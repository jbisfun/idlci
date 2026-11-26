//! idlci's server (the Rust idlci's web.rs router): Jenkins-style pages on the
//! shared theme, the JSON API under /api (docs/workspace-tools.md in the theme
//! package: jobs, projects, runs, status summaries for cpull, the feed) and the
//! live console as server-sent events.
const std = @import("std");
const db = @import("db.zig");
const fmt = @import("fmt.zig");
const projects = @import("projects.zig");
const app_mod = @import("app.zig");
const theme = @import("theme");
const ci_status = @import("status.zig");
const runs = @import("runs.zig");
const feed = @import("feed.zig");
const work = @import("work.zig");

const App = app_mod.App;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Request = std.http.Server.Request;
const log = std.log.scoped(.idlci);

pub const version = "0.2.0";
pub const site_name = "idlci";

pub const templates = [_]theme.Template{
    .{ .name = "ci/base.html", .source = @embedFile("templates/base.html") },
    .{ .name = "ci/macros.html", .source = @embedFile("templates/macros.html") },
    .{ .name = "ci/dashboard.html", .source = @embedFile("templates/dashboard.html") },
    .{ .name = "ci/project.html", .source = @embedFile("templates/project.html") },
    .{ .name = "ci/job.html", .source = @embedFile("templates/job.html") },
    .{ .name = "ci/jobs.html", .source = @embedFile("templates/jobs.html") },
};

const css = @embedFile("idlci.css");

/// Serve the requests of one connection until it closes.
pub fn serveConnection(app: *App, io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);
    var recv: [8192]u8 = undefined;
    var send: [8192]u8 = undefined;
    var br = stream.reader(io, &recv);
    var bw = stream.writer(io, &send);
    var http = std.http.Server.init(&br.interface, &bw.interface);
    while (http.reader.state == .ready) {
        var request = http.receiveHead() catch break;
        handle(app, io, &request, app.gpa) catch break;
    }
}

/// Answer one request.
pub fn handle(app: *App, io: Io, request: *Request, gpa: Allocator) anyerror!void {
    const target = request.head.target;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const owned = try a.dupe(u8, target);
    const q = std.mem.indexOfScalar(u8, owned, '?');
    const path = owned[0 .. q orelse owned.len];
    const query: []const u8 = if (q) |i| owned[i + 1 ..] else "";
    var r: Req = .{ .app = app, .io = io, .a = a, .request = request, .query = query };
    route(&r, path) catch |e| switch (e) {
        error.WriteFailed, error.HttpExpectationFailed => return e,
        else => {
            log.err("{s}: {t}", .{ path, e });
            r.fail(.internal_server_error, @errorName(e)) catch {};
        },
    };
}

