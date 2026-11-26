//! The job model and the SQLite store (`$ROOT/.pull/idlci/idlci.db`). The
//! schema is the Rust idlci's plus the `subject`/`checkout` columns of patch
//! and stack runs, so every older idlci.db (and cpull's `.pull/cpull/ci/ci.db`
//! copy of it, see migrate.zig) opens as is.
const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Command = enum {
    build,
    @"test",
    lint,
    fmt_check,
    check,
    clean,

    pub const all = [_]Command{ .build, .@"test", .lint, .fmt_check, .check, .clean };

    pub fn name(c: Command) []const u8 {
        return if (c == .fmt_check) "fmt-check" else @tagName(c);
    }

    pub fn parse(s: []const u8) ?Command {
        if (std.mem.eql(u8, s, "fmt-check")) return .fmt_check;
        if (std.mem.eql(u8, s, "fmt_check")) return null;
        return std.meta.stringToEnum(Command, s);
    }

    pub fn jsonStringify(c: Command, w: anytype) !void {
        try w.write(c.name());
    }

    /// Arguments for `idl`, run from the project directory.
    pub fn idlArgs(c: Command, a: Allocator, cfg: Configuration, strict: bool, targets: []const []const u8) ![]const []const u8 {
        var args: std.ArrayList([]const u8) = .empty;
        if (c == .fmt_check) try args.appendSlice(a, &.{ "fmt", "--check" }) else try args.append(a, c.name());
        const cfg_flag = c == .build or c == .@"test" or c == .clean;
        if (cfg_flag and cfg != .none) try args.appendSlice(a, &.{ "-c", @tagName(cfg) });
        if (strict and (c == .build or c == .check)) try args.append(a, "--strict");
        try args.appendSlice(a, targets);
        return args.items;
    }
};

pub const Status = enum {
    queued,
    running,
    passed,
    failed,
    cancelled,

    pub const all = [_]Status{ .queued, .running, .passed, .failed, .cancelled };

    pub fn isFinal(s: Status) bool {
        return s != .queued and s != .running;
    }

    pub fn parse(s: []const u8) ?Status {
        return std.meta.stringToEnum(Status, s);
    }
};

pub const Configuration = enum {
    debug,
    release,
    none,

    pub fn parse(s: []const u8) ?Configuration {
        return std.meta.stringToEnum(Configuration, s);
    }
};

pub const RequestedBy = enum {
    web,
    mcp,
    watch,
    cli,

    pub fn parse(s: []const u8) ?RequestedBy {
        return std.meta.stringToEnum(RequestedBy, s);
    }
};

pub const GitInfo = struct {
    repo: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    dirty: bool = false,
};

/// A job; its JSON is idlci's (serde field order, `git` flattened).
pub const Job = struct {
    id: i64,
    project: []const u8,
    command: Command,
    targets: []const []const u8,
    configuration: Configuration,
    strict: bool,
    status: Status,
    exit_code: ?i32,
    /// Unix seconds.
    created: i64,
    started: ?i64,
    finished: ?i64,
    git: GitInfo,
    requested_by: RequestedBy,
    retry_of: ?i64,
    log: []const u8,
    /// What the job checks besides the workspace checkout: "patch:<repo>:<id>"
    /// or "stack:<id>" (runs.zig); null for the workspace itself.
    subject: ?[]const u8 = null,
    /// For a subject: the commits checked out, one "<pullfile repo> <oid>" per line.
    checkout: ?[]const u8 = null,

    pub fn jsonStringify(j: Job, w: anytype) !void {
        try w.beginObject();
        try j.writeFields(w);
        try w.endObject();
    }

    pub fn writeFields(j: Job, w: anytype) !void {
        inline for (.{ "id", "project", "command", "targets", "configuration", "strict", "status", "exit_code", "created", "started", "finished" }) |f| {
            try w.objectField(f);
            try w.write(@field(j, f));
        }
        inline for (.{ "repo", "branch", "head", "dirty" }) |f| {
            try w.objectField(f);
            try w.write(@field(j.git, f));
        }
        inline for (.{ "requested_by", "retry_of", "log", "subject", "checkout" }) |f| {
            try w.objectField(f);
            try w.write(@field(j, f));
        }
    }

    /// One line for the CLI and MCP tools.
    pub fn summary(j: Job, a: Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.print("#{d} {t} {s} {s}", .{ j.id, j.status, j.command.name(), j.project });
        if (j.targets.len > 0) {
            try w.writeAll(" [");
            for (j.targets, 0..) |t, i| {
                if (i > 0) try w.writeByte(' ');
                try w.writeAll(t);
            }
            try w.writeByte(']');
        }
        if (j.configuration != .none) try w.print(" -c {t}", .{j.configuration});
        if (j.strict) try w.writeAll(" --strict");
        if (j.exit_code) |code| try w.print(" exit={d}", .{code});
        if (j.started) |s| if (j.finished) |f| try w.print(" {d}s", .{f - s});
        if (j.git.head) |head| {
            try w.writeAll(" @");
            if (j.git.branch) |b| try w.print("{s}:", .{b});
            try w.print("{s}{s}", .{ head, if (j.git.dirty) "+dirty" else "" });
        }
        try w.print(" by {t}", .{j.requested_by});
        if (j.subject) |subj| try w.print(" for {s}", .{subj});
        return out.written();
    }
};

