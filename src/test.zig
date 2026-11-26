//! idlci end to end over HTTP: every page renders (the Rust idlci's
//! pages_render test), the JSON API queues, lists, cancels and retries, and
//! cpull's routes (runs, status, feed) answer.
const std = @import("std");
const App = @import("app.zig").App;
const web = @import("web.zig");

const Io = std.Io;

fn serve(io: Io, server: *Io.net.Server, app: *App) void {
    while (true) {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var recv: [4096]u8 = undefined;
        var send: [4096]u8 = undefined;
        var br = stream.reader(io, &recv);
        var bw = stream.writer(io, &send);
        var http = std.http.Server.init(&br.interface, &bw.interface);
        while (http.reader.state == .ready) {
            var request = http.receiveHead() catch break;
            web.handle(app, io, &request, std.heap.smp_allocator) catch break;
        }
    }
}

const Fetched = struct { status: std.http.Status, body: []const u8 };

fn fetch(a: std.mem.Allocator, client: *std.http.Client, port: u16, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Fetched {
    var out: std.Io.Writer.Allocating = .init(a);
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, path }) },
        .method = method,
        .payload = payload,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    return .{ .status = res.status, .body = out.written() };
}

fn contains2(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack[0..@min(haystack.len, 4000)] });
    return false;
}