const Req = struct {
    app: *App,
    io: Io,
    a: Allocator,
    request: *Request,
    query: []const u8,

    fn param(r: *Req, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, r.query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse kv.len;
            if (!std.mem.eql(u8, decode(r.a, kv[0..eq]), key)) continue;
            return decode(r.a, if (eq < kv.len) kv[eq + 1 ..] else "");
        }
        return null;
    }

    /// A query parameter, with an empty value meaning "any" (idlci's JobsQuery).
    fn nonEmpty(r: *Req, key: []const u8) ?[]const u8 {
        const v = r.param(key) orelse return null;
        return if (v.len == 0) null else v;
    }

    fn json(r: *Req, status: std.http.Status, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(r.a, value, .{});
        try r.request.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn fail(r: *Req, status: std.http.Status, msg: []const u8) !void {
        try r.json(status, .{ .@"error" = msg });
    }

    fn html(r: *Req, body: []const u8) !void {
        try r.request.respond(body, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    }

    fn redirect(r: *Req, location: []const u8) !void {
        try r.request.respond("", .{ .status = .see_other, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }

    fn redirectPermanent(r: *Req, location: []const u8) !void {
        try r.request.respond("", .{ .status = .moved_permanently, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }

    fn readBody(r: *Req) ![]const u8 {
        var buf: [1024]u8 = undefined;
        return r.request.readerExpectNone(&buf).allocRemaining(r.a, .limited(1 << 20));
    }
};

/// Percent-decode a url component ('+' is a space in query strings).
fn decode(a: Allocator, s: []const u8) []const u8 {
    const buf = a.dupe(u8, s) catch return s;
    for (buf) |*c| if (c.* == '+') {
        c.* = ' ';
    };
    return std.Uri.percentDecodeInPlace(buf);
}

fn isSameOrigin(request: *Request) bool {
    var origin: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "origin")) origin = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "host")) host = h.value;
    }
    const o = origin orelse return true;
    const scheme_end = std.mem.indexOf(u8, o, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(o[scheme_end + 3 ..], host orelse return false);
}

fn header(request: *Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn route(r: *Req, path_in: []const u8) !void {
    // the CI's urls while it lived in cpull (/ci/...): the same pages here
    if (std.mem.eql(u8, path_in, "/ci") or std.mem.startsWith(u8, path_in, "/ci/")) {
        const rest = path_in["/ci".len..];
        return r.redirectPermanent(try std.fmt.allocPrint(r.a, "{s}{s}{s}", .{ if (rest.len == 0) "/" else rest, if (r.query.len > 0) "?" else "", r.query }));
    }
    const path = std.mem.trimEnd(u8, path_in, "/");
    const method = r.request.head.method;
    if (method == .POST) {
        if (!isSameOrigin(r.request)) return r.fail(.forbidden, "cross-origin request");
        if (std.mem.eql(u8, path, "/api/jobs")) return apiEnqueue(r);
        if (std.mem.eql(u8, path, "/api/runs")) return apiRuns(r);
        if (std.mem.eql(u8, path, "/api/work/cleanup")) return apiCleanup(r);
        if (jobRoute(path, "/api/jobs/", "/cancel")) |id| return apiCancel(r, id);
        if (jobRoute(path, "/api/jobs/", "/retry")) |id| return apiRetry(r, id);
        return r.fail(.not_found, "not found");
    }
    if (method != .GET and method != .HEAD) return r.fail(.method_not_allowed, "method not allowed");
    if (path.len == 0) return dashboard(r);
    if (std.mem.eql(u8, path, "/assets/idlci.css"))
        return r.request.respond(css, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "text/css; charset=utf-8" }, .{ .name = "cache-control", .value = "max-age=300" } } });
    for (theme.assets) |asset| if (std.mem.eql(u8, path[1..], asset.path))
        return r.request.respond(asset.body, .{ .extra_headers = &.{ .{ .name = "content-type", .value = asset.content_type }, .{ .name = "cache-control", .value = "max-age=300" } } });
    if (std.mem.eql(u8, path, "/favicon.ico")) return r.redirect("/assets/icons/favicon.ico");
    if (std.mem.eql(u8, path, "/jobs")) return jobsPage(r);
    if (std.mem.eql(u8, path, "/search")) return search(r);
    if (std.mem.startsWith(u8, path, "/projects/")) return projectPage(r, decode(r.a, path["/projects/".len..]));
    if (jobRoute(path, "/jobs/", "")) |id| return jobPage(r, id);
    if (jobRoute(path, "/jobs/", "/console")) |id| return consoleText(r, id);
    if (std.mem.eql(u8, path, "/api/health")) return r.json(.ok, .{ .ok = true, .tool = "idlci", .root = r.app.root, .version = version });
    if (std.mem.eql(u8, path, "/api/feed")) return apiFeed(r);
    if (std.mem.eql(u8, path, "/api/status/repos")) return apiStatusRepos(r);
    if (std.mem.startsWith(u8, path, "/api/status/repo/")) return r.json(.ok, try ci_status.forRepo(r.a, r.app.store, decode(r.a, path["/api/status/repo/".len..])));
    if (std.mem.eql(u8, path, "/api/status/commits")) {
        const repo = r.nonEmpty("repo") orelse return r.fail(.bad_request, "missing repo");
        return r.json(.ok, try ci_status.commitIndex(r.a, r.app.store, repo));
    }
    if (std.mem.eql(u8, path, "/api/status/subject")) {
        const subject = r.nonEmpty("subject") orelse return r.fail(.bad_request, "missing subject");
        return r.json(.ok, try ci_status.forSubject(r.a, r.app.store, subject, r.nonEmpty("tips")));
    }
    if (std.mem.eql(u8, path, "/api/projects")) return r.json(.ok, try r.app.projectViews(r.a, null));
    if (std.mem.startsWith(u8, path, "/api/projects/")) return apiProject(r, decode(r.a, path["/api/projects/".len..]));
    if (std.mem.eql(u8, path, "/api/jobs")) return apiJobs(r);
    if (jobRoute(path, "/api/jobs/", "")) |id| return apiJob(r, id);
    if (jobRoute(path, "/api/jobs/", "/log")) |id| return apiLog(r, id);
    if (jobRoute(path, "/api/jobs/", "/events")) |id| return apiEvents(r, id);
    return r.fail(.not_found, "not found");
}

