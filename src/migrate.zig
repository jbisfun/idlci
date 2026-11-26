//! Moving the CI's state back from cpull. While the CI lived inside cpull, it
//! kept idlci's database as `.pull/cpull/ci/ci.db` (with `logs/` and `work/`
//! beside it). On start idlci adopts that database when it is newer than its
//! own `.pull/idlci/idlci.db` (or idlci has none): the current idlci.db is kept
//! as `idlci.db.bak`, ci.db is copied in (VACUUM INTO, consistent even while
//! WAL is in use), the jobs' log paths are pointed at `.pull/idlci/logs/`, the
//! log files are copied over and the work trees moved (and `git worktree
//! repair`ed). cpull's files are left in place otherwise, so an old cpull
//! still running keeps working; idlci's own copy is newer from then on.
const std = @import("std");
const sqlite = @import("sqlite");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.idlci);

/// `.pull/cpull/ci`, where cpull kept the CI's state.
pub fn cpullDir(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, ".pull", "cpull", "ci" });
}

/// The newest mtime of a database and its WAL, or null when it doesn't exist.
fn dbMtime(io: Io, a: Allocator, path: []const u8) ?i96 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    var t = st.mtime.nanoseconds;
    const wal = std.fmt.allocPrint(a, "{s}-wal", .{path}) catch return t;
    if (Io.Dir.cwd().statFile(io, wal, .{})) |w| t = @max(t, w.mtime.nanoseconds) else |_| {}
    return t;
}

fn deleteDb(io: Io, a: Allocator, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const p = std.fmt.allocPrint(a, "{s}{s}", .{ path, suffix }) catch continue;
        Io.Dir.cwd().deleteFile(io, p) catch {};
    }
}

fn vacuumInto(a: Allocator, from: []const u8, to: []const u8) !void {
    var src = try sqlite.Db.init(.{ .mode = .{ .File = try a.dupeSentinel(u8, from, 0) }, .open_flags = .{ .write = false } });
    defer src.deinit();
    _ = try src.pragma(void, .{}, "busy_timeout", "5000");
    try src.execDynamic("VACUUM INTO ?", .{}, .{to});
}

pub const Adopted = struct { jobs: usize, logs: usize, work: bool };

/// Adopt cpull's ci.db when it is newer than idlci.db; null when there was nothing to do.
pub fn adopt(io: Io, a: Allocator, root: []const u8) !?Adopted {
    const old_dir = try cpullDir(a, root);
    const old_db = try std.fs.path.join(a, &.{ old_dir, "ci.db" });
    const old_t = dbMtime(io, a, old_db) orelse return null;
    const dir = try db.dataDir(a, root);
    try Io.Dir.cwd().createDirPath(io, dir);
    const new_db = try std.fs.path.join(a, &.{ dir, db.db_name });
    if (dbMtime(io, a, new_db)) |new_t| {
        if (new_t >= old_t) return null;
        const bak = try std.fmt.allocPrint(a, "{s}.bak", .{new_db});
        deleteDb(io, a, bak);
        try vacuumInto(a, new_db, bak);
        deleteDb(io, a, new_db);
        log.info("keeping the older {s} as {s}", .{ new_db, bak });
    }
    try vacuumInto(a, old_db, new_db);

    // the jobs' logs now live in .pull/idlci/logs
    var out: Adopted = .{ .jobs = 0, .logs = 0, .work = false };
    {
        var conn = try sqlite.Db.init(.{ .mode = .{ .File = try a.dupeSentinel(u8, new_db, 0) }, .open_flags = .{ .write = true } });
        defer conn.deinit();
        const old_prefix = try std.fmt.allocPrint(a, "{s}/logs/", .{old_dir});
        const new_prefix = try std.fmt.allocPrint(a, "{s}/logs/", .{dir});
        try conn.exec("UPDATE jobs SET log = ? || substr(log, ?) WHERE substr(log, 1, ?) = ?", .{}, .{
            new_prefix, @as(i64, @intCast(old_prefix.len + 1)), @as(i64, @intCast(old_prefix.len)), old_prefix,
        });
        const n = try conn.one(struct { n: i64 }, "SELECT COUNT(*) FROM jobs", .{}, .{});
        out.jobs = if (n) |x| @intCast(x.n) else 0;
    }
    const logs = try std.fs.path.join(a, &.{ dir, "logs" });
    try Io.Dir.cwd().createDirPath(io, logs);
    const old_logs = try std.fs.path.join(a, &.{ old_dir, "logs" });
    if (Io.Dir.cwd().openDir(io, old_logs, .{ .iterate = true })) |src_dir| {
        var src = src_dir;
        defer src.close(io);
        var dst = try Io.Dir.cwd().openDir(io, logs, .{});
        defer dst.close(io);
        var it = src.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file) continue;
            src.copyFile(e.name, dst, e.name, io, .{ .replace = true }) catch |err| {
                log.warn("can't copy log {s}: {t}", .{ e.name, err });
                continue;
            };
            out.logs += 1;
        }
    } else |_| {}

    // the patch/stack work trees: moved, then re-linked to their repos
    const old_work = try std.fs.path.join(a, &.{ old_dir, "work" });
    const work = try std.fs.path.join(a, &.{ dir, "work" });
    const have_work = if (Io.Dir.cwd().statFile(io, work, .{})) |_| true else |_| false;
    if (!have_work) if (Io.Dir.cwd().statFile(io, old_work, .{})) |_| {
        if (Io.Dir.cwd().rename(old_work, Io.Dir.cwd(), work, io)) {
            repairTrees(io, a, work, 0);
            out.work = true;
        } else |e| log.warn("can't move {s} to {s}: {t}", .{ old_work, work, e });
    } else |_| {};
    log.info("adopted cpull's {s}: {d} jobs, {d} logs{s}", .{ old_db, out.jobs, out.logs, if (out.work) ", work trees" else "" });
    return out;
}

