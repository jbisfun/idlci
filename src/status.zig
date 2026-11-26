//! CI status summaries for cpull's pages (GET /api/status/...): a repo's latest
//! workspace jobs, the jobs that ran on each commit, and a patch's or stack's
//! latest jobs, each reduced to one Jenkins ball, a label and a link (a path
//! on idlci's server, which cpull prefixes with idlci's base url).
const std = @import("std");
const db = @import("db.zig");
const fmt = @import("fmt.zig");
const work = @import("work.zig");

const Allocator = std.mem.Allocator;

pub const JobRef = struct {
    id: i64,
    // "build fossify-ios/calculator-ios [App]"
    label: []const u8,
    status: []const u8,
    ball: []const u8,
    href: []const u8,
    // local time it was queued
    when: []const u8,
    head: []const u8,
};

pub const Summary = struct {
    // passed, failed, running or none (theme .ball-<x>)
    ball: []const u8,
    label: []const u8,
    href: []const u8,
    jobs: []const JobRef,
    // every job passed
    green: bool,
    // a subject's jobs ran on older commits than its branches hold now
    stale: bool = false,
};

pub fn ballOf(s: db.Status) []const u8 {
    return switch (s) {
        .queued, .running => "running",
        .passed => "passed",
        .failed => "failed",
        .cancelled => "none",
    };
}

pub fn jobRef(a: Allocator, j: db.Job) !JobRef {
    var label: std.Io.Writer.Allocating = .init(a);
    try label.writer.print("{s} {s}", .{ j.command.name(), j.project });
    if (j.targets.len > 0) try label.writer.print(" [{s}]", .{try std.mem.join(a, " ", j.targets)});
    return .{
        .id = j.id,
        .label = label.written(),
        .status = @tagName(j.status),
        .ball = ballOf(j.status),
        .href = try std.fmt.allocPrint(a, "/jobs/{d}", .{j.id}),
        .when = try fmt.dts(a, j.created),
        .head = j.git.head orelse "",
    };
}

// one ball for a set of latest jobs (one per project + command), or null for none
pub fn summarize(a: Allocator, jobs: []const db.Job, href: []const u8) !?Summary {
    if (jobs.len == 0) return null;
    var refs: std.ArrayList(JobRef) = .empty;
    var active: usize = 0;
    var failed: std.ArrayList([]const u8) = .empty;
    var passed: usize = 0;
    for (jobs) |j| {
        const ref = try jobRef(a, j);
        try refs.append(a, ref);
        switch (j.status) {
            .queued, .running => active += 1,
            .failed => try failed.append(a, ref.label),
            .passed => passed += 1,
            .cancelled => {},
        }
    }
    const n = jobs.len;
    const ball: []const u8, const label: []const u8 = if (active > 0)
        .{ "running", try std.fmt.allocPrint(a, "CI running ({d} of {d} jobs)", .{ active, n }) }
    else if (failed.items.len > 0)
        .{ "failed", try std.fmt.allocPrint(a, "CI failed: {s}", .{try std.mem.join(a, ", ", failed.items)}) }
    else if (passed == n)
        .{ "passed", try std.fmt.allocPrint(a, "CI passed ({d} job{s})", .{ n, if (n == 1) "" else "s" }) }
    else
        .{ "none", try std.fmt.allocPrint(a, "CI cancelled ({d} of {d} jobs passed)", .{ passed, n }) };
    return .{ .ball = ball, .label = label, .href = href, .jobs = refs.items, .green = passed == n };
}

// the url of a set of jobs: the project page when they share one, else the job list
fn jobsHref(a: Allocator, jobs: []const db.Job) ![]const u8 {
    if (jobs.len == 0) return "/";
    for (jobs[1..]) |j| if (!std.mem.eql(u8, j.project, jobs[0].project)) return "/jobs";
    return std.fmt.allocPrint(a, "/projects/{s}", .{jobs[0].project});
}