/// The id in `<start><id><end>`.
fn jobRoute(path: []const u8, start: []const u8, end: []const u8) ?i64 {
    if (!std.mem.startsWith(u8, path, start) or !std.mem.endsWith(u8, path, end)) return null;
    if (path.len < start.len + end.len) return null;
    return std.fmt.parseInt(i64, path[start.len .. path.len - end.len], 10) catch null;
}

fn jobOr404(r: *Req, id: i64) !?db.Job {
    if (try r.app.store.get(r.a, id)) |j| return j;
    try r.fail(.not_found, try std.fmt.allocPrint(r.a, "no job #{d}", .{id}));
    return null;
}

// ---- JSON API -----------------------------------------------------------

fn filter(r: *Req) !?db.JobFilter {
    var f: db.JobFilter = .{};
    if (r.nonEmpty("status")) |s| f.status = db.Status.parse(s) orelse {
        try r.fail(.bad_request, try std.fmt.allocPrint(r.a, "invalid value \"{s}\"", .{s}));
        return null;
    };
    if (r.nonEmpty("project")) |p| {
        var msg: []const u8 = "";
        f.project = if (r.app.resolve(r.a, p, &msg)) |proj| proj.path else |_| p;
    }
    if (r.param("limit")) |l| f.limit = std.fmt.parseInt(usize, l, 10) catch null;
    return f;
}

fn apiJobs(r: *Req) !void {
    const f = try filter(r) orelse return;
    try r.json(.ok, try r.app.store.list(r.a, f));
}

fn apiJob(r: *Req, id: i64) !void {
    const job = try jobOr404(r, id) orelse return;
    try r.json(.ok, job);
}

fn apiProject(r: *Req, arg: []const u8) !void {
    var msg: []const u8 = "";
    const p = r.app.resolve(r.a, arg, &msg) catch |e| return if (e == error.NotFound) r.fail(.not_found, msg) else e;
    const views = try r.app.projectViews(r.a, p.path);
    if (views.len == 0) return r.fail(.internal_server_error, "project vanished");
    try r.json(.ok, views[0]);
}

fn enqueue(r: *Req, new: db.NewJob) !void {
    var msg: []const u8 = "";
    const e = r.app.enqueue(r.a, new, &msg) catch |err| switch (err) {
        error.BadRequest, error.NotFound => return r.fail(.bad_request, msg),
        else => return err,
    };
    try r.json(.ok, e);
}

fn apiEnqueue(r: *Req) !void {
    const body = try r.readBody();
    const new = db.NewJob.fromJson(r.a, body) catch |e| return r.fail(.bad_request, try std.fmt.allocPrint(r.a, "invalid job: {t}", .{e}));
    try enqueue(r, new);
}

fn apiCancel(r: *Req, id: i64) !void {
    _ = try jobOr404(r, id) orelse return;
    r.app.runner.cancel(id) catch |e| switch (e) {
        error.NotQueuedOrRunning => return r.fail(.bad_request, try std.fmt.allocPrint(r.a, "job #{d} is not queued or running", .{id})),
        else => return e,
    };
    const job = try jobOr404(r, id) orelse return;
    try r.json(.ok, job);
}

fn apiRetry(r: *Req, id: i64) !void {
    const job = try jobOr404(r, id) orelse return;
    const by = if (r.param("by")) |b| db.RequestedBy.parse(b) orelse job.requested_by else job.requested_by;
    // a patch or stack job retries on the same commits
    if (job.subject != null) {
        var msg: []const u8 = "";
        const e = r.app.enqueueWith(r.a, .{
            .project = job.project,
            .command = job.command,
            .targets = job.targets,
            .configuration = job.configuration,
            .strict = job.strict,
            .requested_by = by,
            .retry_of = id,
            .subject = job.subject,
            .checkout = job.checkout,
        }, job.git, &msg) catch |err| switch (err) {
            error.BadRequest, error.NotFound => return r.fail(.bad_request, msg),
            else => return err,
        };
        return r.json(.ok, e);
    }
    try enqueue(r, .{
        .project = job.project,
        .command = job.command,
        .targets = job.targets,
        .configuration = job.configuration,
        .strict = job.strict,
        .requested_by = by,
        .retry_of = id,
    });
}


