//! The CI service: the store, the workers, the project and target caches and
//! queueing (the Rust idlci's web.rs `App`).
const std = @import("std");
const db = @import("db.zig");
const projects = @import("projects.zig");
const Runner = @import("runner.zig").Runner;
const pullfile = @import("pullfile.zig");
const migrate = @import("migrate.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.idlci);

pub const Options = struct {
    /// Concurrent jobs (builds are CPU-heavy).
    jobs: usize = 1,
    /// Queue build + test when a project's git HEAD changes, every this many seconds.
    watch: ?u64 = null,
    /// The workspace's name, for the crumbs.
    workspace_name: []const u8 = "workspace",
    /// Run the executors and the watcher (tests turn them off). The caller
    /// holds `.pull/idlci/serve.lock` (discovery.announce), so one server per
    /// workspace runs jobs.
    start_workers: bool = true,
    /// Remove a patch/stack work tree this many days after its last job (0 = never).
    work_days: u32 = 7,
};

pub const Error = error{ BadRequest, NotFound };

/// Latest-job reference used in project views.
pub const Brief = struct {
    id: i64,
    status: db.Status,
    created: i64,
    started: ?i64,
    finished: ?i64,

    pub fn of(j: db.Job) Brief {
        return .{ .id = j.id, .status = j.status, .created = j.created, .started = j.started, .finished = j.finished };
    }
};

pub const ProjectView = struct {
    path: []const u8,
    name: []const u8,
    git: db.GitInfo,
    targets: []const projects.Target,
    targets_error: ?[]const u8,
    /// Latest job per command, in command name order (idlci's BTreeMap).
    last: []const struct { command: []const u8, brief: Brief },
    last_build: ?Brief,
    last_success: ?Brief,
    last_failure: ?Brief,
    running: bool,
    /// Pass rate (%) of the last 5 passed/failed jobs.
    health: ?i64,

    pub fn jsonStringify(p: ProjectView, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "path", "name" }) |f| {
            try w.objectField(f);
            try w.write(@field(p, f));
        }
        inline for (.{ "repo", "branch", "head", "dirty" }) |f| {
            try w.objectField(f);
            try w.write(@field(p.git, f));
        }
        inline for (.{ "targets", "targets_error" }) |f| {
            try w.objectField(f);
            try w.write(@field(p, f));
        }
        try w.objectField("last");
        try w.beginObject();
        for (p.last) |l| {
            try w.objectField(l.command);
            try w.write(l.brief);
        }
        try w.endObject();
        inline for (.{ "last_build", "last_success", "last_failure", "running", "health" }) |f| {
            try w.objectField(f);
            try w.write(@field(p, f));
        }
        try w.endObject();
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    store: *db.Store,
    runner: Runner,
    watch: ?u64,
    workspace_name: []const u8,
    /// the executors (and the watcher) run
    workers: bool,
    work_days: u32,
    env: std.process.Environ.Map,

    mutex: Io.Mutex = .init,
    projects_arena: std.heap.ArenaAllocator,
    projects_cache: ?struct { at: i64, list: []const projects.Project } = null,
    /// `idl list` per project dir, with the idlproj.yml mtime it was read at
    targets_cache: std.StringHashMapUnmanaged(TargetEntry) = .empty,
    /// the pull repo holding each project dir (never changes)
    repo_cache: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    cache_arena: std.heap.ArenaAllocator,
    pullfile_arena: std.heap.ArenaAllocator,
    pullfile_cache: ?struct { mtime: i96, repos: []const pullfile.Repo } = null,

    const TargetEntry = struct { mtime: i96, arena: std.heap.ArenaAllocator, list: []const projects.Target };

    /// Open the store (adopting cpull's copy of it when newer), recover jobs a
    /// previous server left running, and start the workers and the watcher.
    pub fn init(io: Io, gpa: Allocator, root_in: []const u8, environ: *const std.process.Environ.Map, opts: Options) !*App {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // the real path, as the CLI and the MCP tools compare it with theirs
        const root = try Io.Dir.cwd().realPathFileAlloc(io, root_in, a);
        const dir = try db.dataDir(a, root);
        if (opts.start_workers) _ = migrate.adopt(io, a, root) catch |e| log.err("can't adopt cpull's CI database: {t}", .{e});
        const store = try db.Store.open(io, gpa, dir, null);
        app.* = .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, root),
            .store = store,
            .runner = undefined,
            .watch = opts.watch,
            .workspace_name = try gpa.dupe(u8, opts.workspace_name),
            .workers = opts.start_workers,
            .work_days = opts.work_days,
            .env = try environ.clone(gpa),
            .projects_arena = .init(gpa),
            .cache_arena = .init(gpa),
            .pullfile_arena = .init(gpa),
        };
        try app.env.put("PULL_ROOT", root);
        app.runner = .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .root = app.root,
            .idl = try projects.idlPath(io, app.cache_arena.allocator(), &app.env),
            .executors = @max(opts.jobs, 1),
            .env = &app.env,
        };

        if (app.workers) {
            try app.runner.recover();
            try app.runner.start();
            if (opts.watch) |secs| {
                const t = try std.Thread.spawn(.{}, @import("watch.zig").run, .{ app, secs });
                t.detach();
            }
            if (opts.work_days > 0) {
                const t = try std.Thread.spawn(.{}, @import("work.zig").cleanupLoop, .{app});
                t.detach();
            }
            log.info("root {s}  idl {s}  executors {d}{s}", .{ root, app.runner.idl, app.runner.executors, if (opts.watch != null) "  watching" else "" });
        }
        return app;
    }

    /// Discovered projects, rescanned at most every 30s; copied into `a`.
    pub fn projectList(app: *App, a: Allocator) ![]projects.Project {
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const now = db.now(app.io);
        if (app.projects_cache == null or now - app.projects_cache.?.at >= 30) {
            _ = app.projects_arena.reset(.retain_capacity);
            const list = try projects.discover(app.io, app.projects_arena.allocator(), app.root);
            app.projects_cache = .{ .at = now, .list = list };
        }
        const src = app.projects_cache.?.list;
        const out = try a.alloc(projects.Project, src.len);
        for (src, out) |p, *o| o.* = .{ .path = try a.dupe(u8, p.path), .dir = try a.dupe(u8, p.dir) };
        return out;
    }

    /// The pull repo (relative to the root) holding a project dir.
    pub fn repoOf(app: *App, dir: []const u8) ?[]const u8 {
        app.mutex.lockUncancelable(app.io);
        if (app.repo_cache.get(dir)) |r| {
            app.mutex.unlock(app.io);
            return r;
        }
        app.mutex.unlock(app.io);
        const ca = app.cache_arena.allocator();
        var tmp = std.heap.ArenaAllocator.init(app.gpa);
        defer tmp.deinit();
        const name = projects.repoName(app.io, tmp.allocator(), app.root, dir);
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        const key = ca.dupe(u8, dir) catch return name;
        const value: ?[]const u8 = if (name) |n| (ca.dupe(u8, n) catch null) else null;
        app.repo_cache.put(app.gpa, key, value) catch {};
        return value;
    }

    /// The pullfile's repos (re-read when pullfile.plist changes); copied into `a`.
    pub fn repos(app: *App, a: Allocator) ![]const pullfile.Repo {
        const path = try std.fs.path.join(a, &.{ app.root, pullfile.file_name });
        const st = Io.Dir.cwd().statFile(app.io, path, .{}) catch return &.{};
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        if (app.pullfile_cache == null or app.pullfile_cache.?.mtime != st.mtime.nanoseconds) {
            _ = app.pullfile_arena.reset(.retain_capacity);
            const pa = app.pullfile_arena.allocator();
            const data = Io.Dir.cwd().readFileAlloc(app.io, path, pa, .limited(16 << 20)) catch return &.{};
            const pf = pullfile.parse(pa, data) catch |e| {
                log.warn("{s}: {t}", .{ path, e });
                return &.{};
            };
            app.pullfile_cache = .{ .mtime = st.mtime.nanoseconds, .repos = pf.repos };
        }
        const src = app.pullfile_cache.?.repos;
        const out = try a.alloc(pullfile.Repo, src.len);
        for (src, out) |r, *o| o.* = .{ .name = try a.dupe(u8, r.name), .branch = try a.dupe(u8, r.branch) };
        return out;
    }

    const RepoLookup = struct {
        app: *App,
        pub fn get(l: RepoLookup, dir: []const u8) ?[]const u8 {
            return l.app.repoOf(dir);
        }
    };

    pub fn resolve(app: *App, a: Allocator, arg: []const u8, msg: *[]const u8) !projects.Project {
        const list = try app.projectList(a);
        return projects.resolve(a, app.root, list, arg, RepoLookup{ .app = app }, msg) catch |e| switch (e) {
            error.UnknownProject => error.NotFound,
            else => e,
        };
    }

    /// `idl list` for a project, cached until idlproj.yml changes; copied into `a`.
    pub fn targets(app: *App, a: Allocator, p: projects.Project, msg: *[]const u8) ![]projects.Target {
        const yml = try std.fs.path.join(a, &.{ p.dir, "idlproj.yml" });
        const st = Io.Dir.cwd().statFile(app.io, yml, .{}) catch |e| {
            msg.* = try std.fmt.allocPrint(a, "{s}: {t}", .{ yml, e });
            return error.IdlListFailed;
        };
        const mtime = st.mtime.nanoseconds;
        app.mutex.lockUncancelable(app.io);
        if (app.targets_cache.get(p.dir)) |entry| if (entry.mtime == mtime) {
            defer app.mutex.unlock(app.io);
            return copyTargets(a, entry.list);
        };
        app.mutex.unlock(app.io);

        var entry: TargetEntry = .{ .mtime = mtime, .arena = .init(app.gpa), .list = &.{} };
        var list_msg: []const u8 = "";
        entry.list = projects.targets(app.io, entry.arena.allocator(), app.runner.idl, p.dir, &list_msg) catch |e| {
            msg.* = a.dupe(u8, list_msg) catch "";
            entry.arena.deinit();
            return e;
        };
        const out = try copyTargets(a, entry.list);
        app.mutex.lockUncancelable(app.io);
        defer app.mutex.unlock(app.io);
        if (app.targets_cache.getPtr(p.dir)) |old| {
            old.arena.deinit();
            old.* = entry;
        } else {
            try app.targets_cache.put(app.gpa, try app.cache_arena.allocator().dupe(u8, p.dir), entry);
        }
        return out;
    }

    /// The git state of a project dir, with its pull repo.
    pub fn gitInfo(app: *App, a: Allocator, dir: []const u8) db.GitInfo {
        var info = projects.gitInfo(app.io, a, dir);
        if (info.head != null or info.branch != null) info.repo = app.repoOf(dir);
        return info;
    }

    /// Queue a job (`msg` explains a BadRequest/NotFound).
    pub fn enqueue(app: *App, a: Allocator, new_in: db.NewJob, msg: *[]const u8) !db.Enqueued {
        return app.enqueueWith(a, new_in, null, msg);
    }

    /// Queue a job recording `git` as its git state rather than the project
    /// dir's (patch and stack jobs, whose commits aren't checked out there).
    pub fn enqueueWith(app: *App, a: Allocator, new_in: db.NewJob, git: ?db.GitInfo, msg: *[]const u8) !db.Enqueued {
        var new = new_in;
        const p = app.resolve(a, new.project, msg) catch |e| return if (e == error.NotFound) error.BadRequest else e;
        if (new.targets.len > 0) {
            var tmsg: []const u8 = "";
            if (app.targets(a, p, &tmsg)) |known| {
                var unknown: std.ArrayList([]const u8) = .empty;
                for (new.targets) |t| {
                    if (for (known) |k| (if (std.mem.eql(u8, k.name, t)) break false) else true) try unknown.append(a, t);
                }
                if (unknown.items.len > 0) {
                    var names: std.ArrayList([]const u8) = .empty;
                    for (known) |k| try names.append(a, k.name);
                    msg.* = try std.fmt.allocPrint(a, "unknown target(s) {s} in {s}; targets: {s}", .{
                        try std.mem.join(a, ", ", unknown.items), p.path, try std.mem.join(a, ", ", names.items),
                    });
                    return error.BadRequest;
                }
            } else |_| {}
        }
        new.project = p.path;
        const job, const created = try app.store.insert(a, new, git orelse app.gitInfo(a, p.dir));
        if (created) app.runner.kick();
        return .{ .job = job, .deduplicated = !created };
    }

    pub fn projectViews(app: *App, a: Allocator, only: ?[]const u8) ![]ProjectView {
        const latest = try app.store.latestPerCommand(a);
        const finished = try app.store.finishedPerProject(a, 50);
        const active = try app.store.active(a);
        var out: std.ArrayList(ProjectView) = .empty;
        for (try app.projectList(a)) |p| {
            if (only) |o| if (!std.mem.eql(u8, o, p.path)) continue;
            var terr: []const u8 = "";
            const tlist = app.targets(a, p, &terr) catch &.{};
            var mine: std.ArrayList(db.Job) = .empty;
            for (finished) |j| if (std.mem.eql(u8, j.project, p.path)) try mine.append(a, j);
            // the weather counts passed/failed only (aborted builds don't affect it, like Jenkins)
            var rated: usize = 0;
            var passed: i64 = 0;
            for (mine.items) |j| {
                if (j.status == .cancelled) continue;
                if (rated == 5) break;
                rated += 1;
                if (j.status == .passed) passed += 1;
            }
            const Last = @typeInfo(@FieldType(ProjectView, "last")).pointer.child;
            var last: std.ArrayList(Last) = .empty;
            for (latest) |j| if (std.mem.eql(u8, j.project, p.path)) try last.append(a, .{ .command = j.command.name(), .brief = .of(j) });
            std.mem.sort(Last, last.items, {}, struct {
                fn lt(_: void, x: Last, y: Last) bool {
                    return std.mem.lessThan(u8, x.command, y.command);
                }
            }.lt);
            var success: ?Brief = null;
            var failure: ?Brief = null;
            for (mine.items) |j| {
                if (success == null and j.status == .passed) success = .of(j);
                if (failure == null and j.status == .failed) failure = .of(j);
            }
            var running = false;
            for (active) |j| if (j.status == .running and std.mem.eql(u8, j.project, p.path)) {
                running = true;
            };
            try out.append(a, .{
                .path = p.path,
                .name = std.fs.path.basenamePosix(p.path),
                .git = app.gitInfo(a, p.dir),
                .targets = tlist,
                .targets_error = if (terr.len > 0) terr else null,
                .last = last.items,
                .last_build = if (mine.items.len > 0) .of(mine.items[0]) else null,
                .last_success = success,
                .last_failure = failure,
                .running = running,
                .health = if (rated > 0) @divTrunc(passed * 100, @as(i64, @intCast(rated))) else null,
            });
        }
        return out.items;
    }
};

fn copyTargets(a: Allocator, src: []const projects.Target) ![]projects.Target {
    const out = try a.alloc(projects.Target, src.len);
    for (src, out) |t, *o| o.* = .{
        .name = try a.dupe(u8, t.name),
        .kind = try a.dupe(u8, t.kind),
        .builder = try a.dupe(u8, t.builder),
        .bundle_id = if (t.bundle_id) |b| try a.dupe(u8, b) else null,
        .platform = try a.dupe(u8, t.platform),
        .dir = try a.dupe(u8, t.dir),
    };
    return out;
}
