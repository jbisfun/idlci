//! Workers: run queued jobs as `idl` process groups logging to `logs/<id>.log`
//! (the Rust idlci's runner.rs). Each executor is a thread.
const std = @import("std");
const db = @import("db.zig");
const fmt = @import("fmt.zig");
const work = @import("work.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.idlci);

pub const Runner = struct {
    gpa: Allocator,
    io: Io,
    store: *db.Store,
    root: []const u8,
    idl: []const u8,
    executors: usize,
    /// The workers' environment: the server's plus PULL_ROOT.
    env: *const std.process.Environ.Map,
    mutex: Io.Mutex = .init,
    /// job id -> process group and executor index
    running: std.AutoHashMapUnmanaged(i64, Slot) = .empty,
    cancelling: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// bumped by `kick`, so an idle worker claims a new job without waiting out its poll
    kicks: std.atomic.Value(u32) = .init(0),
    /// set by `shutdown`: workers stop claiming jobs
    stopping: std.atomic.Value(bool) = .init(false),
    /// serializes preparing the work trees of patch/stack jobs
    work_mutex: Io.Mutex = .init,

    const Slot = struct { pgid: i32, executor: usize };

    pub const Executor = struct {
        number: usize,
        job: ?db.Job,
        /// Estimated progress 0..=99 from the last passed run of the same project + command.
        progress: ?i64,
    };

    /// Fail jobs a previous server left running and kill their leftover process groups.
    pub fn recover(r: *Runner) !void {
        var arena = std.heap.ArenaAllocator.init(r.gpa);
        defer arena.deinit();
        for (try r.store.recover(arena.allocator())) |rec| {
            if (rec.pid) |pid| if (isIdl(r.io, pid)) {
                log.warn("killing leftover process group {d} of job #{d}", .{ pid, rec.job.id });
                killGroup(pid, .TERM);
                killLater(r.io, pid);
            };
            append(r.io, rec.job.log, "\n[idlci] server restarted while this job was running; marked failed\n");
        }
    }

    pub fn start(r: *Runner) !void {
        for (0..r.executors) |n| {
            const t = try std.Thread.spawn(.{}, worker, .{ r, n });
            t.detach();
        }
    }

    /// Wake the workers after queueing.
    pub fn kick(r: *Runner) void {
        _ = r.kicks.fetchAdd(1, .release);
    }

    fn worker(r: *Runner, n: usize) void {
        while (!r.stopping.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(r.gpa);
            defer arena.deinit();
            const job = r.store.claimNext(arena.allocator()) catch |e| {
                log.err("worker {d}: {t}", .{ n, e });
                r.io.sleep(.fromSeconds(5), .awake) catch {};
                continue;
            };
            if (job) |j| {
                r.run(arena.allocator(), j, n);
                continue;
            }
            // idle: poll every 5s, or sooner after a kick
            const seen = r.kicks.load(.acquire);
            for (0..50) |_| {
                r.io.sleep(.fromMilliseconds(100), .awake) catch {};
                if (r.kicks.load(.acquire) != seen) break;
            }
        }
    }

    fn run(r: *Runner, a: Allocator, job: db.Job, executor: usize) void {
        const io = r.io;
        const args = job.command.idlArgs(a, job.configuration, job.strict, job.targets) catch return;
        // a patch or stack job runs in its own work tree with the subject's commits checked out
        var root = r.root;
        var env = r.env;
        var prep_log: []const u8 = "";
        if (job.subject != null and job.checkout != null) {
            r.work_mutex.lockUncancelable(io);
            const prepared = work.prepare(io, a, r.root, job.subject.?, job.checkout.?);
            r.work_mutex.unlock(io);
            if (prepared) |p| {
                root = p.root;
                prep_log = p.log;
                const map = a.create(std.process.Environ.Map) catch return;
                map.* = r.env.clone(a) catch return;
                map.put("PULL_ROOT", root) catch return;
                env = map;
            } else |e| {
                const text = std.fmt.allocPrint(a, "[idlci] job #{d}: can't prepare the work tree for {s}: {t}\n", .{ job.id, job.subject.?, e }) catch "";
                Io.Dir.cwd().writeFile(io, .{ .sub_path = job.log, .data = text }) catch {};
                r.store.finish(job.id, .failed, null) catch {};
                return;
            }
        }
        const dir = std.fs.path.join(a, &.{ root, job.project }) catch return;
        const header = std.fmt.allocPrint(a, "{s}[idlci] job #{d} on executor #{d} in {s}, started {s}\n[idlci] git {s} {s}@{s}{s}\n$ idl {s}\n", .{
            prep_log,
            job.id,
            executor + 1,
            dir,
            fmt.dt(a, job.started orelse db.now(io)) catch "",
            job.git.repo orelse "-",
            job.git.branch orelse "-",
            job.git.head orelse "-",
            if (job.git.dirty) " (dirty)" else "",
            std.mem.join(a, " ", args) catch return,
        }) catch return;
        const argv = std.mem.concat(a, []const u8, &.{ &.{r.idl}, args }) catch return;

        const file = Io.Dir.cwd().createFile(io, job.log, .{}) catch |e| {
            log.err("job #{d}: can't create {s}: {t}", .{ job.id, job.log, e });
            r.store.finish(job.id, .failed, null) catch {};
            return;
        };
        defer file.close(io);
        file.writeStreamingAll(io, header) catch {};
        var child = std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = dir },
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
            // its own process group, so cancel kills compilers too
            .pgid = 0,
        }) catch |e| {
            append(io, job.log, std.fmt.allocPrint(a, "[idlci] failed to start {s}: {t}\n", .{ r.idl, e }) catch "");
            r.store.finish(job.id, .failed, null) catch {};
            return;
        };
        const pid: ?i32 = if (child.id) |p| @intCast(p) else null;
        if (pid) |p| {
            r.mutex.lockUncancelable(io);
            r.running.put(r.gpa, job.id, .{ .pgid = p, .executor = executor }) catch {};
            r.mutex.unlock(io);
        }
        r.store.setPid(job.id, pid) catch {};
        const term = child.wait(io);
        r.mutex.lockUncancelable(io);
        _ = r.running.remove(job.id);
        const cancelled = r.cancelling.remove(job.id);
        r.mutex.unlock(io);
        const code: ?i32 = if (term) |t| switch (t) {
            .exited => |c| c,
            .signal => |s| 128 + @as(i32, @intCast(@intFromEnum(s))),
            else => null,
        } else |_| null;
        const status: db.Status = if (cancelled) .cancelled else if (term) |t| (if (t.success()) .passed else .failed) else |_| .failed;
        const took = if (job.started) |s| db.now(io) - s else 0;
        var code_buf: [16]u8 = undefined;
        const code_text = if (code) |c| std.fmt.bufPrint(&code_buf, "{d}", .{c}) catch "-" else "-";
        append(io, job.log, std.fmt.allocPrint(a, "\n[idlci] finished: {t} (exit {s}) in {d}s, at {s}\n", .{ status, code_text, took, fmt.dt(a, db.now(io)) catch "" }) catch "");
        r.store.finish(job.id, status, code) catch |e| log.err("job #{d}: {t}", .{ job.id, e });
    }

    pub const CancelError = error{NotQueuedOrRunning};

    /// Cancel a queued job, or SIGTERM (then SIGKILL after 5s) a running job's process group.
    pub fn cancel(r: *Runner, id: i64) !void {
        if (try r.store.cancelQueued(id)) return;
        r.mutex.lockUncancelable(r.io);
        const slot = r.running.get(id);
        if (slot != null) r.cancelling.put(r.gpa, id, {}) catch {};
        r.mutex.unlock(r.io);
        const s = slot orelse return error.NotQueuedOrRunning;
        killGroup(s.pgid, .TERM);
        // children (compilers) may outlive the group leader, so kill the group regardless
        killLater(r.io, s.pgid);
    }

    /// Stop for good (the server got SIGTERM): no new jobs, SIGTERM every
    /// running job's process group, wait up to `grace_s` for them to finish
    /// (they are recorded as cancelled), then SIGKILL what's left.
    pub fn shutdown(r: *Runner, grace_s: u32) void {
        r.stopping.store(true, .release);
        r.mutex.lockUncancelable(r.io);
        var pgids: [64]i32 = undefined;
        var count: usize = 0;
        var it = r.running.iterator();
        while (it.next()) |e| {
            r.cancelling.put(r.gpa, e.key_ptr.*, {}) catch {};
            if (count < pgids.len) {
                pgids[count] = e.value_ptr.pgid;
                count += 1;
            }
        }
        r.mutex.unlock(r.io);
        for (pgids[0..count]) |p| killGroup(p, .TERM);
        var waited: u32 = 0;
        while (waited < grace_s * 10) : (waited += 1) {
            r.mutex.lockUncancelable(r.io);
            const left = r.running.count();
            r.mutex.unlock(r.io);
            if (left == 0) break;
            r.io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        for (pgids[0..count]) |p| killGroup(p, .KILL);
        // let the workers record the outcome
        r.io.sleep(.fromMilliseconds(200), .awake) catch {};
    }

    /// The executors and the job each one runs.
    pub fn executorList(r: *Runner, a: Allocator) ![]Executor {
        r.mutex.lockUncancelable(r.io);
        var slots: std.ArrayList(struct { id: i64, slot: Slot }) = .empty;
        var it = r.running.iterator();
        while (it.next()) |e| slots.append(a, .{ .id = e.key_ptr.*, .slot = e.value_ptr.* }) catch {};
        r.mutex.unlock(r.io);
        const out = try a.alloc(Executor, r.executors);
        for (out, 0..) |*e, n| {
            e.* = .{ .number = n + 1, .job = null, .progress = null };
            for (slots.items) |s| if (s.slot.executor == n) {
                e.job = try r.store.get(a, s.id);
            };
            if (e.job) |j| if (j.started) |started| if (try r.store.lastDuration(j.project, j.command)) |total| {
                const spent = db.now(r.io) - started;
                e.progress = @min(@divTrunc(spent * 100, @max(total, 1)), 99);
            };
        }
        return out;
    }
};

fn killGroup(pgid: i32, sig: std.posix.SIG) void {
    std.posix.kill(-pgid, sig) catch {};
}

/// SIGKILL the group after 5s, from a short-lived thread.
fn killLater(io: Io, pgid: i32) void {
    const t = std.Thread.spawn(.{}, struct {
        fn f(io_: Io, p: i32) void {
            io_.sleep(.fromSeconds(5), .awake) catch {};
            killGroup(p, .KILL);
        }
    }.f, .{ io, pgid }) catch return;
    t.detach();
}

pub fn append(io: Io, path: []const u8, text: []const u8) void {
    const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch
        Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    const len = f.length(io) catch return;
    f.writePositionalAll(io, text, len) catch {};
}

/// Whether `pid` is alive and an `idl` process (guards against pid reuse).
fn isIdl(io: Io, pid: i32) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return false;
    var buf: [4096]u8 = undefined;
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    const argv0 = std.mem.sliceTo(buf[0..n], 0);
    return std.mem.endsWith(u8, argv0, "idl");
}
