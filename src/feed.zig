//! GET /api/feed: the jobs that reached a final status (passed, failed,
//! cancelled) after a cursor, oldest first, each with its idl command line and
//! the end of its log. cpull polls it to file, comment on and close its `ci`
//! issues (this replaced the runner's in-process on_finish hook). The cursor
//! is "<finished>.<id>" of the last job returned; only jobs finished before
//! the current second are listed, so jobs finishing in the same second as the
//! cursor's are never skipped.
const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const tail_lines = 30;
pub const tail_bytes = 6 * 1024;

pub const Page = struct {
    cursor: []const u8,
    jobs: []const FeedJob,
};

/// A Job plus `idl` ("idl build -c release") and `log_tail`.
pub const FeedJob = struct {
    job: db.Job,
    idl: []const u8,
    log_tail: []const u8,

    pub fn of(io: Io, a: Allocator, j: db.Job) !FeedJob {
        const args = try j.command.idlArgs(a, j.configuration, j.strict, &.{});
        const text = Io.Dir.cwd().readFileAlloc(io, j.log, a, .limited(64 << 20)) catch "";
        return .{
            .job = j,
            .idl = try std.fmt.allocPrint(a, "idl {s}", .{try std.mem.join(a, " ", args)}),
            .log_tail = tail(text, tail_lines, tail_bytes),
        };
    }

    pub fn jsonStringify(f: FeedJob, w: anytype) !void {
        try w.beginObject();
        try f.job.writeFields(w);
        try w.objectField("idl");
        try w.write(f.idl);
        try w.objectField("log_tail");
        try w.write(f.log_tail);
        try w.endObject();
    }
};

pub fn formatCursor(a: Allocator, finished: i64, id: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}", .{ finished, id });
}

pub fn parseCursor(s: []const u8) ?struct { i64, i64 } {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    const f = std.fmt.parseInt(i64, s[0..dot], 10) catch return null;
    const id = std.fmt.parseInt(i64, s[dot + 1 ..], 10) catch return null;
    return .{ f, id };
}

/// The last `lines` lines of `text`, at most `max` bytes, not starting mid UTF-8.
pub fn tail(text_in: []const u8, lines: usize, max: usize) []const u8 {
    const text = std.mem.trimEnd(u8, text_in, " \r\n");
    var start = text.len;
    var n: usize = 0;
    while (start > 0) {
        if (text[start - 1] == '\n') {
            n += 1;
            if (n == lines) break;
        }
        start -= 1;
    }
    if (text.len - start > max) start = text.len - max;
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    return text[start..];
}

test tail {
    try std.testing.expectEqualStrings("c\nd", tail("a\nb\nc\nd\n", 2, 100));
    try std.testing.expectEqualStrings("a\nb", tail("a\nb", 5, 100));
    try std.testing.expectEqualStrings("cd", tail("abcd", 5, 2));
}

test parseCursor {
    try std.testing.expectEqual(@as(i64, 17), parseCursor("12.17").?[1]);
    try std.testing.expect(parseCursor("x") == null);
}
