//! Work trees for patch and stack jobs: a pull-style workspace under
//! `.pull/idlci/work/<subject>/` holding a linked git worktree of every repo
//! the job needs (the patch's repos at their source commits, the repos their
//! idl projects depend on at the workspace's current commits), at the same
//! paths as in the workspace, plus a copy of its pullfile. idl projects refer
//! to sibling repos by relative path (`../commons-ios`) and reject symlinks,
//! so the siblings are checked out too. Each subject keeps its tree between
//! jobs: it's moved to the new commits with `git checkout --detach --force`
//! and `git clean -fd`, which keeps ignored build output for incremental builds.
//! `cleanup` removes the trees of subjects with no job for some days (the
//! server runs it hourly; `idlci cleanup` on demand).
const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Prepared = struct {
    /// The work tree's root: run the project from `<root>/<project>`.
    root: []const u8,
    /// What was done, for the job's log.
    log: []const u8,
};

/// `.pull/idlci/work`
pub fn workDir(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, ".pull", "idlci", "work" });
}

/// The directory name of a subject's tree: the subject with ':' and '/' as '-'.
pub fn keyOf(a: Allocator, subject: []const u8) ![]const u8 {
    const key = try a.dupe(u8, subject);
    for (key) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_' or c.* == '.')) {
        c.* = '-';
    };
    return key;
}

/// `.pull/idlci/work/<keyOf(subject)>`.
pub fn dirFor(a: Allocator, root: []const u8, subject: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ try workDir(a, root), try keyOf(a, subject) });
}

/// One `<repo> <oid>` line of a job's checkout.
pub const Line = struct { repo: []const u8, oid: []const u8 };

pub fn parseCheckout(a: Allocator, text: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        try out.append(a, .{ .repo = line[0..sp], .oid = line[sp + 1 ..] });
    }
    return out.items;
}

/// The oid `checkout` records for `repo`.
pub fn oidOf(checkout: []const u8, repo: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, checkout, '\n');
    while (lines.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        if (std.mem.eql(u8, line[0..sp], repo)) return line[sp + 1 ..];
    }
    return null;
}

