//! idlci: local CI for the idl projects of a pull workspace. A SQLite job
//! queue (`.pull/idlci/idlci.db`), executor threads running `idl
//! build|test|lint|fmt --check|check|clean` as process groups, `--watch` HEAD
//! polling, patch/stack runs in work trees for cpull, Jenkins-style pages on
//! the workspace's shared theme, a JSON API (theme docs/workspace-tools.md
//! §5), the CLI and `idlci mcp`.
const std = @import("std");
const cli = @import("cli.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = init.minimal.environ });
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.skip();
    while (it.next()) |arg| try args.append(a, arg);

    // streaming: a pull job's log is a file, and a positional writer would
    // write from offset 0 over what std.log appended
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    var env = try std.process.Environ.createMap(init.minimal.environ, gpa);
    defer env.deinit();
    const cwd = try std.process.currentPathAlloc(io, a);

    const code = cli.run(io, a, args.items, &env, cwd, &stdout.interface, &stderr.interface) catch |e| blk: {
        stderr.interface.print("Error: {t}\n", .{e}) catch {};
        break :blk 1;
    };
    stdout.interface.flush() catch {};
    return code;
}

test {
    _ = @import("db.zig");
    _ = @import("projects.zig");
    _ = @import("fmt.zig");
    _ = @import("work.zig");
    _ = @import("migrate.zig");
    _ = @import("status.zig");
    _ = @import("runs.zig");
    _ = @import("feed.zig");
    _ = @import("pullfile.zig");
    _ = @import("mcp_args.zig");
    _ = @import("mcp.zig");
    _ = @import("test.zig");
}
