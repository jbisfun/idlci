//! Patch and stack runs (POST /api/runs): build and test every idl project of
//! the member repos with the members' source commits checked out, in a work
//! tree of their own (work.zig). cpull resolves a patch or stack into its
//! members (repo, patch id, source branch, tip); idlci adds the repos the
//! projects' targets live in (sibling repos like `../commons-ios`) at the
//! workspace's current HEADs. The jobs carry the subject ("patch:<repo>:<id>"
//! or "stack:<id>") and the commits they check out, so status.forSubject can
//! tell when they ran on older commits than the branches hold now.
const std = @import("std");
const db = @import("db.zig");
const App = @import("app.zig").App;
const pullfile = @import("pullfile.zig");
const projects = @import("projects.zig");

const Allocator = std.mem.Allocator;

pub const Member = struct {
    repo: []const u8,
    patch_id: []const u8,
    branch: []const u8,
    /// the source branch's tip
    oid: []const u8,
};

pub const Run = struct {
    subject: []const u8,
    members: []const Member,
    requested_by: db.RequestedBy = .cli,
};

pub const Queued = struct {
    subject: []const u8,
    checkout: []const u8,
    jobs: []const db.Enqueued,
};

pub fn patchSubject(a: Allocator, repo: []const u8, patch_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "patch:{s}:{s}", .{ repo, patch_id });
}

pub fn stackSubject(a: Allocator, stack_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "stack:{s}", .{stack_id});
}

/// "<repo> <oid>" per member: what a subject's jobs must have checked out to be current.
pub fn tips(a: Allocator, members: []const Member) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (members, 0..) |m, i| {
        if (i > 0) try out.append(a, '\n');
        try out.print(a, "{s} {s}", .{ m.repo, m.oid });
    }
    return out.items;
}

/// Parse a POST /api/runs body; `msg` says what's wrong.
pub fn parse(a: Allocator, body: []const u8, msg: *[]const u8) !Run {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch {
        msg.* = "invalid json";
        return error.BadRequest;
    };
    if (v != .object) {
        msg.* = "expected an object";
        return error.BadRequest;
    }
    const str = struct {
        fn f(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = o.get(k) orelse return null;
            return if (x == .string and x.string.len > 0) x.string else null;
        }
    }.f;
    var run: Run = .{ .subject = str(v.object, "subject") orelse {
        msg.* = "missing subject";
        return error.BadRequest;
    }, .members = &.{} };
    if (!std.mem.startsWith(u8, run.subject, "patch:") and !std.mem.startsWith(u8, run.subject, "stack:")) {
        msg.* = "subject must be patch:<repo>:<id> or stack:<id>";
        return error.BadRequest;
    }
    if (str(v.object, "requested_by")) |by| run.requested_by = db.RequestedBy.parse(by) orelse {
        msg.* = try std.fmt.allocPrint(a, "invalid requested_by \"{s}\"", .{by});
        return error.BadRequest;
    };
    const list = v.object.get("members") orelse {
        msg.* = "missing members";
        return error.BadRequest;
    };
    if (list != .array or list.array.items.len == 0) {
        msg.* = "members must be a non-empty array";
        return error.BadRequest;
    }
    const members = try a.alloc(Member, list.array.items.len);
    for (list.array.items, members, 0..) |item, *m, i| {
        if (item != .object) {
            msg.* = "members must be objects";
            return error.BadRequest;
        }
        const o = item.object;
        m.* = .{
            .repo = str(o, "repo") orelse "",
            .patch_id = str(o, "patch_id") orelse "",
            .branch = str(o, "branch") orelse "",
            .oid = str(o, "oid") orelse "",
        };
        if (m.repo.len == 0 or m.oid.len == 0) {
            msg.* = try std.fmt.allocPrint(a, "member {d} needs repo and oid", .{i});
            return error.BadRequest;
        }
        if (std.mem.indexOf(u8, m.repo, "..") != null or m.repo[0] == '/' or !isHex(m.oid)) {
            msg.* = try std.fmt.allocPrint(a, "member {d}: invalid repo or oid", .{i});
            return error.BadRequest;
        }
    }
    run.members = members;
    return run;
}