fn apiRuns(r: *Req) !void {
    const body = try r.readBody();
    var msg: []const u8 = "";
    const run = runs.parse(r.a, body, &msg) catch |e| return if (e == error.BadRequest) r.fail(.bad_request, msg) else e;
    const queued = runs.queue(r.app, r.a, run, &msg) catch |e| switch (e) {
        error.BadRequest, error.NotFound => return r.fail(.bad_request, if (msg.len > 0) msg else @errorName(e)),
        else => return e,
    };
    try r.json(.ok, queued);
}

/// Every pullfile repo's summary (null for a repo without workspace jobs).
fn apiStatusRepos(r: *Req) !void {
    const Entry = struct { name: []const u8, summary: ?ci_status.Summary };
    const Map = struct {
        entries: []const Entry,
        pub fn jsonStringify(m: @This(), w: anytype) !void {
            try w.beginObject();
            for (m.entries) |e| {
                try w.objectField(e.name);
                try w.write(e.summary);
            }
            try w.endObject();
        }
    };
    const repos = try r.app.repos(r.a);
    const entries = try r.a.alloc(Entry, repos.len);
    for (repos, entries) |repo, *e| e.* = .{ .name = repo.name, .summary = try ci_status.forRepo(r.a, r.app.store, repo.name) };
    try r.json(.ok, Map{ .entries = entries });
}

/// Finished jobs after `cursor`, oldest first; long-polls up to `wait` seconds (see feed.zig).
fn apiFeed(r: *Req) !void {
    const wait_s: u64 = @min(if (r.param("wait")) |w| std.fmt.parseInt(u64, w, 10) catch 0 else 0, 60);
    const limit: usize = @min(if (r.param("limit")) |l| std.fmt.parseInt(usize, l, 10) catch 100 else 100, 500);
    const cursor = r.nonEmpty("cursor") orelse {
        const last_f, const last_id = try r.app.store.lastFinished(db.now(r.io));
        return r.json(.ok, feed.Page{ .cursor = try feed.formatCursor(r.a, last_f, last_id), .jobs = &.{} });
    };
    var f, var id = feed.parseCursor(cursor) orelse return r.fail(.bad_request, "invalid cursor");
    const deadline = db.now(r.io) + @as(i64, @intCast(wait_s));
    while (true) {
        const jobs = try r.app.store.finishedAfter(r.a, f, id, db.now(r.io), limit);
        if (jobs.len > 0 or db.now(r.io) >= deadline) {
            if (jobs.len > 0) {
                f = jobs[jobs.len - 1].finished.?;
                id = jobs[jobs.len - 1].id;
            }
            const out = try r.a.alloc(feed.FeedJob, jobs.len);
            for (jobs, out) |j, *o| o.* = try feed.FeedJob.of(r.io, r.a, j);
            return r.json(.ok, feed.Page{ .cursor = try feed.formatCursor(r.a, f, id), .jobs = out });
        }
        r.io.sleep(.fromMilliseconds(500), .awake) catch return r.fail(.service_unavailable, "cancelled");
    }
}

/// Remove idle patch/stack work trees now: ?days=N (default the server's), ?dry_run=1.
fn apiCleanup(r: *Req) !void {
    const days: u32 = if (r.param("days")) |d| std.fmt.parseInt(u32, d, 10) catch return r.fail(.bad_request, "invalid days") else if (r.app.work_days > 0) r.app.work_days else 7;
    const dry = if (r.param("dry_run")) |d| std.mem.eql(u8, d, "1") or std.mem.eql(u8, d, "true") else false;
    r.app.runner.work_mutex.lockUncancelable(r.io);
    defer r.app.runner.work_mutex.unlock(r.io);
    const removed = try work.cleanup(r.io, r.a, r.app.root, r.app.store, days, db.now(r.io), dry);
    try r.json(.ok, .{ .days = days, .dry_run = dry, .removed = removed });
}

/// Up to `max` bytes of `path` from `offset`, and the file's size.
pub fn readFrom(io: Io, a: Allocator, path: []const u8, offset: u64, max: usize) !struct { []u8, u64 } {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return .{ &.{}, 0 };
    defer f.close(io);
    const size = f.length(io) catch 0;
    if (offset >= size) return .{ &.{}, size };
    const buf = try a.alloc(u8, @intCast(@min(size - offset, max)));
    const n = f.readPositionalAll(io, buf, offset) catch 0;
    return .{ buf[0..n], size };
}