fn git(io: Io, a: Allocator, argv: []const []const u8) !void {
    const full = try std.mem.concat(a, []const u8, &.{ &.{"git"}, argv });
    const r = std.process.run(a, io, .{ .argv = full, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch return error.GitFailed;
    if (!r.term.success()) {
        std.log.scoped(.idlci).warn("git {s}: {s}", .{ try std.mem.join(a, " ", argv), std.mem.trim(u8, r.stderr, " \r\n") });
        return error.GitFailed;
    }
}

fn exists(io: Io, path: []const u8) bool {
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Check out `checkout` (see Line) in the subject's work tree.
pub fn prepare(io: Io, a: Allocator, root: []const u8, subject: []const u8, checkout: []const u8) !Prepared {
    const dir = try dirFor(a, root, subject);
    try Io.Dir.cwd().createDirPath(io, dir);
    var log: std.ArrayList(u8) = .empty;
    try log.print(a, "[idlci] work tree {s}\n", .{dir});
    for (try parseCheckout(a, checkout)) |line| {
        if (line.repo.len == 0 or std.mem.indexOf(u8, line.repo, "..") != null) return error.InvalidCheckout;
        const src = try std.fs.path.join(a, &.{ root, line.repo });
        const wt = try std.fs.path.join(a, &.{ dir, line.repo });
        const dot_git = try std.fs.path.join(a, &.{ wt, ".git" });
        var ok = false;
        if (exists(io, dot_git)) {
            if (git(io, a, &.{ "-C", wt, "checkout", "-q", "--detach", "--force", line.oid })) {
                git(io, a, &.{ "-C", wt, "clean", "-fdq" }) catch {};
                ok = true;
            } else |_| {
                // a broken tree (its repo moved, a stale lock): start over
                Io.Dir.cwd().deleteTree(io, wt) catch {};
                git(io, a, &.{ "-C", src, "worktree", "prune" }) catch {};
            }
        }
        if (!ok) {
            if (std.fs.path.dirname(wt)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
            if (exists(io, wt)) Io.Dir.cwd().deleteTree(io, wt) catch {};
            try git(io, a, &.{ "-C", src, "worktree", "add", "-q", "--detach", "--force", wt, line.oid });
        }
        try log.print(a, "[idlci]   {s} at {s}\n", .{ line.repo, line.oid[0..@min(line.oid.len, 10)] });
    }
    // a pull workspace: the root's pullfile, so idl and pull see the same repos
    const pf_src = try std.fs.path.join(a, &.{ root, "pullfile.plist" });
    if (Io.Dir.cwd().readFileAlloc(io, pf_src, a, .limited(16 << 20))) |data| {
        const pf_dst = try std.fs.path.join(a, &.{ dir, "pullfile.plist" });
        Io.Dir.cwd().writeFile(io, .{ .sub_path = pf_dst, .data = data }) catch {};
    } else |_| {}
    return .{ .root = dir, .log = log.items };
}


pub const Removed = struct {
    /// The tree's directory name under work/.
    name: []const u8,
    /// Its subject, null for a tree no job knows (left by a deleted database).
    subject: ?[]const u8,
    /// Days since its last job (or since it was last touched).
    idle_days: i64,

    pub fn jsonStringify(r: Removed, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "name", "subject", "idle_days" }) |f| {
            try w.objectField(f);
            try w.write(@field(r, f));
        }
        try w.endObject();
    }
};

/// Remove the work trees of subjects whose last job was queued more than
/// `days` days before `now` and that have nothing queued or running (and
/// unknown trees untouched that long). The caller holds the runner's
/// work_mutex, so no job prepares a tree meanwhile. With `dry_run`, only lists them.
pub fn cleanup(io: Io, a: Allocator, root: []const u8, store: *db.Store, days: u32, now: i64, dry_run: bool) ![]Removed {
    const dir = try workDir(a, root);
    var out: std.ArrayList(Removed) = .empty;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return out.items;
    defer d.close(io);
    const uses = try store.subjects(a);
    const limit: i64 = @as(i64, days) * 86400;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        var subject: ?db.Store.SubjectUse = null;
        for (uses) |u| if (std.mem.eql(u8, try keyOf(a, u.subject), e.name)) {
            subject = u;
            break;
        };
        const tree = try std.fs.path.join(a, &.{ dir, e.name });
        const last = if (subject) |u| u.last else blk: {
            const st = Io.Dir.cwd().statFile(io, tree, .{}) catch continue;
            break :blk @as(i64, @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s)));
        };
        if (subject) |u| if (u.active > 0) continue;
        if (now - last <= limit) continue;
        try out.append(a, .{ .name = try a.dupe(u8, e.name), .subject = if (subject) |u| u.subject else null, .idle_days = @divTrunc(now - last, 86400) });
    }
    if (dry_run) return out.items;
    for (out.items) |r| removeTree(io, a, try std.fs.path.join(a, &.{ dir, r.name }));
    return out.items;
}

/// Remove a subject's tree: each linked worktree through its repo (deepest
/// first, as nested repos sit inside their group's tree), then the rest.
pub fn removeTree(io: Io, a: Allocator, tree: []const u8) void {
    var linked: std.ArrayList(Linked) = .empty;
    findLinked(io, a, tree, 0, &linked);
    std.mem.sort(Linked, linked.items, {}, struct {
        fn gt(_: void, x: Linked, y: Linked) bool {
            return x.path.len > y.path.len;
        }
    }.gt);
    for (linked.items) |l| {
        git(io, a, &.{ "--git-dir", l.common, "worktree", "remove", "--force", "--force", l.path }) catch {
            Io.Dir.cwd().deleteTree(io, l.path) catch {};
        };
    }
    Io.Dir.cwd().deleteTree(io, tree) catch |e| std.log.scoped(.idlci).warn("can't remove {s}: {t}", .{ tree, e });
    for (linked.items) |l| git(io, a, &.{ "--git-dir", l.common, "worktree", "prune" }) catch {};
}

const Linked = struct { path: []const u8, common: []const u8 };