fn isHex(s: []const u8) bool {
    if (s.len < 7) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The pullfile repo holding an absolute dir (the longest match).
fn repoHolding(root: []const u8, repos: []const pullfile.Repo, a: Allocator, dir: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    for (repos) |r| {
        const path = std.fs.path.join(a, &.{ root, r.name }) catch continue;
        const inside = std.mem.eql(u8, dir, path) or (std.mem.startsWith(u8, dir, path) and dir.len > path.len and dir[path.len] == '/');
        if (inside and path.len > best_len) {
            best = r.name;
            best_len = path.len;
        }
    }
    return best;
}

/// Queue build + test of every idl project in the members' repos (see the top).
pub fn queue(app: *App, a: Allocator, run: Run, msg: *[]const u8) !Queued {
    const members = run.members;
    const repos = try app.repos(a);
    for (members) |m| {
        if (repos.len > 0 and for (repos) |r| (if (std.mem.eql(u8, r.name, m.repo)) break false) else true) {
            msg.* = try std.fmt.allocPrint(a, "no repo {s} in the pullfile", .{m.repo});
            return error.BadRequest;
        }
    }
    const Selected = struct { path: []const u8, dir: []const u8, member: Member };
    var selected: std.ArrayList(Selected) = .empty;
    for (try app.projectList(a)) |p| {
        const repo = app.repoOf(p.dir) orelse continue;
        for (members) |m| if (std.mem.eql(u8, m.repo, repo)) {
            try selected.append(a, .{ .path = p.path, .dir = p.dir, .member = m });
        };
    }
    if (selected.items.len == 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (members) |m| try names.append(a, m.repo);
        msg.* = try std.fmt.allocPrint(a, "no idl projects in {s}, so there is nothing to build", .{try std.mem.join(a, ", ", names.items)});
        return error.BadRequest;
    }
    // the members at their tips, the repos their targets live in at the workspace's HEADs
    var checkout: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (members) |m| try checkout.put(a, m.repo, m.oid);
    for (selected.items) |p| {
        var tmsg: []const u8 = "";
        const targets = app.targets(a, .{ .path = p.path, .dir = p.dir }, &tmsg) catch continue;
        for (targets) |t| {
            const dir = try std.fs.path.resolve(a, &.{ p.dir, t.dir });
            const repo = repoHolding(app.root, repos, a, dir) orelse continue;
            if (checkout.contains(repo)) continue;
            const path = try std.fs.path.join(a, &.{ app.root, repo });
            const out = projects.output(app.io, a, &.{ "git", "-C", path, "rev-parse", "--verify", "-q", "HEAD" }, null) orelse continue;
            try checkout.put(a, repo, std.mem.trimEnd(u8, out, "\n"));
        }
    }
    const Entry = struct { repo: []const u8, oid: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    var it = checkout.iterator();
    while (it.next()) |e| try entries.append(a, .{ .repo = e.key_ptr.*, .oid = e.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.repo, y.repo);
        }
    }.lt);
    var text: std.ArrayList(u8) = .empty;
    for (entries.items, 0..) |e, i| {
        if (i > 0) try text.append(a, '\n');
        try text.print(a, "{s} {s}", .{ e.repo, e.oid });
    }

    var jobs: std.ArrayList(db.Enqueued) = .empty;
    for (selected.items) |p| {
        for ([_]db.Command{ .build, .@"test" }) |command| {
            const enq = try app.enqueueWith(a, .{
                .project = p.path,
                .command = command,
                .requested_by = run.requested_by,
                .subject = run.subject,
                .checkout = text.items,
            }, .{
                .repo = p.member.repo,
                .branch = if (p.member.branch.len > 0) p.member.branch else null,
                .head = p.member.oid[0..@min(7, p.member.oid.len)],
            }, msg);
            try jobs.append(a, enq);
        }
    }
    return .{ .subject = run.subject, .checkout = text.items, .jobs = jobs.items };
}

test parse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    const run = try parse(a,
        \\{"subject":"stack:abc","members":[{"repo":"core","patch_id":"p1","branch":"feat","oid":"0123456789abcdef"}],"requested_by":"mcp"}
    , &msg);
    try std.testing.expectEqualStrings("core", run.members[0].repo);
    try std.testing.expectEqual(db.RequestedBy.mcp, run.requested_by);
    try std.testing.expectError(error.BadRequest, parse(a, "{\"subject\":\"x\",\"members\":[]}", &msg));
    try std.testing.expectError(error.BadRequest, parse(a, "{\"subject\":\"patch:a:b\",\"members\":[{\"repo\":\"../x\",\"oid\":\"0123456\"}]}", &msg));
    try std.testing.expectEqualStrings("core 0123456789abcdef", try tips(a, run.members));
}