/// Invalid UTF-8 as U+FFFD, like Rust's from_utf8_lossy.
fn lossy(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(a, bytes[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

pub const LogChunk = struct {
    id: i64,
    status: db.Status,
    size: u64,
    /// Offset to pass next time to continue.
    next_offset: u64,
    text: []const u8,
};

fn apiLog(r: *Req, id: i64) !void {
    const job = try jobOr404(r, id) orelse return;
    if (r.param("tail")) |t| {
        const n = std.fmt.parseInt(usize, t, 10) catch return r.fail(.bad_request, "invalid tail");
        const buf, const size = try readFrom(r.io, r.a, job.log, 0, std.math.maxInt(usize));
        const text = try lossy(r.a, buf);
        // Rust's str::lines: split on \n, drop a trailing empty line and \r endings
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try lines.append(r.a, std.mem.trimEnd(u8, line, "\r"));
        if (lines.items.len > 0 and std.mem.endsWith(u8, text, "\n")) _ = lines.pop();
        if (text.len == 0) lines.clearRetainingCapacity();
        const from = lines.items.len -| n;
        return r.json(.ok, LogChunk{ .id = id, .status = job.status, .size = size, .next_offset = size, .text = try std.mem.join(r.a, "\n", lines.items[from..]) });
    }
    const offset = if (r.param("offset")) |o| std.fmt.parseInt(u64, o, 10) catch 0 else 0;
    const buf, const size = try readFrom(r.io, r.a, job.log, offset, 1 << 20);
    try r.json(.ok, LogChunk{ .id = id, .status = job.status, .size = size, .next_offset = offset + buf.len, .text = try lossy(r.a, buf) });
}

/// Live console: `log` events (JSON string chunks, id = byte offset, so
/// reconnects resume), `status` when it changes, and a final `done` with the job.
fn apiEvents(r: *Req, id: i64) !void {
    _ = try jobOr404(r, id) orelse return;
    var offset: u64 = if (header(r.request, "last-event-id")) |v| std.fmt.parseInt(u64, v, 10) catch 0 else 0;
    var send_buf: [8192]u8 = undefined;
    var body = try r.request.respondStreaming(&send_buf, .{ .respond_options = .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-cache" },
    } } });
    const w = &body.writer;
    var last_status: ?db.Status = null;
    var idle_ms: u64 = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(r.app.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const job = (r.app.store.get(a, id) catch null) orelse break;
        var sent = false;
        if (last_status != job.status) {
            last_status = job.status;
            try w.print("event: status\ndata: {t}\n\n", .{job.status});
            sent = true;
        }
        const done = job.status.isFinal();
        var buf, _ = try readFrom(r.io, a, job.log, offset, 256 << 10);
        // whole lines only while the job writes
        if (!done) if (std.mem.lastIndexOfScalar(u8, buf, '\n')) |nl| {
            buf = buf[0 .. nl + 1];
        };
        if (buf.len > 0 and (done or buf[buf.len - 1] == '\n')) {
            offset += buf.len;
            const data = try std.json.Stringify.valueAlloc(a, try lossy(a, buf), .{});
            try w.print("event: log\nid: {d}\ndata: {s}\n\n", .{ offset, data });
            try w.flush();
            try body.flush();
            idle_ms = 0;
            continue;
        }
        if (done) {
            try w.print("event: done\ndata: {f}\n\n", .{std.json.fmt(job, .{})});
            break;
        }
        if (sent) {
            try w.flush();
            try body.flush();
        }
        r.io.sleep(.fromMilliseconds(500), .awake) catch break;
        idle_ms += 500;
        if (idle_ms >= 15_000) {
            // axum's KeepAlive default
            try w.writeAll(":\n\n");
            try w.flush();
            try body.flush();
            idle_ms = 0;
        }
    }
    try body.end();
}

fn consoleText(r: *Req, id: i64) !void {
    const job = try jobOr404(r, id) orelse return;
    const text, _ = try readFrom(r.io, r.a, job.log, 0, std.math.maxInt(usize));
    try r.request.respond(text, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }} });
}

