//! The `idlci` CLI: `serve` and `mcp`, and the client commands (queue, jobs,
//! log, cancel, retry, patch, stack, cleanup) of the Rust idlci and of `cpull
//! ci`, talking to the server's /api.
const std = @import("std");
const db = @import("db.zig");
const client_mod = @import("client.zig");
const discovery = @import("discovery");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = client_mod.Client;

pub const version = @import("web.zig").version;

pub const usage =
    \\usage: idlci <command> [--root DIR] [--addr HOST:PORT]
    \\
    \\local CI for the idl projects of a pull workspace.
    \\
    \\  serve [--listen ADDR] [--jobs N] [--watch] [--watch-interval S] [--work-days D]
    \\        web UI + JSON API + job workers (default 127.0.0.1:8737; --addr
    \\        is accepted for --listen, as the Rust idlci had it). --watch queues
    \\        build + test when a project's git HEAD moves (every 15s); patch/stack
    \\        work trees idle for D days (default 7, 0 = keep) are removed.
    \\  mcp   MCP server on stdio (ci_* tools), a client of the server
    \\  queue PROJECT COMMAND [TARGET...] [-c debug|release] [--strict] [-w|--wait]
    \\        COMMAND: build test lint fmt-check check clean. --wait follows the log
    \\        and exits nonzero unless the job passed.
    \\  jobs  [--status S] [--project P] [--limit N]    (also: list)
    \\  log   ID [-f|--follow]
    \\  cancel ID
    \\  retry ID
    \\  patch REPO PATCH [-w]   build + test a cpull patch's source branch in a work tree
    \\  stack STACK [-w]        the same for every member of a stack, checked out together
    \\        (PATCH/STACK: an id or a unique prefix, resolved through cpull's API;
    \\        --wait exits nonzero unless all pass)
    \\  cleanup [--days D] [--dry-run]   remove patch/stack work trees idle for D days
    \\
    \\--root defaults to $PULL_ROOT, else the nearest parent holding pullfile.plist;
    \\--addr to $IDLCI_ADDR, else .pull/idlci/serve.addr, else 127.0.0.1:8737
    \\(cpull: $CPULL_ADDR, else .pull/cpull/serve.addr, else 127.0.0.1:8080).
    \\
;

/// A Job from the API's JSON.
pub fn parseJob(a: Allocator, v: std.json.Value) !db.Job {
    const o = v.object;
    const str = struct {
        fn s(obj: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = obj.get(k) orelse return null;
            return if (x == .string) x.string else null;
        }
        fn i(obj: std.json.ObjectMap, k: []const u8) ?i64 {
            const x = obj.get(k) orelse return null;
            return if (x == .integer) x.integer else null;
        }
        fn b(obj: std.json.ObjectMap, k: []const u8) bool {
            const x = obj.get(k) orelse return false;
            return x == .bool and x.bool;
        }
    };
    var targets: std.ArrayList([]const u8) = .empty;
    if (o.get("targets")) |t| if (t == .array) for (t.array.items) |x| if (x == .string) try targets.append(a, x.string);
    return .{
        .id = str.i(o, "id") orelse return error.InvalidJob,
        .project = str.s(o, "project") orelse "",
        .command = db.Command.parse(str.s(o, "command") orelse "") orelse return error.InvalidJob,
        .targets = targets.items,
        .configuration = db.Configuration.parse(str.s(o, "configuration") orelse "") orelse .none,
        .strict = str.b(o, "strict"),
        .status = db.Status.parse(str.s(o, "status") orelse "") orelse return error.InvalidJob,
        .exit_code = if (str.i(o, "exit_code")) |c| @intCast(c) else null,
        .created = str.i(o, "created") orelse 0,
        .started = str.i(o, "started"),
        .finished = str.i(o, "finished"),
        .git = .{ .repo = str.s(o, "repo"), .branch = str.s(o, "branch"), .head = str.s(o, "head"), .dirty = str.b(o, "dirty") },
        .requested_by = db.RequestedBy.parse(str.s(o, "requested_by") orelse "") orelse .cli,
        .retry_of = str.i(o, "retry_of"),
        .log = str.s(o, "log") orelse "",
        .subject = str.s(o, "subject"),
        .checkout = str.s(o, "checkout"),
    };
}