/// `POST /api/jobs` result: the job, and whether it was already queued.
pub const Enqueued = struct {
    job: Job,
    deduplicated: bool,

    pub fn jsonStringify(e: Enqueued, w: anytype) !void {
        try w.beginObject();
        try e.job.writeFields(w);
        try w.objectField("deduplicated");
        try w.write(e.deduplicated);
        try w.endObject();
    }
};

pub const NewJob = struct {
    /// Project path relative to the workspace root, pull repo name or last path segment.
    project: []const u8,
    command: Command = .build,
    targets: []const []const u8 = &.{},
    configuration: Configuration = .none,
    strict: bool = false,
    requested_by: RequestedBy = .cli,
    retry_of: ?i64 = null,
    /// See Job.subject/checkout; queued by runs.zig only.
    subject: ?[]const u8 = null,
    checkout: ?[]const u8 = null,

    /// Parse idlci's NewJob JSON (missing fields take their defaults).
    pub fn fromJson(a: Allocator, body: []const u8) !NewJob {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.InvalidJson;
        if (v != .object) return error.InvalidJson;
        const o = v.object;
        var n: NewJob = .{ .project = "" };
        n.project = switch (o.get("project") orelse return error.MissingProject) {
            .string => |s| s,
            else => return error.InvalidProject,
        };
        n.command = switch (o.get("command") orelse return error.MissingCommand) {
            .string => |s| Command.parse(s) orelse return error.InvalidCommand,
            else => return error.InvalidCommand,
        };
        if (o.get("targets")) |t| switch (t) {
            .null => {},
            .array => |arr| {
                const list = try a.alloc([]const u8, arr.items.len);
                for (arr.items, list) |item, *dst| dst.* = switch (item) {
                    .string => |s| s,
                    else => return error.InvalidTargets,
                };
                n.targets = list;
            },
            else => return error.InvalidTargets,
        };
        if (o.get("configuration")) |c| switch (c) {
            .null => {},
            .string => |s| n.configuration = Configuration.parse(s) orelse return error.InvalidConfiguration,
            else => return error.InvalidConfiguration,
        };
        if (o.get("strict")) |s| switch (s) {
            .null => {},
            .bool => |b| n.strict = b,
            else => return error.InvalidStrict,
        };
        if (o.get("requested_by")) |r| switch (r) {
            .null => {},
            .string => |s| n.requested_by = RequestedBy.parse(s) orelse return error.InvalidRequestedBy,
            else => return error.InvalidRequestedBy,
        };
        if (o.get("retry_of")) |r| switch (r) {
            .integer => |i| n.retry_of = i,
            else => {},
        };
        return n;
    }

    pub fn jsonStringify(n: NewJob, w: anytype) !void {
        try w.beginObject();
        inline for (.{ "project", "command", "targets", "configuration", "strict", "requested_by", "retry_of" }) |f| {
            try w.objectField(f);
            try w.write(@field(n, f));
        }
        try w.endObject();
    }
};