fn search(r: *Req) !void {
    const q = std.mem.trim(u8, r.param("q") orelse "", " \t\r\n");
    if (std.fmt.parseInt(i64, std.mem.trimStart(u8, q, "#"), 10)) |id| {
        return r.redirect(try std.fmt.allocPrint(r.a, "/jobs/{d}", .{id}));
    } else |_| {}
    var msg: []const u8 = "";
    if (r.app.resolve(r.a, q, &msg)) |p| return r.redirect(try std.fmt.allocPrint(r.a, "/projects/{s}", .{p.path})) else |_| {}
    try r.redirect("/");
}

// ---- pages -------------------------------------------------------------

/// A job as the templates read it, with the Rust idlci's filters applied.
const JobView = struct {
    id: i64,
    project: []const u8,
    command: []const u8,
    targets: []const []const u8,
    targets_text: []const u8,
    configuration: []const u8,
    strict: bool,
    status: []const u8,
    exit_code: ?i32,
    started: bool,
    created_dt: []const u8,
    created_dts: []const u8,
    created_ago: []const u8,
    started_ago: []const u8,
    dur: []const u8,
    repo: ?[]const u8,
    branch: ?[]const u8,
    head: ?[]const u8,
    dirty: bool,
    requested_by: []const u8,
    retry_of: ?i64,
    active: bool,
    // a patch or stack job's subject, and the commits it checked out
    subject: []const u8,
    checkout_lines: []const []const u8,

    fn of(a: Allocator, now: i64, j: db.Job) !JobView {
        return .{
            .id = j.id,
            .project = j.project,
            .command = j.command.name(),
            .targets = j.targets,
            .targets_text = if (j.targets.len == 0) "all" else try std.mem.join(a, " ", j.targets),
            .configuration = @tagName(j.configuration),
            .strict = j.strict,
            .status = @tagName(j.status),
            .exit_code = j.exit_code,
            .started = j.started != null,
            .created_dt = try fmt.dt(a, j.created),
            .created_dts = try fmt.dts(a, j.created),
            .created_ago = try fmt.human(a, now - j.created),
            .started_ago = if (j.started) |s| try fmt.human(a, now - s) else "",
            .dur = try fmt.dur(a, now, j.started, j.finished),
            .repo = j.git.repo,
            .branch = j.git.branch,
            .head = j.git.head,
            .dirty = j.git.dirty,
            .requested_by = @tagName(j.requested_by),
            .retry_of = j.retry_of,
            .active = !j.status.isFinal(),
            .subject = j.subject orelse "",
            .checkout_lines = blk: {
                var lines: std.ArrayList([]const u8) = .empty;
                var it = std.mem.tokenizeScalar(u8, j.checkout orelse "", '\n');
                while (it.next()) |line| try lines.append(a, line);
                break :blk lines.items;
            },
        };
    }

    fn list(a: Allocator, now: i64, jobs: []const db.Job) ![]JobView {
        const out = try a.alloc(JobView, jobs.len);
        for (jobs, out) |j, *v| v.* = try of(a, now, j);
        return out;
    }
};

const BriefView = struct {
    id: i64,
    status: []const u8,
    created_dt: []const u8,
    finished_ago: []const u8,
    dur: []const u8,

    fn of(a: Allocator, now: i64, b: ?app_mod.Brief) !?BriefView {
        const x = b orelse return null;
        return .{
            .id = x.id,
            .status = @tagName(x.status),
            .created_dt = try fmt.dt(a, x.created),
            .finished_ago = if (x.finished) |f| try fmt.human(a, now - f) else "",
            .dur = try fmt.dur(a, now, x.started, x.finished),
        };
    }
};

const LastView = struct { command: []const u8, brief: BriefView };

const ProjectPageView = struct {
    path: []const u8,
    name: []const u8,
    repo: ?[]const u8,
    branch: ?[]const u8,
    head: ?[]const u8,
    dirty: bool,
    targets: []const projects.Target,
    targets_error: ?[]const u8,
    last: []const LastView,
    last_build: ?BriefView,
    last_success: ?BriefView,
    last_failure: ?BriefView,
    running: bool,
    health: ?i64,
    /// the weather icon for `health`
    weather: []const u8,
    /// the dashboard ball: running, else the last build's status
    ball: []const u8,

    fn of(a: Allocator, now: i64, p: app_mod.ProjectView) !ProjectPageView {
        const last = try a.alloc(LastView, p.last.len);
        for (p.last, last) |l, *v| v.* = .{ .command = l.command, .brief = (try BriefView.of(a, now, l.brief)).? };
        const h = p.health orelse 0;
        return .{
            .path = p.path,
            .name = p.name,
            .repo = p.git.repo,
            .branch = p.git.branch,
            .head = p.git.head,
            .dirty = p.git.dirty,
            .targets = p.targets,
            .targets_error = p.targets_error,
            .last = last,
            .last_build = try BriefView.of(a, now, p.last_build),
            .last_success = try BriefView.of(a, now, p.last_success),
            .last_failure = try BriefView.of(a, now, p.last_failure),
            .running = p.running,
            .health = p.health,
            .weather = if (h > 80) "sun" else if (h > 60) "cloud-sun" else if (h > 40) "cloud" else if (h > 20) "cloud-rain" else "cloud-lightning-rain",
            .ball = if (p.running) "running" else if (p.last_build) |b| @tagName(b.status) else "",
        };
    }
};