/// `git worktree repair` in every linked worktree (a dir with a `.git` file) under `dir`.
pub fn repairTrees(io: Io, a: Allocator, dir: []const u8, depth: usize) void {
    if (depth > 4) return;
    var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const sub = std.fs.path.join(a, &.{ dir, e.name }) catch continue;
        const dot_git = std.fs.path.join(a, &.{ sub, ".git" }) catch continue;
        const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch {
            repairTrees(io, a, sub, depth + 1);
            continue;
        };
        if (st.kind != .file) continue;
        const r = std.process.run(a, io, .{ .argv = &.{ "git", "-C", sub, "worktree", "repair" }, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 16) }) catch continue;
        if (!r.term.success()) log.warn("git worktree repair in {s}: {s}", .{ sub, std.mem.trim(u8, r.stderr, " \r\n") });
    }
}

test "adopts a newer cpull ci.db and points the logs at idlci" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try std.testing.expect(try adopt(io, a, root) == null);

    // cpull's store with one job and its log
    const old_dir = try cpullDir(a, root);
    {
        const store = try db.Store.open(io, std.testing.allocator, old_dir, null);
        defer store.close(std.testing.allocator);
        // Store.open names its file idlci.db: make it cpull's ci.db
        const job, _ = try store.insert(a, .{ .project = "p", .command = .build }, .{});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = job.log, .data = "hello\n" });
    }
    try Io.Dir.cwd().rename(try std.fs.path.join(a, &.{ old_dir, db.db_name }), Io.Dir.cwd(), try std.fs.path.join(a, &.{ old_dir, "ci.db" }), io);
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ old_dir, db.db_name, suffix })) catch {};
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ old_dir, "work", "patch-r-1" }));

    const got = (try adopt(io, a, root)).?;
    try std.testing.expectEqual(@as(usize, 1), got.jobs);
    try std.testing.expectEqual(@as(usize, 1), got.logs);
    try std.testing.expect(got.work);
    const dir = try db.dataDir(a, root);
    const store = try db.Store.open(io, std.testing.allocator, dir, null);
    defer store.close(std.testing.allocator);
    const job = (try store.get(a, 1)).?;
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/logs/1.log", .{dir}), job.log);
    try std.testing.expectEqualStrings("hello\n", try Io.Dir.cwd().readFileAlloc(io, job.log, a, .limited(100)));
    // idlci's copy is newer now: nothing to adopt
    try std.testing.expect(try adopt(io, a, root) == null);
}
