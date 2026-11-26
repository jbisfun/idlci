//! `idlci serve --watch`: poll the repos of every project (and of its targets' dirs) and
//! queue `build` then `test` when a HEAD moves (the Rust idlci's watch.rs).
const std = @import("std");
const App = @import("app.zig").App;

const log = std.log.scoped(.idlci);

pub fn run(app: *App, every_s: u64) void {
    var seen_arena = std.heap.ArenaAllocator.init(app.gpa);
    defer seen_arena.deinit();
    // project path -> its sorted, deduplicated "worktree\nHEAD" lines
    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const list = app.projectList(a) catch &.{};
        for (list) |p| {
            var dirs: std.ArrayList([]const u8) = .empty;
            dirs.append(a, p.dir) catch continue;
            var msg: []const u8 = "";
            if (app.targets(a, p, &msg)) |targets| {
                for (targets) |t| dirs.append(a, std.fs.path.resolve(a, &.{ p.dir, t.dir }) catch continue) catch {};
            } else |_| {}
            var heads: std.ArrayList([]const u8) = .empty;
            for (dirs.items) |d| if (@import("projects.zig").headOid(app.io, a, d)) |h| heads.append(a, h) catch {};
            std.mem.sort([]const u8, heads.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            var key: std.ArrayList(u8) = .empty;
            var prev: ?[]const u8 = null;
            for (heads.items) |h| {
                if (prev) |pr| if (std.mem.eql(u8, pr, h)) continue;
                prev = h;
                key.appendSlice(a, h) catch {};
                key.append(a, '\n') catch {};
            }
            const sa = seen_arena.allocator();
            const gop = seen.getOrPut(app.gpa, p.path) catch continue;
            const changed = gop.found_existing and !std.mem.eql(u8, gop.value_ptr.*, key.items);
            if (!gop.found_existing) gop.key_ptr.* = sa.dupe(u8, p.path) catch continue;
            if (!gop.found_existing or changed) gop.value_ptr.* = sa.dupe(u8, key.items) catch continue;
            if (!changed) continue;
            for ([_]@import("db.zig").Command{ .build, .@"test" }) |command| {
                var emsg: []const u8 = "";
                if (app.enqueue(a, .{ .project = p.path, .command = command, .requested_by = .watch }, &emsg)) |e| {
                    if (!e.deduplicated) log.info("watch: {s} moved, queued #{d}", .{ p.path, e.job.id });
                } else |e| log.err("watch: {s}: {t} {s}", .{ p.path, e, emsg });
            }
        }
        app.io.sleep(.fromSeconds(@intCast(every_s)), .awake) catch {};
    }
}