const ExecutorView = struct {
    number: usize,
    job: ?JobView,
    progress: ?i64,
    /// the progress bar's width: the estimate, else full
    width: i64,
};

/// What every page's sidebar and chrome read (the Rust idlci's base context).
const Base = struct {
    root: []const u8,
    watch: bool,
    commands: []const []const u8,
    queue: []const JobView,
    executors: []const ExecutorView,
    active: bool,
};

fn base(r: *Req, now: i64) !Base {
    const active = try r.app.store.active(r.a);
    var queue: std.ArrayList(JobView) = .empty;
    for (active) |j| if (j.status == .queued) try queue.append(r.a, try JobView.of(r.a, now, j));
    const execs = try r.app.runner.executorList(r.a);
    const ev = try r.a.alloc(ExecutorView, execs.len);
    for (execs, ev) |e, *v| v.* = .{
        .number = e.number,
        .job = if (e.job) |j| try JobView.of(r.a, now, j) else null,
        .progress = e.progress,
        .width = e.progress orelse 100,
    };
    var commands: [db.Command.all.len][]const u8 = undefined;
    for (db.Command.all, &commands) |c, *n| n.* = c.name();
    return .{
        .root = r.app.root,
        .watch = r.app.watch != null,
        .commands = try r.a.dupe([]const u8, &commands),
        .queue = queue.items,
        .executors = ev,
        .active = active.len > 0,
    };
}

fn render(r: *Req, template: []const u8, title: []const u8, crumbs: []const theme.Link, data: anytype) !void {
    const now = db.now(r.io);
    const b = try base(r, now);
    const ws = r.app.workspace_name;
    var all_crumbs: std.ArrayList(theme.Link) = .empty;
    try all_crumbs.append(r.a, .{ .label = ws, .href = "/" });
    try all_crumbs.appendSlice(r.a, crumbs);
    var badges: std.ArrayList(theme.Badge) = .empty;
    try badges.append(r.a, .{ .label = ws, .icon = "boxes", .title = "pull workspace" });
    if (b.watch) try badges.append(r.a, .{ .label = "watching", .icon = "eye", .title = "Polling git HEADs" });
    const layout: theme.Layout = .{
        .title = try std.fmt.allocPrint(r.a, "{s} · {s}", .{ title, site_name }),
        .site = site_name,
        .tools = theme.workspaceTools(r.io, r.a, r.app.root, .idlci, &.{}) catch &.{},
        .nav = try navFor(r.a, template),
        .badges = badges.items,
        .search = .{ .action = "/search", .placeholder = "project or #build" },
        .crumbs = all_crumbs.items,
        .footer = &.{
            .{ .label = "REST API", .href = "/api/projects" },
            .{ .label = "idlci " ++ version },
            .{ .label = r.app.root },
        },
        .stylesheets = &.{"/assets/idlci.css"},
    };
    var out: std.Io.Writer.Allocating = .init(r.a);
    try theme.render(&templates, r.app.gpa, r.a, template, .{ .layout = layout, .page = data, .base = b }, &out.writer);
    try r.html(out.written());
}

/// idlci's own items in the global bar, after the tool switcher.
fn navFor(a: Allocator, template: []const u8) ![]const theme.Link {
    const items = [_]struct { label: []const u8, href: []const u8, page: []const u8 }{
        .{ .label = "Dashboard", .href = "/", .page = "ci/dashboard.html" },
        .{ .label = "Build History", .href = "/jobs", .page = "ci/jobs.html" },
    };
    const out = try a.alloc(theme.Link, items.len);
    for (items, out) |item, *link| link.* = .{ .label = item.label, .href = item.href, .active = std.mem.eql(u8, item.page, template) };
    return out;
}

