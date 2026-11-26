//! Times as idlci's minijinja filters wrote them: `dt`, `dts` (local time, via
//! libc's localtime_r, which SQLite already links), `ago` and `dur`.
const std = @import("std");

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn local(ts: i64) ?Tm {
    var tm: Tm = undefined;
    const t: c_long = @intCast(ts);
    _ = localtime_r(&t, &tm) orelse return null;
    return tm;
}

fn hour12(h: c_int) c_int {
    const m = @mod(h, 12);
    return if (m == 0) 12 else m;
}

/// "%b %-d, %Y, %-I:%M:%S %p", e.g. "Nov 25, 2026, 3:04:05 PM".
pub fn dt(a: std.mem.Allocator, ts: i64) ![]const u8 {
    const t = local(ts) orelse return "";
    return std.fmt.allocPrint(a, "{s} {d}, {d}, {d}:{d:0>2}:{d:0>2} {s}", .{
        months[@intCast(t.mon)], t.mday, t.year + 1900, hour12(t.hour), @as(u32, @intCast(t.min)), @as(u32, @intCast(t.sec)), if (t.hour < 12) "AM" else "PM",
    });
}

/// "%b %-d, %-I:%M %p", e.g. "Nov 25, 3:04 PM".
pub fn dts(a: std.mem.Allocator, ts: i64) ![]const u8 {
    const t = local(ts) orelse return "";
    return std.fmt.allocPrint(a, "{s} {d}, {d}:{d:0>2} {s}", .{
        months[@intCast(t.mon)], t.mday, hour12(t.hour), @as(u32, @intCast(t.min)), if (t.hour < 12) "AM" else "PM",
    });
}

/// A duration as idlci's `human`: "12 sec", "3 min 4 sec", "2 hr 5 min", "3 days".
pub fn human(a: std.mem.Allocator, secs: i64) ![]const u8 {
    const s = @max(secs, 0);
    if (s < 60) return std.fmt.allocPrint(a, "{d} sec", .{s});
    if (s < 3600) return std.fmt.allocPrint(a, "{d} min {d} sec", .{ @divTrunc(s, 60), @mod(s, 60) });
    if (s < 86400) return std.fmt.allocPrint(a, "{d} hr {d} min", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) });
    return std.fmt.allocPrint(a, "{d} days", .{@divTrunc(s, 86400)});
}

/// `started|dur(finished)`: empty until started, running time while running.
pub fn dur(a: std.mem.Allocator, now: i64, started: ?i64, finished: ?i64) ![]const u8 {
    const s = started orelse return "";
    return human(a, (finished orelse now) - s);
}

test human {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("59 sec", try human(a, 59));
    try std.testing.expectEqualStrings("1 min 1 sec", try human(a, 61));
    try std.testing.expectEqualStrings("1 hr 1 min", try human(a, 3661));
    try std.testing.expectEqualStrings("2 days", try human(a, 2 * 86400 + 5));
}