// a repo's idl projects at its workspace checkout
pub fn forRepo(a: Allocator, store: *db.Store, repo: []const u8) !?Summary {
    const jobs = try store.latestForRepo(a, repo);
    return summarize(a, jobs, try jobsHref(a, jobs));
}

// a patch's or stack's latest jobs; `tips` ("<repo> <oid>" lines) marks them
// stale when they ran on other commits
pub fn forSubject(a: Allocator, store: *db.Store, subject: []const u8, tips: ?[]const u8) !?Summary {
    const jobs = try store.latestForSubject(a, subject);
    var s = try summarize(a, jobs, try jobsHref(a, jobs)) orelse return null;
    if (tips) |t| s.stale = isStale(a, jobs, t);
    if (s.stale) {
        s.green = false;
        if (std.mem.eql(u8, s.ball, "passed")) s.ball = "warning";
        s.label = try std.fmt.allocPrint(a, "{s}; ran on older commits", .{s.label});
    }
    return s;
}

pub fn isStale(a: Allocator, jobs: []const db.Job, tips: []const u8) bool {
    const lines = work.parseCheckout(a, tips) catch return true;
    for (jobs) |j| {
        const checkout = j.checkout orelse return true;
        for (lines) |line| {
            const ran = work.oidOf(checkout, line.repo) orelse return true;
            if (!std.mem.eql(u8, ran, line.oid)) return true;
        }
    }
    return false;
}

// the jobs that ran on each commit of a repo: short oid -> summary
pub const CommitIndex = struct {
    map: std.StringArrayHashMapUnmanaged(Summary) = .empty,

    pub fn jsonStringify(self: CommitIndex, w: anytype) !void {
        try w.beginObject();
        var it = self.map.iterator();
        while (it.next()) |e| {
            try w.objectField(e.key_ptr.*);
            try w.write(e.value_ptr.*);
        }
        try w.endObject();
    }

    pub fn get(self: CommitIndex, oid: []const u8) ?Summary {
        return self.map.get(oid[0..@min(oid.len, 7)]);
    }
};

pub fn commitIndex(a: Allocator, store: *db.Store, repo: []const u8) !CommitIndex {
    const jobs = try store.withHeads(a, repo, 500);
    // newest first: the first job per (head, project, command) is the latest
    var by_head: std.StringArrayHashMapUnmanaged(std.ArrayList(db.Job)) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (jobs) |j| {
        const head = j.git.head orelse continue;
        if (head.len < 7 or j.git.dirty) continue;
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{s}", .{ head[0..7], j.project, j.command.name() });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        const gop = try by_head.getOrPut(a, head[0..7]);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, j);
    }
    var index: CommitIndex = .{};
    var it = by_head.iterator();
    while (it.next()) |e| {
        const list = e.value_ptr.items;
        const href = if (list.len == 1) try std.fmt.allocPrint(a, "/jobs/{d}", .{list[0].id}) else try jobsHref(a, list);
        if (try summarize(a, list, href)) |s| try index.map.put(a, e.key_ptr.*, s);
    }
    return index;
}

test summarize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: db.Job = .{ .id = 1, .project = "p", .command = .build, .targets = &.{}, .configuration = .none, .strict = false, .status = .passed, .exit_code = 0, .created = 0, .started = null, .finished = null, .git = .{}, .requested_by = .cli, .retry_of = null, .log = "" };
    var t = base;
    t.id = 2;
    t.command = .@"test";
    t.status = .failed;
    const s = (try summarize(a, &.{ base, t }, "/")).?;
    try std.testing.expectEqualStrings("failed", s.ball);
    try std.testing.expectEqualStrings("CI failed: test p", s.label);
    try std.testing.expect(!s.green);
    try std.testing.expect((try summarize(a, &.{base}, "/")).?.green);
    var c = base;
    c.checkout = "core aaa\nlib bbb";
    try std.testing.expect(!isStale(a, &.{c}, "core aaa"));
    try std.testing.expect(isStale(a, &.{c}, "core ccc"));
    try std.testing.expect(isStale(a, &.{base}, "core aaa"));
}