fn dashboard(r: *Req) !void {
    const now = db.now(r.io);
    const views = try r.app.projectViews(r.a, null);
    const pv = try r.a.alloc(ProjectPageView, views.len);
    for (views, pv) |v, *p| p.* = try ProjectPageView.of(r.a, now, v);
    try render(r, "ci/dashboard.html", "Dashboard", &.{}, .{ .refresh = true, .projects = pv });
}

fn historyHref(a: Allocator, project: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("/jobs?project=");
    try std.Uri.Component.percentEncode(&out.writer, project, struct {
        fn ok(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        }
    }.ok);
    return out.written();
}

fn projectPage(r: *Req, arg: []const u8) !void {
    var msg: []const u8 = "";
    const p = r.app.resolve(r.a, arg, &msg) catch |e| return if (e == error.NotFound) r.fail(.not_found, msg) else e;
    const now = db.now(r.io);
    const views = try r.app.projectViews(r.a, p.path);
    if (views.len == 0) return r.fail(.not_found, msg);
    const view = try ProjectPageView.of(r.a, now, views[0]);
    const builds = try r.app.store.list(r.a, .{ .project = p.path, .limit = 30 });
    const yml = try std.fs.path.join(r.a, &.{ p.dir, "idlproj.yml" });
    const config = Io.Dir.cwd().readFileAlloc(r.io, yml, r.a, .limited(1 << 20)) catch "";
    const Permalink = struct { label: []const u8, brief: BriefView };
    var links: std.ArrayList(Permalink) = .empty;
    if (view.last_build) |b| try links.append(r.a, .{ .label = "Last build", .brief = b });
    if (view.last_success) |b| try links.append(r.a, .{ .label = "Last successful build", .brief = b });
    if (view.last_failure) |b| try links.append(r.a, .{ .label = "Last failed build", .brief = b });
    const crumbs = [_]theme.Link{.{ .label = p.path, .href = try std.fmt.allocPrint(r.a, "/projects/{s}", .{p.path}) }};
    try render(r, "ci/project.html", p.path, &crumbs, .{
        .refresh = false,
        .project = view,
        .builds = try JobView.list(r.a, now, builds),
        .history_href = try historyHref(r.a, p.path),
        .permalinks = links.items,
        .config = config,
        .targets_size = if (view.targets.len == 0) 2 else @min(view.targets.len, 8),
    });
}

fn jobsPage(r: *Req) !void {
    const f = try filter(r) orelse return;
    const now = db.now(r.io);
    const jobs = try r.app.store.list(r.a, f);
    const list = try r.app.projectList(r.a);
    const names = try r.a.alloc([]const u8, list.len);
    for (list, names) |p, *n| n.* = p.path;
    var statuses: [db.Status.all.len][]const u8 = undefined;
    for (db.Status.all, &statuses) |s, *n| n.* = @tagName(s);
    const crumbs = [_]theme.Link{.{ .label = "Build History", .href = "/jobs" }};
    try render(r, "ci/jobs.html", "Build History", &crumbs, .{
        .refresh = true,
        .jobs = try JobView.list(r.a, now, jobs),
        .projects = names,
        .statuses = try r.a.dupe([]const u8, &statuses),
        .status = r.param("status") orelse "",
        .project = r.param("project") orelse "",
    });
}

fn jobPage(r: *Req, id: i64) !void {
    const job = try jobOr404(r, id) orelse return;
    const now = db.now(r.io);
    const builds = try r.app.store.list(r.a, .{ .project = job.project, .limit = 30 });
    const crumbs = [_]theme.Link{
        .{ .label = job.project, .href = try std.fmt.allocPrint(r.a, "/projects/{s}", .{job.project}) },
        .{ .label = try std.fmt.allocPrint(r.a, "#{d}", .{id}), .href = try std.fmt.allocPrint(r.a, "/jobs/{d}", .{id}) },
    };
    const args = try job.command.idlArgs(r.a, job.configuration, job.strict, job.targets);
    try render(r, "ci/job.html", try std.fmt.allocPrint(r.a, "{s} #{d}", .{ job.project, id }), &crumbs, .{
        .refresh = false,
        .job = try JobView.of(r.a, now, job),
        .builds = try JobView.list(r.a, now, builds),
        .history_href = try historyHref(r.a, job.project),
        .args = try std.mem.join(r.a, " ", args),
    });
}