pub const JobFilter = struct {
    status: ?Status = null,
    project: ?[]const u8 = null,
    limit: ?usize = null,
};

pub fn now(io: Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

const cols = "id, project, command, targets, configuration, strict, status, exit_code, created, " ++
    "started, finished, repo, branch, head, dirty, requested_by, retry_of, log, subject, checkout";

/// A jobs row as SQLite returns it; `toJob` parses its enum and JSON columns.
const Row = struct {
    id: i64,
    project: []const u8,
    command: []const u8,
    targets: []const u8,
    configuration: []const u8,
    strict: bool,
    status: []const u8,
    exit_code: ?i32,
    created: i64,
    started: ?i64,
    finished: ?i64,
    repo: ?[]const u8,
    branch: ?[]const u8,
    head: ?[]const u8,
    dirty: bool,
    requested_by: []const u8,
    retry_of: ?i64,
    log: []const u8,
    subject: ?[]const u8,
    checkout: ?[]const u8,

    fn toJob(r: Row, a: Allocator) !Job {
        const targets = std.json.parseFromSliceLeaky([]const []const u8, a, r.targets, .{}) catch &.{};
        return .{
            .id = r.id,
            .project = r.project,
            .command = Command.parse(r.command) orelse return error.InvalidColumn,
            .targets = targets,
            .configuration = Configuration.parse(r.configuration) orelse return error.InvalidColumn,
            .strict = r.strict,
            .status = Status.parse(r.status) orelse return error.InvalidColumn,
            .exit_code = r.exit_code,
            .created = r.created,
            .started = r.started,
            .finished = r.finished,
            .git = .{ .repo = r.repo, .branch = r.branch, .head = r.head, .dirty = r.dirty },
            .requested_by = RequestedBy.parse(r.requested_by) orelse return error.InvalidColumn,
            .retry_of = r.retry_of,
            .log = r.log,
            .subject = r.subject,
            .checkout = r.checkout,
        };
    }
};

pub const Store = struct {
    db: sqlite.Db,
    mutex: Io.Mutex = .init,
    io: Io,
    /// `$ROOT/.pull/idlci`, absolute.
    dir: []const u8,

    /// Open (creating) the store in `dir` (see `dataDir`). With `migrate_from`,
    /// a missing database is first copied from that database (tests).
    pub fn open(io: Io, gpa: Allocator, dir: []const u8, migrate_from: ?[]const u8) !*Store {
        const cwd = Io.Dir.cwd();
        const logs = try std.fs.path.join(gpa, &.{ dir, "logs" });
        defer gpa.free(logs);
        try cwd.createDirPath(io, logs);
        const path = try std.fs.path.joinZ(gpa, &.{ dir, db_name });
        defer gpa.free(path);
        const fresh = if (cwd.access(io, path, .{})) false else |_| true;
        var db = try sqlite.Db.init(.{
            .mode = .{ .File = path },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .Serialized,
        });
        errdefer db.deinit();
        if (fresh) if (migrate_from) |old| if (cwd.access(io, old, .{})) |_| {
            // VACUUM INTO copies a live WAL database consistently, sqlite_sequence included
            var src = try sqlite.Db.init(.{ .mode = .{ .File = try gpa.dupeSentinel(u8, old, 0) }, .open_flags = .{ .write = false } });
            defer src.deinit();
            try src.execDynamic("VACUUM INTO ?", .{}, .{@as([]const u8, path)});
            db.deinit();
            db = try sqlite.Db.init(.{ .mode = .{ .File = path }, .open_flags = .{ .write = true, .create = true }, .threading_mode = .Serialized });
        } else |_| {};
        _ = try db.pragma(void, .{}, "busy_timeout", "5000");
        _ = try db.pragma([32:0]u8, .{}, "journal_mode", "WAL");
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS jobs (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  project TEXT NOT NULL, command TEXT NOT NULL, targets TEXT NOT NULL,
            \\  configuration TEXT NOT NULL, strict INTEGER NOT NULL, status TEXT NOT NULL,
            \\  exit_code INTEGER, created INTEGER NOT NULL, started INTEGER, finished INTEGER,
            \\  repo TEXT, branch TEXT, head TEXT, dirty INTEGER NOT NULL DEFAULT 0,
            \\  requested_by TEXT NOT NULL, retry_of INTEGER, log TEXT NOT NULL DEFAULT '',
            \\  pid INTEGER)
        , .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS jobs_project ON jobs(project, command)", .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status)", .{}, .{});
        // patch/stack runs (added while the CI lived in cpull)
        inline for (.{ "subject", "checkout" }) |col| {
            const has = try db.one(struct { n: i64 }, "SELECT COUNT(*) FROM pragma_table_info('jobs') WHERE name = ?", .{}, .{@as([]const u8, col)});
            if (has == null or has.?.n == 0) try db.exec("ALTER TABLE jobs ADD COLUMN " ++ col ++ " TEXT", .{}, .{});
        }
        try db.exec("CREATE INDEX IF NOT EXISTS jobs_subject ON jobs(subject)", .{}, .{});
        try db.exec("CREATE INDEX IF NOT EXISTS jobs_head ON jobs(repo, head)", .{}, .{});
        // the feed (finished jobs in order)
        try db.exec("CREATE INDEX IF NOT EXISTS jobs_finished ON jobs(finished, id)", .{}, .{});
        // cpull's ci_issues/issue_jobs/link_tips tables, in a database adopted
        // from cpull, are left alone: they moved to cpull's integrate.json
        const s = try gpa.create(Store);
        s.* = .{ .db = db, .io = io, .dir = try gpa.dupe(u8, dir) };
        return s;
    }

    pub fn close(s: *Store, gpa: Allocator) void {
        s.db.deinit();
        gpa.free(s.dir);
        gpa.destroy(s);
    }

    fn lock(s: *Store) void {
        s.mutex.lockUncancelable(s.io);
    }

    fn unlock(s: *Store) void {
        s.mutex.unlock(s.io);
    }

    fn queryAll(s: *Store, a: Allocator, comptime query: []const u8, values: anytype) ![]Job {
        var stmt = try s.db.prepare(query);
        defer stmt.deinit();
        var it = try stmt.iteratorAlloc(Row, a, values);
        var out: std.ArrayList(Job) = .empty;
        while (try it.nextAlloc(a, .{})) |r| try out.append(a, try r.toJob(a));
        return out.items;
    }

    fn queryOne(s: *Store, a: Allocator, comptime query: []const u8, values: anytype) !?Job {
        const r = try s.db.oneAlloc(Row, a, query, .{}, values) orelse return null;
        return try r.toJob(a);
    }

    /// Queue a job, or return the identical job already queued (created = false).
    pub fn insert(s: *Store, a: Allocator, new: NewJob, git: GitInfo) !struct { Job, bool } {
        s.lock();
        defer s.unlock();
        const targets = try std.json.Stringify.valueAlloc(a, new.targets, .{});
        if (try s.queryOne(a, "SELECT " ++ cols ++ " FROM jobs WHERE status = 'queued' AND project = ? AND command = ? " ++
            "AND targets = ? AND configuration = ? AND strict = ? AND subject IS ? AND checkout IS ? ORDER BY id LIMIT 1", .{
            new.project, new.command.name(), targets, @as([]const u8, @tagName(new.configuration)), new.strict, new.subject, new.checkout,
        })) |job| return .{ job, false };
        try s.db.exec(
            "INSERT INTO jobs (project, command, targets, configuration, strict, status, created, " ++
                "repo, branch, head, dirty, requested_by, retry_of, subject, checkout) VALUES (?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            .{},
            .{
                new.project,         new.command.name(), targets,       @as([]const u8, @tagName(new.configuration)), new.strict, now(s.io),
                git.repo,            git.branch,         git.head,      git.dirty,                                     @as([]const u8, @tagName(new.requested_by)),
                new.retry_of,        new.subject,        new.checkout,
            },
        );
        const id = s.db.getLastInsertRowID();
        const log = try std.fmt.allocPrint(a, "{s}/logs/{d}.log", .{ s.dir, id });
        try s.db.exec("UPDATE jobs SET log = ? WHERE id = ?", .{}, .{ log, id });
        const job = try s.queryOne(a, "SELECT " ++ cols ++ " FROM jobs WHERE id = ?", .{id}) orelse return error.JobVanished;
        return .{ job, true };
    }

    pub fn get(s: *Store, a: Allocator, id: i64) !?Job {
        s.lock();
        defer s.unlock();
        return s.queryOne(a, "SELECT " ++ cols ++ " FROM jobs WHERE id = ?", .{id});
    }

    pub fn list(s: *Store, a: Allocator, f: JobFilter) ![]Job {
        s.lock();
        defer s.unlock();
        const status: ?[]const u8 = if (f.status) |st| @tagName(st) else null;
        const limit: i64 = @intCast(f.limit orelse 100);
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE (? IS NULL OR status = ?) AND (? IS NULL OR project = ?) " ++
            "ORDER BY id DESC LIMIT ?", .{ status, status, f.project, f.project, limit });
    }

    /// Queued and running jobs, oldest first.
    pub fn active(s: *Store, a: Allocator) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE status IN ('queued', 'running') ORDER BY id", .{});
    }

    /// Mark the oldest queued job running and return it.
    pub fn claimNext(s: *Store, a: Allocator) !?Job {
        s.lock();
        defer s.unlock();
        return s.queryOne(a, "UPDATE jobs SET status = 'running', started = ? WHERE id = " ++
            "(SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 1) RETURNING " ++ cols, .{now(s.io)});
    }

    pub fn setPid(s: *Store, id: i64, pid: ?i32) !void {
        s.lock();
        defer s.unlock();
        try s.db.exec("UPDATE jobs SET pid = ? WHERE id = ?", .{}, .{ pid, id });
    }

    pub fn finish(s: *Store, id: i64, status: Status, exit_code: ?i32) !void {
        s.lock();
        defer s.unlock();
        try s.db.exec("UPDATE jobs SET status = ?, exit_code = ?, finished = ?, pid = NULL WHERE id = ?", .{}, .{
            @as([]const u8, @tagName(status)), exit_code, now(s.io), id,
        });
    }

    /// Cancel a job that hasn't started; false if it isn't queued.
    pub fn cancelQueued(s: *Store, id: i64) !bool {
        s.lock();
        defer s.unlock();
        try s.db.exec("UPDATE jobs SET status = 'cancelled', finished = ? WHERE id = ? AND status = 'queued'", .{}, .{ now(s.io), id });
        return s.db.rowsAffected() > 0;
    }

    pub const Recovered = struct { job: Job, pid: ?i32 };

    /// Jobs left `running` by a previous server: mark them failed, return them with their pids.
    pub fn recover(s: *Store, a: Allocator) ![]Recovered {
        s.lock();
        defer s.unlock();
        const jobs = try s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE status = 'running' ORDER BY id", .{});
        const out = try a.alloc(Recovered, jobs.len);
        for (jobs, out) |job, *r| {
            const row = try s.db.one(struct { pid: ?i32 }, "SELECT pid FROM jobs WHERE id = ?", .{}, .{job.id});
            r.* = .{ .job = job, .pid = if (row) |x| x.pid else null };
        }
        try s.db.exec("UPDATE jobs SET status = 'failed', finished = ?, pid = NULL WHERE status = 'running'", .{}, .{now(s.io)});
        return out;
    }

    /// The newest finished jobs per project (for the dashboard), newest first.
    pub fn finishedPerProject(s: *Store, a: Allocator, per_project: usize) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY project ORDER BY id DESC) AS n " ++
            "FROM jobs WHERE status IN ('passed', 'failed', 'cancelled') AND subject IS NULL) WHERE n <= ? ORDER BY id DESC", .{@as(i64, @intCast(per_project))});
    }

    /// The latest job per (project, command).
    pub fn latestPerCommand(s: *Store, a: Allocator) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs WHERE subject IS NULL GROUP BY project, command)", .{});
    }

    /// How long the last passed run of the same project + command took (progress estimate).
    pub fn lastDuration(s: *Store, project: []const u8, command: Command) !?i64 {
        s.lock();
        defer s.unlock();
        const row = try s.db.one(struct { d: ?i64 }, "SELECT finished - started FROM jobs WHERE project = ? AND command = ? " ++
            "AND status = 'passed' AND subject IS NULL ORDER BY id DESC LIMIT 1", .{}, .{ project, command.name() }) orelse return null;
        return row.d;
    }

    // ---- status summaries (status.zig) ------------------------------------

    /// The workspace's latest job per (project, command) whose repo is `repo`.
    pub fn latestForRepo(s: *Store, a: Allocator, repo: []const u8) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs WHERE subject IS NULL " ++
            "AND repo = ? GROUP BY project, command) ORDER BY project, command", .{repo});
    }

    /// The latest job per (project, command) checking `subject`.
    pub fn latestForSubject(s: *Store, a: Allocator, subject: []const u8) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs WHERE subject = ? " ++
            "GROUP BY project, command) ORDER BY project, command", .{subject});
    }

    /// The newest jobs that ran on some commit of `repo` (any subject), newest first.
    pub fn withHeads(s: *Store, a: Allocator, repo: []const u8, limit: usize) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE repo = ? AND head IS NOT NULL ORDER BY id DESC LIMIT ?", .{ repo, @as(i64, @intCast(limit)) });
    }

    /// The newest job before `before` with the same project, command, targets,
    /// configuration and subject as `j` that passed or failed.
    pub fn previousOutcome(s: *Store, a: Allocator, j: Job) !?Job {
        s.lock();
        defer s.unlock();
        const targets = try std.json.Stringify.valueAlloc(a, j.targets, .{});
        return s.queryOne(a, "SELECT " ++ cols ++ " FROM jobs WHERE id < ? AND project = ? AND command = ? AND targets = ? " ++
            "AND configuration = ? AND subject IS ? AND status IN ('passed', 'failed') ORDER BY id DESC LIMIT 1", .{
            j.id, j.project, j.command.name(), targets, @as([]const u8, @tagName(j.configuration)), j.subject,
        });
    }

    // ---- the feed (cpull's CI issues) and work tree cleanup ---------------

    /// Jobs that reached a final status after (finished, id) and before
    /// `before` (exclusive, unix seconds), oldest first.
    pub fn finishedAfter(s: *Store, a: Allocator, finished: i64, id: i64, before: i64, limit: usize) ![]Job {
        s.lock();
        defer s.unlock();
        return s.queryAll(a, "SELECT " ++ cols ++ " FROM jobs WHERE status IN ('passed', 'failed', 'cancelled') AND finished IS NOT NULL " ++
            "AND (finished > ? OR (finished = ? AND id > ?)) AND finished < ? ORDER BY finished, id LIMIT ?", .{ finished, finished, id, before, @as(i64, @intCast(limit)) });
    }

    /// The newest (finished, id) of the jobs finished before `before`, or (0, 0).
    pub fn lastFinished(s: *Store, before: i64) !struct { i64, i64 } {
        s.lock();
        defer s.unlock();
        const row = try s.db.one(struct { finished: i64, id: i64 }, "SELECT finished, id FROM jobs WHERE status IN ('passed', 'failed', 'cancelled') " ++
            "AND finished IS NOT NULL AND finished < ? ORDER BY finished DESC, id DESC LIMIT 1", .{}, .{before}) orelse return .{ 0, 0 };
        return .{ row.finished, row.id };
    }

    pub const SubjectUse = struct { subject: []const u8, last: i64, active: i64 };

    /// Every subject with its newest job's creation time and its queued/running job count.
    pub fn subjects(s: *Store, a: Allocator) ![]SubjectUse {
        s.lock();
        defer s.unlock();
        var stmt = try s.db.prepare("SELECT subject, MAX(created) AS last, SUM(status IN ('queued', 'running')) AS active FROM jobs WHERE subject IS NOT NULL GROUP BY subject");
        defer stmt.deinit();
        var it = try stmt.iteratorAlloc(SubjectUse, a, .{});
        var out: std.ArrayList(SubjectUse) = .empty;
        while (try it.nextAlloc(a, .{})) |r| try out.append(a, r);
        return out.items;
    }

    /// The running jobs' process groups, for shutdown.
    pub fn runningPids(s: *Store, a: Allocator) ![]i32 {
        s.lock();
        defer s.unlock();
        var stmt = try s.db.prepare("SELECT pid FROM jobs WHERE status = 'running' AND pid IS NOT NULL");
        defer stmt.deinit();
        var it = try stmt.iterator(struct { pid: i32 }, .{});
        var out: std.ArrayList(i32) = .empty;
        while (try it.next(.{})) |r| try out.append(a, r.pid);
        return out.items;
    }
};