test "pages render and the API answers" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "group/app-ios");
    try tmp.dir.writeFile(io, .{ .sub_path = "group/app-ios/idlproj.yml", .data = "name: App\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    var env = std.process.Environ.Map.init(a);
    try env.put("IDLCI_IDL", "/bin/false");
    const app = try App.init(io, std.heap.smp_allocator, root, &env, .{ .jobs = 2, .watch = 15, .start_workers = false, .workspace_name = "ws" });

    var msg: []const u8 = "";
    const job = (try app.enqueue(a, .{ .project = "app-ios", .command = .build }, &msg)).job;
    try std.testing.expectEqualStrings("group/app-ios", job.project);
    _ = try app.store.claimNext(a);
    try app.store.finish(job.id, .failed, 1);
    _ = try app.enqueue(a, .{ .project = "app-ios", .command = .@"test" }, &msg);

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    (try std.Thread.spawn(.{}, serve, .{ io, &server, app })).detach();
    var client: std.http.Client = .{ .allocator = a, .io = io };

    const dash = try fetch(a, &client, port, .GET, "/", null);
    try std.testing.expectEqual(std.http.Status.ok, dash.status);
    try std.testing.expect(contains(dash.body, "group/app-ios"));
    try std.testing.expect(contains(dash.body, "Build Queue (1)"));
    try std.testing.expect(contains(dash.body, "w-cloud-lightning-rain"));
    try std.testing.expect(contains(dash.body, "watching"));
    try std.testing.expect(contains(dash.body, "nav-link active\" href=\"/\" data-tool=\"idlci\""));

    const project = try fetch(a, &client, port, .GET, "/projects/group/app-ios", null);
    try std.testing.expect(contains(project.body, "Build with Parameters"));
    try std.testing.expect(contains(project.body, "name: App"));
    try std.testing.expect(contains(project.body, "idl list failed"));
    try std.testing.expect(contains(project.body, "/jobs?project=group%2Fapp-ios"));
    try std.testing.expect(!contains2(project.body, "/ci/"));

    const jobs = try fetch(a, &client, port, .GET, "/jobs", null);
    try std.testing.expect(contains(jobs.body, try std.fmt.allocPrint(a, "#{d}", .{job.id})));
    const failed = try fetch(a, &client, port, .GET, "/jobs?status=failed&project=app-ios", null);
    try std.testing.expect(contains(failed.body, "Build History of app-ios"));

    const page = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/jobs/{d}", .{job.id}), null);
    try std.testing.expect(contains(page.body, try std.fmt.allocPrint(a, "Build #{d}", .{job.id})));
    try std.testing.expect(contains(page.body, "Console Output"));

    const missing = try fetch(a, &client, port, .GET, "/jobs/999", null);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
    try std.testing.expectEqualStrings("{\"error\":\"no job #999\"}", missing.body);

    const health = try fetch(a, &client, port, .GET, "/api/health", null);
    try std.testing.expect(contains(health.body, root));
    try std.testing.expect(contains(health.body, "\"tool\":\"idlci\""));
    const css = try fetch(a, &client, port, .GET, "/assets/style.css", null);
    try std.testing.expectEqual(std.http.Status.ok, css.status);
    const old = try fetch(a, &client, port, .GET, "/ci/jobs?status=failed", null);
    try std.testing.expectEqual(std.http.Status.moved_permanently, old.status);

    const api = try fetch(a, &client, port, .GET, "/api/projects", null);
    try std.testing.expect(contains(api.body, "\"path\":\"group/app-ios\",\"name\":\"app-ios\""));
    try std.testing.expect(contains(api.body, "\"last\":{\"build\":{"));

    const queued = try fetch(a, &client, port, .POST, "/api/jobs", "{\"project\":\"app-ios\",\"command\":\"fmt-check\",\"requested_by\":\"web\"}");
    try std.testing.expectEqual(std.http.Status.ok, queued.status);
    try std.testing.expect(contains(queued.body, "\"command\":\"fmt-check\""));
    try std.testing.expect(contains(queued.body, "\"deduplicated\":false"));
    const again = try fetch(a, &client, port, .POST, "/api/jobs", "{\"project\":\"app-ios\",\"command\":\"fmt-check\"}");
    try std.testing.expect(contains(again.body, "\"deduplicated\":true"));
    const bad = try fetch(a, &client, port, .POST, "/api/jobs", "{\"project\":\"nope\",\"command\":\"build\"}");
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
    try std.testing.expect(contains(bad.body, "unknown project"));

    const cancel = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/api/jobs/{d}/cancel", .{job.id + 2}), "null");
    try std.testing.expect(contains(cancel.body, "\"status\":\"cancelled\""));
    const retry = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/api/jobs/{d}/retry?by=mcp", .{job.id}), "null");
    try std.testing.expect(contains(retry.body, try std.fmt.allocPrint(a, "\"requested_by\":\"mcp\",\"retry_of\":{d}", .{job.id})));

    const log = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/api/jobs/{d}/log?tail=5", .{job.id}), null);
    try std.testing.expect(contains(log.body, "\"text\":\"\""));
    const search = try fetch(a, &client, port, .GET, "/search?q=%23" ++ "1", null);
    try std.testing.expectEqual(std.http.Status.see_other, search.status);
}

fn git(io: Io, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]const u8 {
    const full = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", cwd }, argv });
    const r = try std.process.run(a, io, .{ .argv = full });
    if (!r.term.success()) {
        std.debug.print("git {s}: {s}\n", .{ try std.mem.join(a, " ", argv), r.stderr });
        return error.GitFailed;
    }
    return std.mem.trimEnd(u8, r.stdout, "\n");
}

test "runs, status and the feed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "pullfile.plist", .data =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict><key>repos</key><array>
        \\<dict><key>name</key><string>core</string><key>branch</key><string>main</string></dict>
        \\<dict><key>name</key><string>other</string></dict>
        \\</array></dict></plist>
    });
    try tmp.dir.createDirPath(io, "core");
    try tmp.dir.writeFile(io, .{ .sub_path = "core/idlproj.yml", .data = "name: Core\n" });
    const core = try std.fs.path.join(a, &.{ root, "core" });
    _ = try git(io, a, core, &.{ "init", "-q", "-b", "main" });
    _ = try git(io, a, core, &.{ "add", "." });
    _ = try git(io, a, core, &.{ "commit", "-qm", "one" });
    _ = try git(io, a, core, &.{ "checkout", "-qb", "feat" });
    try tmp.dir.writeFile(io, .{ .sub_path = "core/b.txt", .data = "b\n" });
    _ = try git(io, a, core, &.{ "add", "." });
    _ = try git(io, a, core, &.{ "commit", "-qm", "two" });
    const tip = try git(io, a, core, &.{ "rev-parse", "HEAD" });
    _ = try git(io, a, core, &.{ "checkout", "-q", "main" });

    var env = std.process.Environ.Map.init(a);
    try env.put("IDLCI_IDL", "/bin/false");
    const app = try App.init(io, std.heap.smp_allocator, root, &env, .{ .start_workers = false, .workspace_name = "ws" });

    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    const port = server.socket.address.getPort();
    (try std.Thread.spawn(.{}, serve, .{ io, &server, app })).detach();
    var client: std.http.Client = .{ .allocator = a, .io = io };

    // a workspace job on core, finished: the repo's ball and the feed
    const feed0 = try fetch(a, &client, port, .GET, "/api/feed", null);
    try std.testing.expect(contains(feed0.body, "\"cursor\":\"0.0\",\"jobs\":[]"));
    var msg: []const u8 = "";
    const job = (try app.enqueue(a, .{ .project = "core", .command = .build }, &msg)).job;
    try std.testing.expectEqualStrings("core", job.git.repo.?);
    _ = try app.store.claimNext(a);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = job.log, .data = "line 1\nerror: broken\n" });
    try app.store.finish(job.id, .failed, 1);

    const repos = try fetch(a, &client, port, .GET, "/api/status/repos", null);
    try std.testing.expect(contains(repos.body, "\"core\":{\"ball\":\"failed\",\"label\":\"CI failed: build core\""));
    try std.testing.expect(contains(repos.body, "\"other\":null"));
    const one = try fetch(a, &client, port, .GET, "/api/status/repo/core", null);
    try std.testing.expect(contains(one.body, try std.fmt.allocPrint(a, "\"href\":\"/jobs/{d}\"", .{job.id})));
    const commits = try fetch(a, &client, port, .GET, "/api/status/commits?repo=core", null);
    try std.testing.expect(contains(commits.body, try std.fmt.allocPrint(a, "\"{s}\":{{\"ball\":\"failed\"", .{job.git.head.?})));

    // the feed lists it once its second has passed, with the idl line and the log's tail
    io.sleep(.fromMilliseconds(1100), .awake) catch {};
    const feed1 = try fetch(a, &client, port, .GET, "/api/feed?cursor=0.0&wait=2", null);
    try std.testing.expect(contains(feed1.body, "\"idl\":\"idl build\",\"log_tail\":\"line 1\\nerror: broken\""));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, feed1.body, .{});
    const cursor = parsed.object.get("cursor").?.string;
    try std.testing.expect(!std.mem.eql(u8, cursor, "0.0"));
    const feed2 = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/api/feed?cursor={s}&wait=1", .{cursor}), null);
    try std.testing.expect(contains(feed2.body, "\"jobs\":[]"));
    try std.testing.expect(contains(feed2.body, cursor));

    // a patch run: build + test of core at the patch's tip, with its subject
    const body = try std.fmt.allocPrint(a,
        \\{{"subject":"patch:core:p1","members":[{{"repo":"core","patch_id":"p1","branch":"feat","oid":"{s}"}}],"requested_by":"web"}}
    , .{tip});
    const run = try fetch(a, &client, port, .POST, "/api/runs", body);
    try std.testing.expectEqual(std.http.Status.ok, run.status);
    try std.testing.expect(contains(run.body, try std.fmt.allocPrint(a, "\"subject\":\"patch:core:p1\",\"checkout\":\"core {s}\"", .{tip})));
    try std.testing.expect(contains(run.body, "\"command\":\"test\""));
    try std.testing.expect(contains(run.body, "\"branch\":\"feat\""));
    const bad = try fetch(a, &client, port, .POST, "/api/runs", "{\"subject\":\"patch:nope:1\",\"members\":[{\"repo\":\"nope\",\"oid\":\"0123456789\"}]}");
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
    try std.testing.expect(contains(bad.body, "no repo nope in the pullfile"));

    const subj = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/api/status/subject?subject=patch%3Acore%3Ap1&tips=core%20{s}", .{tip}), null);
    try std.testing.expect(contains(subj.body, "\"ball\":\"running\""));
    try std.testing.expect(contains(subj.body, "\"stale\":false"));
    const stale = try fetch(a, &client, port, .GET, "/api/status/subject?subject=patch%3Acore%3Ap1&tips=core%200000000", null);
    try std.testing.expect(contains(stale.body, "\"stale\":true"));
    const none = try fetch(a, &client, port, .GET, "/api/status/subject?subject=stack%3Ax", null);
    try std.testing.expectEqualStrings("null", none.body);

    // cross-origin writes are refused
    var out: std.Io.Writer.Allocating = .init(a);
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/api/jobs", .{port}) },
        .method = .POST,
        .payload = "{\"project\":\"core\",\"command\":\"build\"}",
        .response_writer = &out.writer,
        .extra_headers = &.{.{ .name = "origin", .value = "http://evil.example" }},
        .keep_alive = false,
    });
    try std.testing.expectEqual(std.http.Status.forbidden, res.status);

    const clean = try fetch(a, &client, port, .POST, "/api/work/cleanup?days=1&dry_run=1", "null");
    try std.testing.expect(contains(clean.body, "\"removed\":[]"));
}
