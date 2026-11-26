//! `idlci mcp`: an MCP server (stdio, on parley) with the ci_* tools pull's
//! MCP served while the CI lived in cpull (and the Rust idlci's before that):
//! same names, input schemas and output, as a client of idlci's server. When
//! the server isn't running, the tools start it through pull
//! (`pull launchctl start idlci`, the pullfile job), never by spawning one.
//! ci_patch/ci_stack resolve the members through cpull's API, then POST
//! /api/runs.
const std = @import("std");
const parley = @import("parley");
const discovery = @import("discovery");
const client_mod = @import("client.zig");
const args_mod = @import("mcp_args.zig");
const Args = args_mod.Args;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = client_mod.Client;

pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    /// --addr / $IDLCI_ADDR
    explicit: ?[]const u8,
    env: *const std.process.Environ.Map,
    /// set once `pull launchctl start idlci` was tried
    started: std.atomic.Value(bool) = .init(false),
};

pub const Result = union(enum) { ok: []const u8, err: []const u8 };

pub const Def = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    fields: []const args_mod.Field = &.{},
    run: *const fn (ctx: *Ctx, a: Allocator, args: Args) anyerror!Result,
};

const id_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"}},"required":["id"],"type":"object"}
;

pub const defs = &[_]Def{
    .{
        .name = "ci_projects",
        .description = "idlci: list idl projects in the workspace with git state, targets and the latest job per command.",
        .schema = "{\"properties\":{},\"type\":\"object\"}",
        .run = projects,
    },
    .{
        .name = "ci_queue",
        .description = "idlci: queue an idl job (build|test|lint|fmt-check|check|clean) for a project; returns the job id. Use `ci_wait` to block until it finishes. Jobs run one at a time on a shared queue (the laptop overheats), so prefer targeted jobs and don't queue duplicates.",
        .schema =
        \\{"$defs":{"Command":{"enum":["build","test","lint","fmt-check","check","clean"],"type":"string"},"Configuration":{"enum":["debug","release","none"],"type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"command":{"$ref":"#/$defs/Command"},"configuration":{"anyOf":[{"$ref":"#/$defs/Configuration"},{"type":"null"}],"description":"debug | release (default: idl's default)."},"project":{"description":"Project path relative to the workspace root (e.g. `fossify-ios/calculator-ios`), pull repo name, or last path segment.","type":"string"},"strict":{"description":"--strict (build/check only).","type":["boolean","null"]},"targets":{"description":"Targets (default: all).","items":{"type":"string"},"type":["array","null"]}},"required":["project","command"],"type":"object"}
        ,
        .fields = &.{ .{ "project", .string }, .{ "command", .string }, .{ "configuration", .opt_string } },
        .run = queue,
    },
    .{
        .name = "ci_jobs",
        .description = "idlci: list jobs, newest first (filters: status, project, limit).",
        .schema =
        \\{"$defs":{"Status":{"enum":["queued","running","passed","failed","cancelled"],"type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"limit":{"description":"Default 20.","format":"uint","minimum":0,"type":["integer","null"]},"project":{"type":["string","null"]},"status":{"anyOf":[{"$ref":"#/$defs/Status"},{"type":"null"}]}},"type":"object"}
        ,
        .fields = &.{ .{ "status", .opt_string }, .{ "project", .opt_string }, .{ "limit", .opt_usize } },
        .run = jobs,
    },
    .{
        .name = "ci_job",
        .description = "idlci: job metadata plus the last log lines.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"lines":{"description":"Log lines to include from the end (default 40).","format":"uint","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "lines", .opt_usize } },
        .run = job,
    },
    .{
        .name = "ci_log",
        .description = "idlci: read a job's log: from a byte offset (up to 1 MiB, returns next_offset) or the last `tail` lines.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"offset":{"description":"Byte offset to read from (use the returned next_offset to continue).","format":"uint64","minimum":0,"type":["integer","null"]},"tail":{"description":"Only the last N lines (overrides offset).","format":"uint","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "offset", .opt_u64 }, .{ "tail", .opt_usize } },
        .run = log,
    },
    .{
        .name = "ci_wait",
        .description = "idlci: block until a job finishes (or timeout_s, default 300, max 600); returns its status and log tail.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"lines":{"description":"Log lines to include from the end (default 40).","format":"uint","minimum":0,"type":["integer","null"]},"timeout_s":{"description":"Seconds to wait (default 300, max 600).","format":"uint64","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "lines", .opt_usize }, .{ "timeout_s", .opt_u64 } },
        .run = wait,
    },
    .{
        .name = "ci_cancel",
        .description = "idlci: cancel a queued job or abort a running one (kills its whole process group).",
        .schema = id_schema,
        .fields = &.{.{ "id", .int }},
        .run = cancel,
    },
    .{
        .name = "ci_patch",
        .description = "idlci: build + test a cpull patch's source branch (the idl projects of its repo, with sibling repos at the workspace's commits) in a work tree of its own; returns the job ids. The patch page and `cpull_stack` show the result.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"patch":{"description":"Patch id (a unique prefix will do).","type":"string"},"repo":{"description":"Repo name from the pullfile.","type":"string"}},"required":["repo","patch"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "patch", .string } },
        .run = patchCi,
    },
    .{
        .name = "ci_stack",
        .description = "idlci: build + test every member of a cpull stack, all members' branches checked out together; returns the job ids. With the pullfile's `cpull.require_ci`, a stack merges only once this is green at its branches' tips.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"stack":{"description":"Stack id (a unique prefix will do).","type":"string"}},"required":["stack"],"type":"object"}
        ,
        .fields = &.{.{ "stack", .string }},
        .run = stackCiTool,
    },
    .{
        .name = "ci_retry",
        .description = "idlci: queue the same job again; returns the new job id.",
        .schema = id_schema,
        .fields = &.{.{ "id", .int }},
        .run = retry,
    },
};