pub const Parsed = struct {
    positional: std.ArrayList([]const u8) = .empty,
    root: ?[]const u8 = null,
    addr: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    jobs: usize = 1,
    watch: bool = false,
    watch_interval: u64 = 15,
    work_days: u32 = 7,
    days: ?u32 = null,
    dry_run: bool = false,
    configuration: db.Configuration = .none,
    strict: bool = false,
    wait: bool = false,
    follow: bool = false,
    status: ?[]const u8 = null,
    project: ?[]const u8 = null,
    limit: usize = 20,
};

/// Run `idlci ARGS...`; returns the exit code.
pub fn run(io: Io, a: Allocator, args: []const []const u8, env: *const std.process.Environ.Map, cwd: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = struct {
            fn v(list: []const []const u8, idx: *usize, name: []const u8, e: *std.Io.Writer) ?[]const u8 {
                if (idx.* + 1 >= list.len) {
                    e.print("error: {s} needs a value\n\n{s}", .{ name, usage }) catch {};
                    return null;
                }
                idx.* += 1;
                return list[idx.*];
            }
        }.v;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            try out.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try out.print("idlci {s}\n", .{version});
            return 0;
        } else if (std.mem.eql(u8, arg, "--listen")) {
            p.listen = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const v = value(args, &i, arg, err) orelse return 2;
            p.jobs = std.fmt.parseInt(usize, v, 10) catch {
                try err.print("error: invalid --jobs '{s}'\n", .{v});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--watch")) {
            p.watch = true;
        } else if (std.mem.eql(u8, arg, "--watch-interval")) {
            const v = value(args, &i, arg, err) orelse return 2;
            p.watch_interval = std.fmt.parseInt(u64, v, 10) catch {
                try err.print("error: invalid --watch-interval '{s}'\n", .{v});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--work-days") or std.mem.eql(u8, arg, "--days")) {
            const v = value(args, &i, arg, err) orelse return 2;
            const d = std.fmt.parseInt(u32, v, 10) catch {
                try err.print("error: invalid {s} '{s}'\n", .{ arg, v });
                return 2;
            };
            if (std.mem.eql(u8, arg, "--days")) p.days = d else p.work_days = d;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            p.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            p.root = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--addr")) {
            p.addr = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--configuration")) {
            const c = value(args, &i, arg, err) orelse return 2;
            p.configuration = db.Configuration.parse(c) orelse {
                try err.print("error: invalid configuration '{s}' [possible values: debug, release, none]\n", .{c});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--strict")) {
            p.strict = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--wait")) {
            p.wait = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            p.follow = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            p.status = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--project")) {
            p.project = value(args, &i, arg, err) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const l = value(args, &i, arg, err) orelse return 2;
            p.limit = std.fmt.parseInt(usize, l, 10) catch {
                try err.print("error: invalid --limit '{s}'\n", .{l});
                return 2;
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            try err.print("error: unexpected argument '{s}' found\n\n{s}", .{ arg, usage });
            return 2;
        } else try p.positional.append(a, arg);
    }
    const pos = p.positional.items;
    if (pos.len == 0) {
        try err.writeAll(usage);
        return 2;
    }
    const cmd = pos[0];
    const known = [_][]const u8{ "serve", "mcp", "queue", "jobs", "list", "log", "cancel", "retry", "patch", "stack", "cleanup" };
    if (for (known) |k| (if (std.mem.eql(u8, k, cmd)) break false) else true) {
        try err.print("error: unrecognized subcommand '{s}'\n\n{s}", .{ cmd, usage });
        return 2;
    }

    const root = client_mod.findRoot(io, a, p.root, env, cwd) catch |e| {
        try err.print("Error: {s}\n", .{if (e == error.NoWorkspaceRoot) "no workspace root: pass --root, set PULL_ROOT, or run inside a pull workspace" else @errorName(e)});
        return 1;
    };
    if (std.mem.eql(u8, cmd, "serve")) {
        if (pos.len > 1) {
            try err.print("error: unexpected argument '{s}' found\n", .{pos[1]});
            return 2;
        }
        return @import("serve.zig").run(io, a, root, env, .{
            .listen = p.listen orelse p.addr orelse env.get("IDLCI_LISTEN") orelse discovery.Tool.idlci.defaultAddr(),
            .jobs = p.jobs,
            .watch = if (p.watch) p.watch_interval else null,
            .work_days = p.work_days,
        }, err);
    }
    const explicit = p.addr orelse env.get(discovery.Tool.idlci.envVar());
    if (std.mem.eql(u8, cmd, "mcp")) {
        try @import("mcp.zig").serve(io, a, root, explicit, env);
        return 0;
    }
    var c = switch (try client_mod.connect(io, a, root, .idlci, explicit)) {
        .ok => |x| x,
        .err => |m| {
            try err.print("Error: {s}\n", .{m});
            return 1;
        },
    };
    return command(io, a, &c, root, env, cmd, pos[1..], p, out, err) catch |e| {
        if (e == error.ServerError) try err.print("Error: {s}\n", .{c.last_error}) else try err.print("Error: {t}\n", .{e});
        return 1;
    };
}

fn needId(pos: []const []const u8, err: *std.Io.Writer) !?i64 {
    if (pos.len != 1) {
        try err.print("error: expected one job ID\n\n{s}", .{usage});
        return null;
    }
    return std.fmt.parseInt(i64, pos[0], 10) catch {
        try err.print("error: invalid job ID '{s}'\n", .{pos[0]});
        return null;
    };
}

fn command(io: Io, a: Allocator, c: *Client, root: []const u8, env: *const std.process.Environ.Map, cmd: []const u8, pos: []const []const u8, p: Parsed, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (std.mem.eql(u8, cmd, "queue")) {
        if (pos.len < 2) {
            try err.print("error: queue needs PROJECT and COMMAND\n\n{s}", .{usage});
            return 2;
        }
        const command_v = db.Command.parse(pos[1]) orelse {
            try err.print("error: invalid value '{s}' for '<COMMAND>' [possible values: build, test, lint, fmt-check, check, clean]\n", .{pos[1]});
            return 2;
        };
        const new: db.NewJob = .{ .project = pos[0], .command = command_v, .targets = pos[2..], .configuration = p.configuration, .strict = p.strict, .requested_by = .cli };
        const v = try c.post("/api/jobs", try std.json.Stringify.valueAlloc(a, new, .{}));
        const job = try parseJob(a, v);
        const dedup = v.object.get("deduplicated");
        try out.print("{s}{s}\n", .{ try job.summary(a), if (dedup != null and dedup.? == .bool and dedup.?.bool) " (already queued)" else "" });
        try out.flush();
        if (p.wait) {
            const done = try follow(io, a, c, job.id, out);
            if (done.status != .passed) {
                try err.print("Error: job #{d} {t}\n", .{ done.id, done.status });
                return 1;
            }
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "jobs") or std.mem.eql(u8, cmd, "list")) {
        if (pos.len != 0) {
            try err.print("error: unexpected argument '{s}' found\n", .{pos[0]});
            return 2;
        }
        var q: std.Io.Writer.Allocating = .init(a);
        try q.writer.print("/api/jobs?limit={d}", .{p.limit});
        const enc = struct {
            fn ok(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
            }
        }.ok;
        if (p.status) |s| {
            if (db.Status.parse(s) == null) {
                try err.print("error: invalid value '{s}' for '--status' [possible values: queued, running, passed, failed, cancelled]\n", .{s});
                return 2;
            }
            try q.writer.print("&status={s}", .{s});
        }
        if (p.project) |pr| {
            try q.writer.writeAll("&project=");
            try std.Uri.Component.percentEncode(&q.writer, pr, enc);
        }
        const v = try c.get(q.written());
        for (v.array.items) |j| try out.print("{s}\n", .{try (try parseJob(a, j)).summary(a)});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "log")) {
        const id = try needId(pos, err) orelse return 2;
        if (p.follow) {
            _ = try follow(io, a, c, id, out);
            return 0;
        }
        const v = try c.get(try std.fmt.allocPrint(a, "/api/jobs/{d}/log?tail=1000000", .{id}));
        try out.print("{s}\n", .{v.object.get("text").?.string});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "patch") or std.mem.eql(u8, cmd, "stack")) {
        const stack = std.mem.eql(u8, cmd, "stack");
        if (pos.len != @as(usize, if (stack) 1 else 2)) {
            try err.print("error: {s} needs {s}\n\n{s}", .{ cmd, if (stack) "STACK" else "REPO and PATCH", usage });
            return 2;
        }
        var cp = switch (try client_mod.connect(io, a, root, .cpull, env.get(discovery.Tool.cpull.envVar()))) {
            .ok => |x| x,
            .err => |m| {
                try err.print("Error: {s}\n", .{m});
                return 1;
            },
        };
        var msg: []const u8 = "";
        const resolved = (if (stack) client_mod.resolveStack(&cp, a, pos[0], &msg) else client_mod.resolvePatch(&cp, a, pos[0], pos[1], &msg)) catch {
            try err.print("Error: {s}\n", .{msg});
            return 1;
        };
        const v = try c.post("/api/runs", try client_mod.runBody(a, resolved, "cli"));
        try out.print("{s}\n", .{v.object.get("subject").?.string});
        var ids: std.ArrayList(i64) = .empty;
        for (v.object.get("jobs").?.array.items) |j| {
            const job = try parseJob(a, j);
            const dedup = j.object.get("deduplicated");
            try out.print("{s}{s}\n", .{ try job.summary(a), if (dedup != null and dedup.? == .bool and dedup.?.bool) " (already queued)" else "" });
            try ids.append(a, job.id);
        }
        try out.flush();
        if (!p.wait) return 0;
        var failed = false;
        for (ids.items) |id| {
            while (true) {
                const job = try parseJob(a, try c.get(try std.fmt.allocPrint(a, "/api/jobs/{d}", .{id})));
                if (job.status.isFinal()) {
                    try out.print("{s}\n", .{try job.summary(a)});
                    try out.flush();
                    if (job.status != .passed) failed = true;
                    break;
                }
                io.sleep(.fromSeconds(1), .awake) catch {};
            }
        }
        return if (failed) 1 else 0;
    }
    if (std.mem.eql(u8, cmd, "cancel")) {
        const id = try needId(pos, err) orelse return 2;
        const v = try c.post(try std.fmt.allocPrint(a, "/api/jobs/{d}/cancel", .{id}), "null");
        try out.print("{s}\n", .{try (try parseJob(a, v)).summary(a)});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "cleanup")) {
        if (pos.len != 0) {
            try err.print("error: unexpected argument '{s}' found\n", .{pos[0]});
            return 2;
        }
        var q: std.Io.Writer.Allocating = .init(a);
        try q.writer.writeAll("/api/work/cleanup?");
        if (p.days) |d| try q.writer.print("days={d}&", .{d});
        if (p.dry_run) try q.writer.writeAll("dry_run=1");
        const v = try c.post(q.written(), "null");
        const removed = v.object.get("removed").?.array.items;
        if (removed.len == 0) try out.print("no work tree idle for {d} days\n", .{v.object.get("days").?.integer});
        for (removed) |r| {
            const subj = r.object.get("subject").?;
            try out.print("{s}{s} ({s}, {d} days idle)\n", .{ if (p.dry_run) "would remove " else "removed ", r.object.get("name").?.string, if (subj == .string) subj.string else "no jobs", r.object.get("idle_days").?.integer });
        }
        return 0;
    }
    // retry
    const id = try needId(pos, err) orelse return 2;
    const v = try c.post(try std.fmt.allocPrint(a, "/api/jobs/{d}/retry?by=cli", .{id}), "null");
    try out.print("{s}\n", .{try (try parseJob(a, v)).summary(a)});
    return 0;
}

/// Stream a job's log to `out` until it finishes.
fn follow(io: Io, a: Allocator, c: *Client, id: i64, out: *std.Io.Writer) !db.Job {
    var offset: u64 = 0;
    while (true) {
        const v = try c.get(try std.fmt.allocPrint(a, "/api/jobs/{d}/log?offset={d}", .{ id, offset }));
        const o = v.object;
        const text = o.get("text").?.string;
        try out.writeAll(text);
        try out.flush();
        offset = @intCast(o.get("next_offset").?.integer);
        const size: u64 = @intCast(o.get("size").?.integer);
        const status = db.Status.parse(o.get("status").?.string) orelse .failed;
        if (status.isFinal() and offset >= size) return parseJob(a, try c.get(try std.fmt.allocPrint(a, "/api/jobs/{d}", .{id})));
        if (text.len == 0) io.sleep(.fromSeconds(1), .awake) catch {};
    }
}
