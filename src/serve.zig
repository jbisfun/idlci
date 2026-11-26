//! `idlci serve`: bind the listen address, claim `.pull/idlci/serve.lock` and
//! write `serve.addr` (discovery.announce), then run the workers and answer
//! HTTP, a thread per connection (the live console holds its connection).
//!
//! SIGTERM/SIGINT/SIGHUP: jobs run in process groups of their own (so cancel
//! can kill their compilers), which also means they'd outlive a server that is
//! simply killed. The handler only flags the signal; a watcher thread stops
//! the workers, SIGTERMs every running job's process group (SIGKILL after a
//! grace period; the jobs are recorded as cancelled), releases serve.addr and
//! re-raises the signal with its default action. A second signal exits at once.
const std = @import("std");
const discovery = @import("discovery");
const App = @import("app.zig").App;
const web = @import("web.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const log = std.log.scoped(.idlci);

pub const Options = struct {
    listen: []const u8,
    jobs: usize = 1,
    watch: ?u64 = null,
    work_days: u32 = 7,
};

/// seconds the jobs get to finish after SIGTERM before SIGKILL
pub const grace_s = 5;

pub fn run(io: Io, a: Allocator, root: []const u8, env: *const std.process.Environ.Map, opts: Options, err: *Io.Writer) !u8 {
    const gpa = std.heap.smp_allocator;
    const addr = Io.net.IpAddress.parseLiteral(opts.listen) catch {
        try err.print("error: invalid listen address '{s}' (HOST:PORT)\n", .{opts.listen});
        return 2;
    };
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        try err.print("Error: can't listen on {s}: {t}\n", .{ opts.listen, e });
        return 1;
    };
    defer server.deinit(io);
    const bound = try std.fmt.allocPrint(a, "{f}", .{server.socket.address});
    var serving = discovery.announce(io, gpa, root, .idlci, bound) catch |e| {
        if (e == error.AlreadyServing) {
            const other = discovery.read(io, a, root, .idlci) catch null;
            try err.print("Error: another idlci server runs for {s}{s}{s}\n", .{ root, if (other != null) " at " else "", other orelse "" });
        } else try err.print("Error: can't write .pull/idlci/serve.addr: {t}\n", .{e});
        return 1;
    };

    const app = try App.init(io, gpa, root, env, .{
        .jobs = opts.jobs,
        .watch = opts.watch,
        .work_days = opts.work_days,
        .workspace_name = std.fs.path.basename(root),
    });
    install(app, &serving);
    log.info("serving http://{s}/", .{bound});

    while (true) {
        const stream = server.accept(io) catch |e| {
            if (e == error.Canceled) break;
            log.err("accept: {t}", .{e});
            continue;
        };
        const t = std.Thread.spawn(.{}, web.serveConnection, .{ app, io, stream }) catch |e| {
            log.err("can't start a connection thread: {t}", .{e});
            stream.close(io);
            continue;
        };
        t.detach();
    }
    serving.release(io, gpa);
    return 0;
}

var signalled: std.atomic.Value(u8) = .init(0);
var installed = false;

fn handler(sig: std.posix.SIG) callconv(.c) void {
    if (signalled.swap(@intCast(@intFromEnum(sig)), .acq_rel) != 0) linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}

fn install(app: *App, serving: *discovery.Serving) void {
    if (installed) return;
    installed = true;
    const t = std.Thread.spawn(.{}, watchSignals, .{ app, serving }) catch |e| {
        log.err("can't watch for SIGTERM: {t}", .{e});
        return;
    };
    t.detach();
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
    // a pull job's pty closing hangs it up
    std.posix.sigaction(.HUP, &act, null);
}

fn watchSignals(app: *App, serving: *discovery.Serving) void {
    while (signalled.load(.acquire) == 0) app.io.sleep(.fromMilliseconds(100), .awake) catch {};
    const sig: std.posix.SIG = @enumFromInt(signalled.load(.acquire));
    log.info("{t}: cancelling the running jobs", .{sig});
    if (app.workers) app.runner.shutdown(grace_s);
    serving.release(app.io, std.heap.smp_allocator);
    // die of the signal, as without the handler
    const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = null }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(sig, &dfl, null);
    _ = linux.kill(linux.getpid(), sig);
    linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}