const Conn = union(enum) { ok: Client, err: []const u8 };

/// idlci's server for this workspace; started through pull once when it isn't running.
fn connect(ctx: *Ctx, a: Allocator) !Conn {
    switch (try client_mod.connect(ctx.io, a, ctx.root, .idlci, ctx.explicit)) {
        .ok => |c| return .{ .ok = c },
        .err => |m| {
            // a server answering for another root, or an explicit address: don't start anything
            if (ctx.explicit != null or (discovery.read(ctx.io, a, ctx.root, .idlci) catch null) != null) return .{ .err = m };
            if (ctx.started.swap(true, .acq_rel)) return .{ .err = m };
            if (!startThroughPull(ctx, a)) return .{ .err = try std.fmt.allocPrint(a, "{s}; `pull launchctl start idlci` failed (is there an idlci job in the pullfile?)", .{m}) };
            var waited: usize = 0;
            while (waited < 30) : (waited += 1) {
                ctx.io.sleep(.fromMilliseconds(500), .awake) catch break;
                switch (try client_mod.connect(ctx.io, a, ctx.root, .idlci, null)) {
                    .ok => |c| return .{ .ok = c },
                    .err => {},
                }
            }
            return .{ .err = try std.fmt.allocPrint(a, "{s}; started the idlci job through pull, but it didn't answer within 15s", .{m}) };
        },
    }
}

fn startThroughPull(ctx: *Ctx, a: Allocator) bool {
    var env = ctx.env.clone(a) catch return false;
    env.put("PULL_ROOT", ctx.root) catch return false;
    const r = std.process.run(a, ctx.io, .{
        .argv = &.{ "pull", "launchctl", "start", "idlci" },
        .cwd = .{ .path = ctx.root },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    }) catch return false;
    return r.term.success();
}

/// cpull's server, for ci_patch/ci_stack.
fn connectCpull(ctx: *Ctx, a: Allocator) !Conn {
    return switch (try client_mod.connect(ctx.io, a, ctx.root, .cpull, ctx.env.get(discovery.Tool.cpull.envVar()))) {
        .ok => |c| .{ .ok = c },
        .err => |m| .{ .err = m },
    };
}

/// send, as a Result-friendly union.
const Reply = union(enum) { ok: std.json.Value, err: []const u8 };