/// Linked worktrees under `dir`: their path and their repo's git dir (from the
/// `.git` file's `gitdir: <repo>/.git/worktrees/<name>`).
fn findLinked(io: Io, a: Allocator, dir: []const u8, depth: usize, out: *std.ArrayList(Linked)) void {
    if (depth > 4) return;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, ".git")) continue;
        const sub = std.fs.path.join(a, &.{ dir, e.name }) catch continue;
        const dot_git = std.fs.path.join(a, &.{ sub, ".git" }) catch continue;
        if (Io.Dir.cwd().readFileAlloc(io, dot_git, a, .limited(4096))) |text| {
            const line = std.mem.trim(u8, text, " \r\n");
            if (std.mem.startsWith(u8, line, "gitdir: ")) {
                const gitdir = line["gitdir: ".len..];
                // <common>/worktrees/<name>
                if (std.fs.path.dirname(gitdir)) |wts| if (std.fs.path.dirname(wts)) |common| {
                    out.append(a, .{ .path = sub, .common = common }) catch {};
                };
            }
        } else |_| {}
        findLinked(io, a, sub, depth + 1, out);
    }
}

/// The server's hourly cleanup (App.work_days > 0).
pub fn cleanupLoop(app: anytype) void {
    // first pass a minute after start, then hourly
    app.io.sleep(.fromSeconds(60), .awake) catch return;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        app.runner.work_mutex.lockUncancelable(app.io);
        const removed = cleanup(app.io, arena.allocator(), app.root, app.store, app.work_days, db.now(app.io), false) catch |e| blk: {
            std.log.scoped(.idlci).warn("work tree cleanup: {t}", .{e});
            break :blk &.{};
        };
        app.runner.work_mutex.unlock(app.io);
        for (removed) |r| std.log.scoped(.idlci).info("removed the work tree {s} ({d} days idle)", .{ r.name, r.idle_days });
        app.io.sleep(.fromSeconds(3600), .awake) catch return;
    }
}

test parseCheckout {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try parseCheckout(arena.allocator(), "core abc\ngroup/app def\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("group/app", lines[1].repo);
    try std.testing.expectEqualStrings("def", oidOf("core abc\ngroup/app def", "group/app").?);
    try std.testing.expect(oidOf("core abc", "lib") == null);
    try std.testing.expect(std.mem.endsWith(u8, try dirFor(arena.allocator(), "/r", "patch:group/app:12"), ".pull/idlci/work/patch-group-app-12"));
}

test "prepare, then cleanup removes idle trees through git" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const repo = try std.fs.path.join(a, &.{ root, "core" });
    try Io.Dir.cwd().createDirPath(io, repo);
    try tmp.dir.writeFile(io, .{ .sub_path = "core/a.txt", .data = "a\n" });
    try git(io, a, &.{ "-C", repo, "init", "-q" });
    try git(io, a, &.{ "-C", repo, "add", "a.txt" });
    try git(io, a, &.{ "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "a" });
    const head = std.mem.trimEnd(u8, (try std.process.run(a, io, .{ .argv = &.{ "git", "-C", repo, "rev-parse", "HEAD" } })).stdout, "\n");
    const subject = "patch:core:abc";
    const p = try prepare(io, a, root, subject, try std.fmt.allocPrint(a, "core {s}", .{head}));
    try std.testing.expect(exists(io, try std.fs.path.join(a, &.{ p.root, "core", "a.txt" })));

    const store = try db.Store.open(io, std.testing.allocator, try std.fs.path.join(a, &.{ root, ".pull", "idlci" }), null);
    defer store.close(std.testing.allocator);
    _ = try store.insert(a, .{ .project = "core", .subject = subject, .checkout = "x" }, .{});
    // queued: kept, however old
    try std.testing.expectEqual(@as(usize, 0), (try cleanup(io, a, root, store, 1, db.now(io) + 10 * 86400, false)).len);
    const job = (try store.claimNext(a)).?;
    try store.finish(job.id, .passed, 0);
    // recent: kept
    try std.testing.expectEqual(@as(usize, 0), (try cleanup(io, a, root, store, 1, db.now(io), false)).len);
    const removed = try cleanup(io, a, root, store, 1, db.now(io) + 3 * 86400, false);
    try std.testing.expectEqual(@as(usize, 1), removed.len);
    try std.testing.expectEqualStrings(subject, removed[0].subject.?);
    try std.testing.expect(!exists(io, p.root));
    const wts = (try std.process.run(a, io, .{ .argv = &.{ "git", "-C", repo, "worktree", "list" } })).stdout;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wts, "\n"));
}
