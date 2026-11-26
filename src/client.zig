//! HTTP clients of the CLI and the MCP server: idlci's own server, and cpull's
//! API (patches and stacks for `idlci patch|stack`). Both check /api/health
//! names this workspace's root before trusting an address
//! (docs/workspace-tools.md §1 in the theme package).
const std = @import("std");
const discovery = @import("discovery");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Client = struct {
    a: Allocator,
    http: std.http.Client,
    base: []const u8,
    addr: []const u8,
    /// The server's `{"error": ...}` (or what went wrong) after a failed request.
    last_error: []const u8 = "",

    pub const Error = error{ServerError};

    pub fn send(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !std.json.Value {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const url = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path });
        const res = c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &out.writer,
            .keep_alive = false,
            .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        }) catch |e| {
            c.last_error = try std.fmt.allocPrint(c.a, "{s}: {t}", .{ url, e });
            return error.ServerError;
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, c.a, out.written(), .{}) catch {
            c.last_error = try std.fmt.allocPrint(c.a, "decoding response: {s}", .{out.written()});
            return error.ServerError;
        };
        if (res.status.class() != .success) {
            c.last_error = @tagName(res.status);
            if (v == .object) if (v.object.get("error")) |e| if (e == .string) {
                c.last_error = e.string;
            };
            return error.ServerError;
        }
        return v;
    }

    pub fn get(c: *Client, path: []const u8) !std.json.Value {
        return c.send(.GET, path, null);
    }

    pub fn post(c: *Client, path: []const u8, body: []const u8) !std.json.Value {
        return c.send(.POST, path, body);
    }
};

pub const Connected = union(enum) { ok: Client, err: []const u8 };

/// A client for `tool`'s server of the workspace at `root` (a real path):
/// `explicit` (--addr, or the tool's env var), else its serve.addr, else the
/// default address; an error message unless /api/health names `tool` and `root`.
pub fn connect(io: Io, a: Allocator, root: []const u8, tool: discovery.Tool, explicit: ?[]const u8) !Connected {
    const addr = try discovery.connectAddr(io, a, root, tool, explicit);
    var c: Client = .{ .a = a, .http = .{ .allocator = a, .io = io }, .base = try discovery.baseUrl(a, addr), .addr = addr };
    const health = c.get("/api/health") catch return .{ .err = try notRunning(a, tool, root, addr) };
    const served = if (health == .object) health.object.get("root") else null;
    const named = if (health == .object) health.object.get("tool") else null;
    if (served == null or served.? != .string or (named != null and (named.? != .string or !std.mem.eql(u8, named.?.string, @tagName(tool)))))
        return .{ .err = try std.fmt.allocPrint(a, "{s} answers but isn't {s}'s server; pass --addr", .{ addr, @tagName(tool) }) };
    if (!std.mem.eql(u8, served.?.string, root))
        return .{ .err = try std.fmt.allocPrint(a, "{s} is the {s} server of {s}, not {s}; pass --addr", .{ addr, @tagName(tool), served.?.string, root }) };
    return .{ .ok = c };
}

fn notRunning(a: Allocator, tool: discovery.Tool, root: []const u8, addr: []const u8) ![]const u8 {
    return switch (tool) {
        .cpull => std.fmt.allocPrint(a, "cpull isn't running (start the cpull job: pull launchctl start cpull); looked for it at {s}", .{addr}),
        else => std.fmt.allocPrint(a, "{s} isn't running for {s} at {s} (start the {s} job: pull launchctl start {s}, or `{s} serve`; or pass --addr)", .{ @tagName(tool), root, addr, @tagName(tool), @tagName(tool), @tagName(tool) }),
    };
}

/// The workspace root: --root, else $PULL_ROOT, else the nearest parent with pullfile.plist.
pub fn findRoot(io: Io, a: Allocator, arg: ?[]const u8, env: *const std.process.Environ.Map, cwd: []const u8) ![]const u8 {
    const root = arg orelse env.get("PULL_ROOT") orelse blk: {
        var dir: ?[]const u8 = cwd;
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            const p = try std.fs.path.join(a, &.{ d, "pullfile.plist" });
            const st = Io.Dir.cwd().statFile(io, p, .{}) catch null;
            if (st != null and st.?.kind == .file) break :blk d;
        }
        return error.NoWorkspaceRoot;
    };
    const abs = try std.fs.path.resolve(a, &.{ cwd, root });
    return Io.Dir.cwd().realPathFileAlloc(io, abs, a);
}

/// A run's members from cpull's API, for POST /api/runs.
pub const Resolved = struct { subject: []const u8, members: []const Member };
pub const Member = struct { repo: []const u8, patch_id: []const u8, branch: []const u8, oid: []const u8 };

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// `GET /api/patches/<repo>/<id>` → the patch's one member (its source branch and tip).
pub fn resolvePatch(c: *Client, a: Allocator, repo: []const u8, id: []const u8, msg: *[]const u8) !Resolved {
    const v = c.get(try std.fmt.allocPrint(a, "/api/patches/{s}/{s}", .{ std.mem.trim(u8, repo, "/"), id })) catch {
        msg.* = try std.fmt.allocPrint(a, "patch {s} in {s}: {s}", .{ id, repo, c.last_error });
        return error.Unresolved;
    };
    if (v != .object) return error.Unresolved;
    const full = str(v.object, "id") orelse id;
    const name = str(v.object, "repo") orelse repo;
    const branch = str(v.object, "source_branch") orelse {
        msg.* = try std.fmt.allocPrint(a, "patch {s} comes from a fork: no source branch to check out", .{full[0..@min(8, full.len)]});
        return error.Unresolved;
    };
    const tip = str(v.object, "tip") orelse {
        msg.* = try std.fmt.allocPrint(a, "patch {s}: its source branch {s} doesn't exist", .{ full[0..@min(8, full.len)], branch });
        return error.Unresolved;
    };
    const members = try a.alloc(Member, 1);
    members[0] = .{ .repo = name, .patch_id = full, .branch = branch, .oid = tip };
    return .{ .subject = try std.fmt.allocPrint(a, "patch:{s}:{s}", .{ name, full }), .members = members };
}

/// `GET /api/stacks/<id>` → the members whose source branches exist.
pub fn resolveStack(c: *Client, a: Allocator, id: []const u8, msg: *[]const u8) !Resolved {
    const v = c.get(try std.fmt.allocPrint(a, "/api/stacks/{s}", .{id})) catch {
        msg.* = try std.fmt.allocPrint(a, "stack {s}: {s}", .{ id, c.last_error });
        return error.Unresolved;
    };
    if (v != .object) return error.Unresolved;
    const full = str(v.object, "id") orelse id;
    var members: std.ArrayList(Member) = .empty;
    if (v.object.get("members")) |list| if (list == .array) for (list.array.items) |m| {
        if (m != .object) continue;
        try members.append(a, .{
            .repo = str(m.object, "repo") orelse continue,
            .patch_id = str(m.object, "patch_id") orelse "",
            .branch = str(m.object, "branch") orelse "",
            .oid = str(m.object, "oid") orelse continue,
        });
    };
    if (members.items.len == 0) {
        msg.* = "none of the stack's patches has a source branch to check out";
        return error.Unresolved;
    }
    return .{ .subject = try std.fmt.allocPrint(a, "stack:{s}", .{full}), .members = members.items };
}

/// The POST /api/runs body for `r`.
pub fn runBody(a: Allocator, r: Resolved, by: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .subject = r.subject, .members = r.members, .requested_by = by }, .{});
}