pub const db_name = "idlci.db";

/// Where idlci keeps its state: `$ROOT/.pull/idlci`.
pub fn dataDir(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, ".pull", "idlci" });
}

test "queue, dedupe, claim, finish, recover" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const store = try Store.open(io, gpa, dir, null);
    defer store.close(gpa);

    const new: NewJob = .{ .project = "a/b", .command = .build, .targets = &.{"App"} };
    const j1, const created1 = try store.insert(a, new, .{});
    try std.testing.expect(created1);
    try std.testing.expect(std.mem.endsWith(u8, j1.log, try std.fmt.allocPrint(a, "logs/{d}.log", .{j1.id})));
    const j2, const created2 = try store.insert(a, new, .{});
    try std.testing.expect(!created2);
    try std.testing.expectEqual(j1.id, j2.id);
    const claimed = (try store.claimNext(a)).?;
    try std.testing.expectEqual(Status.running, claimed.status);
    try std.testing.expectEqualStrings("App", claimed.targets[0]);
    try std.testing.expect(try store.claimNext(a) == null);
    // a running job doesn't block a new identical one
    try std.testing.expect((try store.insert(a, new, .{}))[1]);
    try store.finish(j1.id, .passed, 0);
    try std.testing.expectEqual(@as(usize, 1), (try store.latestPerCommand(a)).len);
    try std.testing.expectEqual(@as(usize, 1), (try store.finishedPerProject(a, 5)).len);
    try std.testing.expect(try store.lastDuration("a/b", .build) != null);
    const queued = try store.list(a, .{ .status = .queued });
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expect(try store.cancelQueued(queued[0].id));
    try std.testing.expectEqual(@as(usize, 0), (try store.recover(a)).len);
    _ = try store.insert(a, new, .{});
    const running = (try store.claimNext(a)).?;
    try store.setPid(running.id, 4242);
    const recovered = try store.recover(a);
    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqual(@as(?i32, 4242), recovered[0].pid);
    try std.testing.expectEqual(Status.failed, (try store.get(a, running.id)).?.status);
    // idlci's JSON
    const json = try std.json.Stringify.valueAlloc(a, Enqueued{ .job = running, .deduplicated = false }, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"command\":\"build\",\"targets\":[\"App\"],\"configuration\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"repo\":null,\"branch\":null,\"head\":null,\"dirty\":false,\"requested_by\":\"cli\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, json, ",\"deduplicated\":false}"));
}

test "idl args" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const t: []const []const u8 = &.{"X"};
    const fmt = try Command.fmt_check.idlArgs(aa, .release, true, t);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "fmt", "--check", "X" }), fmt);
    const build = try Command.build.idlArgs(aa, .release, true, t);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "build", "-c", "release", "--strict", "X" }), build);
    const tst = try Command.@"test".idlArgs(aa, .none, true, &.{});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"test"}), tst);
}