fn call(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Reply {
    if (c.send(method, path, payload)) |v| return .{ .ok = v } else |e| switch (e) {
        error.ServerError => return .{ .err = c.last_error },
        else => return e,
    }
}

fn s(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn n(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn b(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

/// idlci's Job::summary of a job's JSON.
fn summary(a: Allocator, v: std.json.Value) ![]const u8 {
    const o = v.object;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("#{d} {s} {s} {s}", .{ n(o, "id") orelse 0, s(o, "status") orelse "", s(o, "command") orelse "", s(o, "project") orelse "" });
    if (o.get("targets")) |t| if (t == .array and t.array.items.len > 0) {
        try w.writeAll(" [");
        for (t.array.items, 0..) |x, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", if (x == .string) x.string else "" });
        try w.writeByte(']');
    };
    const cfg = s(o, "configuration") orelse "none";
    if (!std.mem.eql(u8, cfg, "none")) try w.print(" -c {s}", .{cfg});
    if (b(o, "strict")) try w.writeAll(" --strict");
    if (n(o, "exit_code")) |code| try w.print(" exit={d}", .{code});
    if (n(o, "started")) |st| if (n(o, "finished")) |f| try w.print(" {d}s", .{f - st});
    if (s(o, "head")) |head| {
        try w.writeAll(" @");
        if (s(o, "branch")) |br| try w.print("{s}:", .{br});
        try w.print("{s}{s}", .{ head, if (b(o, "dirty")) "+dirty" else "" });
    }
    try w.print(" by {s}", .{s(o, "requested_by") orelse ""});
    return out.written();
}

fn isFinal(status: []const u8) bool {
    return !std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running");
}

fn withTail(c: *Client, a: Allocator, j: std.json.Value, lines: ?u64) !Result {
    const count = lines orelse 40;
    const id = n(j.object, "id") orelse 0;
    const l = switch (try call(c, .GET, try std.fmt.allocPrint(a, "/api/jobs/{d}/log?tail={d}", .{ id, count }), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try std.fmt.allocPrint(a, "{s}\nlog: {s}\n--- last {d} log lines ---\n{s}", .{ try summary(a, j), s(j.object, "log") orelse "", count, s(l.object, "text") orelse "" }) };
}

const command_names = [_][]const u8{ "build", "test", "lint", "fmt-check", "check", "clean" };
const status_names = [_][]const u8{ "queued", "running", "passed", "failed", "cancelled" };
const configuration_names = [_][]const u8{ "debug", "release", "none" };

/// serde's message for an unknown enum variant.
fn variant(a: Allocator, value: []const u8, names: []const []const u8) !?[]const u8 {
    for (names) |x| if (std.mem.eql(u8, x, value)) return null;
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("failed to deserialize parameters: unknown variant `{s}`, expected one of ", .{value});
    for (names, 0..) |x, i| try w.writer.print("{s}`{s}`", .{ if (i > 0) ", " else "", x });
    return w.written();
}

fn queued(a: Allocator, v: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}\n", .{s(v.object, "subject") orelse ""});
    if (v.object.get("jobs")) |list| if (list == .array) for (list.array.items) |j| {
        try out.writer.print("{s}{s}\n", .{ try summary(a, j), if (b(j.object, "deduplicated")) " (already queued)" else "" });
    };
    try out.writer.writeAll("Use `ci_wait` on the ids to block until they finish.");
    return out.written();
}

fn runFor(ctx: *Ctx, a: Allocator, repo: ?[]const u8, id: []const u8) !Result {
    var cp = switch (try connectCpull(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    var msg: []const u8 = "";
    const resolved = (if (repo) |r| client_mod.resolvePatch(&cp, a, r, id, &msg) else client_mod.resolveStack(&cp, a, id, &msg)) catch return .{ .err = msg };
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    return switch (try call(&c, .POST, "/api/runs", try client_mod.runBody(a, resolved, "mcp"))) {
        .ok => |v| .{ .ok = try queued(a, v) },
        .err => |m| .{ .err = m },
    };
}

fn patchCi(ctx: *Ctx, a: Allocator, args: Args) !Result {
    return runFor(ctx, a, args.str("repo").?, args.str("patch").?);
}

fn stackCiTool(ctx: *Ctx, a: Allocator, args: Args) !Result {
    return runFor(ctx, a, null, args.str("stack").?);
}

fn projects(ctx: *Ctx, a: Allocator, _: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const list = switch (try call(&c, .GET, "/api/projects", null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (list.array.items) |p| {
        const o = p.object;
        try w.print("{s}  (repo {s}, {s}@{s}{s})  ", .{ s(o, "path") orelse "", s(o, "repo") orelse "-", s(o, "branch") orelse "-", s(o, "head") orelse "-", if (b(o, "dirty")) " dirty" else "" });
        if (o.get("last")) |last| if (last == .object) {
            var it = last.object.iterator();
            var first = true;
            while (it.next()) |e| {
                try w.print("{s}{s}:{s}#{d}", .{ if (first) "" else " ", e.key_ptr.*, s(e.value_ptr.object, "status") orelse "", n(e.value_ptr.object, "id") orelse 0 });
                first = false;
            }
        };
        try w.writeAll("\n    targets: ");
        if (o.get("targets")) |t| if (t == .array) for (t.array.items, 0..) |x, i| {
            try w.print("{s}{s}({s})", .{ if (i == 0) "" else " ", s(x.object, "name") orelse "", s(x.object, "kind") orelse "" });
        };
        try w.writeByte('\n');
    }
    return .{ .ok = out.written() };
}

fn queue(ctx: *Ctx, a: Allocator, args: Args) !Result {
    const command = args.str("command").?;
    if (try variant(a, command, &command_names)) |m| return .{ .err = m };
    const cfg = args.str("configuration") orelse "none";
    if (try variant(a, cfg, &configuration_names)) |m| return .{ .err = m };
    const strict = if (args.obj.get("strict")) |v| switch (v) {
        .bool => |x| x,
        .null => false,
        else => return .{ .err = "failed to deserialize parameters: invalid type, expected a boolean" },
    } else false;
    var targets: std.ArrayList([]const u8) = .empty;
    if (args.obj.get("targets")) |v| switch (v) {
        .array => |arr| for (arr.items) |x| {
            if (x != .string) return .{ .err = "failed to deserialize parameters: invalid type, expected a string" };
            try targets.append(a, x.string);
        },
        .null => {},
        else => return .{ .err = "failed to deserialize parameters: invalid type, expected a sequence" },
    };
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const body = try std.json.Stringify.valueAlloc(a, .{
        .project = args.str("project").?,
        .command = command,
        .targets = targets.items,
        .configuration = cfg,
        .strict = strict,
        .requested_by = "mcp",
        .retry_of = null,
    }, .{});
    const e = switch (try call(&c, .POST, "/api/jobs", body)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    const note = if (b(e.object, "deduplicated")) " (an identical job was already queued)" else "";
    return .{ .ok = try std.fmt.allocPrint(a, "queued job {d}{s}\n{s}", .{ n(e.object, "id") orelse 0, note, try summary(a, e) }) };
}

fn jobs(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var path: std.Io.Writer.Allocating = .init(a);
    try path.writer.print("/api/jobs?limit={d}", .{args.int("limit") orelse 20});
    if (args.str("status")) |st| {
        if (try variant(a, st, &status_names)) |m| return .{ .err = m };
        try path.writer.print("&status={s}", .{st});
    }
    if (args.str("project")) |p| {
        try path.writer.writeAll("&project=");
        try std.Uri.Component.percentEncode(&path.writer, p, struct {
            fn ok(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
            }
        }.ok);
    }
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const list = switch (try call(&c, .GET, path.written(), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    if (list.array.items.len == 0) return .{ .ok = "no jobs" };
    var lines: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |j| try lines.append(a, try summary(a, j));
    return .{ .ok = try std.mem.join(a, "\n", lines.items) };
}

fn getJob(c: *Client, a: Allocator, id: i64) !Reply {
    return call(c, .GET, try std.fmt.allocPrint(a, "/api/jobs/{d}", .{id}), null);
}

fn job(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const j = switch (try getJob(&c, a, args.obj.get("id").?.integer)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return withTail(&c, a, j, args.int("lines"));
}

fn log(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const id = args.obj.get("id").?.integer;
    const q = if (args.int("tail")) |t| try std.fmt.allocPrint(a, "tail={d}", .{t}) else try std.fmt.allocPrint(a, "offset={d}", .{args.int("offset") orelse 0});
    const l = switch (try call(&c, .GET, try std.fmt.allocPrint(a, "/api/jobs/{d}/log?{s}", .{ id, q }), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    const o = l.object;
    return .{ .ok = try std.fmt.allocPrint(a, "[job #{d} {s} size={d} next_offset={d}]\n{s}", .{ n(o, "id") orelse 0, s(o, "status") orelse "", n(o, "size") orelse 0, n(o, "next_offset") orelse 0, s(o, "text") orelse "" }) };
}

fn wait(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const id = args.obj.get("id").?.integer;
    const timeout_s: i64 = @intCast(@min(args.int("timeout_s") orelse 300, 600));
    const deadline = Io.Timestamp.now(ctx.io, .awake).toSeconds() + timeout_s;
    while (true) {
        const j = switch (try getJob(&c, a, id)) {
            .ok => |v| v,
            .err => |m| return .{ .err = m },
        };
        const status = s(j.object, "status") orelse "";
        if (isFinal(status)) return withTail(&c, a, j, args.int("lines"));
        if (Io.Timestamp.now(ctx.io, .awake).toSeconds() >= deadline) {
            const out = switch (try withTail(&c, a, j, args.int("lines"))) {
                .ok => |x| x,
                .err => |m| return .{ .err = m },
            };
            return .{ .ok = try std.fmt.allocPrint(a, "still {s} after timeout; call wait again\n{s}", .{ status, out }) };
        }
        ctx.io.sleep(.fromSeconds(2), .awake) catch return .{ .err = "cancelled" };
    }
}

fn cancel(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const j = switch (try call(&c, .POST, try std.fmt.allocPrint(a, "/api/jobs/{d}/cancel", .{args.obj.get("id").?.integer}), "null")) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try summary(a, j) };
}

fn retry(ctx: *Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const e = switch (try call(&c, .POST, try std.fmt.allocPrint(a, "/api/jobs/{d}/retry?by=mcp", .{args.obj.get("id").?.integer}), "null")) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try std.fmt.allocPrint(a, "queued job {d}\n{s}", .{ n(e.object, "id") orelse 0, try summary(a, e) }) };
}

const Tool = struct {
    h: parley.ToolHandler = .{ .callFn = callTool },
    ctx: *Ctx,
    def: Def,

    fn callTool(h: *parley.ToolHandler, c: *parley.Call, raw: ?[]const u8) parley.Call.Error!parley.ToolResult {
        const t: *Tool = @fieldParentPtr("h", h);
        const a = c.arena;
        const parsed = args_mod.parse(a, raw, t.def.fields) catch return error.OutOfMemory;
        const args = switch (parsed) {
            .ok => |x| x,
            .err => |m| return .failure(m),
        };
        const r = t.def.run(t.ctx, a, args) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failure(@errorName(e)),
        };
        return switch (r) {
            .ok => |text| .ofText(text),
            .err => |text| .failure(text),
        };
    }
};

pub const instructions = "idlci: local CI for the idl projects of this pull workspace (build/test/lint/fmt-check/check/clean jobs on a shared queue, " ++
    "patch and stack runs for cpull). Queue with ci_queue, block with ci_wait, read logs with ci_log.";

/// Every tool, sorted by name.
pub fn sortedDefs() []const Def {
    const all = comptime blk: {
        var arr = defs.*;
        std.mem.sortUnstable(Def, &arr, {}, struct {
            fn lt(_: void, x: Def, y: Def) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        const final = arr;
        break :blk &final;
    };
    return all;
}

/// Serve MCP on stdin/stdout until the client closes stdin.
pub fn serve(io: Io, a: Allocator, root: []const u8, explicit: ?[]const u8, env: *const std.process.Environ.Map) !void {
    const gpa = std.heap.smp_allocator;
    var ctx: Ctx = .{ .gpa = gpa, .io = io, .root = root, .explicit = explicit, .env = env };
    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "idlci", .version = @import("web.zig").version },
        .instructions = instructions,
        .logging = false,
        .validator = null,
    });
    defer server.deinit(io);
    const list = sortedDefs();
    const handlers = try a.alloc(Tool, list.len);
    for (handlers, list) |*t, d| {
        t.* = .{ .ctx = &ctx, .def = d };
        try server.addDynamicTool(io, .{ .name = d.name, .description = d.description, .input_schema = d.schema }, &t.h);
    }
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    try parley.stdio.serve(io, gpa, &server, .fromFile(&stdin), .fromFile(&stdout), .{});
}

test summary {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":12,"project":"ferry-ios","command":"test","targets":["A","B"],"configuration":"release","strict":true,"status":"failed","exit_code":1,"created":1,"started":10,"finished":11,"repo":"ferry-ios","branch":"master","head":"49c350a","dirty":true,"requested_by":"web","retry_of":null,"log":"/x/12.log"}
    , .{});
    try std.testing.expectEqualStrings("#12 failed test ferry-ios [A B] -c release --strict exit=1 1s @master:49c350a+dirty by web", try summary(a, v));
    try std.testing.expectEqualStrings("failed to deserialize parameters: unknown variant `x`, expected one of `debug`, `release`, `none`", (try variant(a, "x", &configuration_names)).?);
}
