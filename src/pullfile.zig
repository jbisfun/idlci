// the parts of a pull workspace's pullfile.plist cpull reads: the repo list and
// the `cpull` section. pull (github.com/jbisfun/pull) owns the file and writes
// it; cpull only reads it, with the same xml package pull parses it with.
const std = @import("std");
const xml = @import("xml");

pub const file_name = "pullfile.plist";

pub const Repo = struct {
    // the directory under the workspace root, maybe nested ("group/name")
    name: []const u8,
    upstream: []const u8 = "",
    branch: []const u8 = "main",
    // the commit pull pins the repo to
    commit: ?[]const u8 = null,
};

pub const Pullfile = struct {
    repos: []const Repo,
    // the pullfile `cpull` section's `events`: the repo whose cpull/events holds
    // the workspace's own issues and stacks, when the root isn't a git repo
    events_repo: ?[]const u8 = null,
    // the `cpull` section's CI x forge switches (src/integrate): refuse to merge
    // a stack whose latest CI isn't green (unless forced), file an issue when a
    // default-branch CI job fails, close issues a landed commit `fixes #id`
    require_ci: bool = false,
    ci_issues: bool = true,
    close_issues: bool = true,
};

pub const Error = error{ MalformedXml, InvalidPlist } || std.mem.Allocator.Error;

// a plist value, reduced to what a pullfile uses
const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    other,
    array: []const Value,
    dict: []const Entry,

    const Entry = struct { key: []const u8, value: Value };

    fn get(self: Value, key: []const u8) ?Value {
        if (self != .dict) return null;
        for (self.dict) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }

    fn str(self: ?Value) ?[]const u8 {
        const value = self orelse return null;
        return if (value == .string) value.string else null;
    }

    // <true/>/<false/>, or the strings "true"/"false"
    fn flag(self: ?Value, default: bool) bool {
        const value = self orelse return default;
        return switch (value) {
            .boolean => |b| b,
            .string => |text| if (std.mem.eql(u8, text, "true")) true else if (std.mem.eql(u8, text, "false")) false else default,
            else => default,
        };
    }
};

// everything is allocated in `arena`
pub fn parse(arena: std.mem.Allocator, data: []const u8) Error!Pullfile {
    const root = try parsePlist(arena, data);
    if (root != .dict) return error.InvalidPlist;
    var repos: std.ArrayList(Repo) = .empty;
    if (root.get("repos")) |list| {
        if (list != .array) return error.InvalidPlist;
        for (list.array) |item| {
            const name = Value.str(item.get("name")) orelse return error.InvalidPlist;
            try repos.append(arena, .{
                .name = name,
                .upstream = Value.str(item.get("upstream")) orelse "",
                .branch = Value.str(item.get("branch")) orelse "main",
                .commit = Value.str(item.get("commit")),
            });
        }
    }
    // `haxy`: the section's name before the fork was renamed to cpull
    const section = root.get("cpull") orelse root.get("haxy");
    const events_repo = if (section) |sec| Value.str(sec.get("events")) else null;
    var pf: Pullfile = .{ .repos = repos.items, .events_repo = events_repo };
    if (section) |sec| {
        pf.require_ci = Value.flag(sec.get("require_ci"), pf.require_ci);
        pf.ci_issues = Value.flag(sec.get("ci_issues"), pf.ci_issues);
        pf.close_issues = Value.flag(sec.get("close_issues"), pf.close_issues);
    }
    return pf;
}

fn parsePlist(arena: std.mem.Allocator, data: []const u8) Error!Value {
    var static_reader: xml.Reader.Static = .init(arena, data, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const r = &static_reader.interface;
    while (true) {
        const node = r.read() catch return error.MalformedXml;
        switch (node) {
            .eof => return error.InvalidPlist,
            .element_start => {
                if (std.mem.eql(u8, r.elementName(), "plist")) return (try nextValue(arena, r)) orelse error.InvalidPlist;
                return parseElement(arena, r);
            },
            else => {},
        }
    }
}

// the next child value of the current container, or null at its end tag
fn nextValue(arena: std.mem.Allocator, r: *xml.Reader) Error!?Value {
    while (true) {
        const node = r.read() catch return error.MalformedXml;
        switch (node) {
            .element_start => return try parseElement(arena, r),
            .element_end, .eof => return null,
            .text => if (std.mem.trim(u8, r.textRaw(), " \t\r\n").len != 0) return error.InvalidPlist,
            else => {},
        }
    }
}

fn readText(arena: std.mem.Allocator, r: *xml.Reader) Error![]u8 {
    return r.readElementTextAlloc(arena) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedXml,
    };
}

fn parseElement(arena: std.mem.Allocator, r: *xml.Reader) Error!Value {
    const name = r.elementName();
    if (std.mem.eql(u8, name, "dict")) {
        var entries: std.ArrayList(Value.Entry) = .empty;
        while (true) {
            const node = r.read() catch return error.MalformedXml;
            switch (node) {
                .element_start => {
                    if (!std.mem.eql(u8, r.elementName(), "key")) return error.InvalidPlist;
                    const key = try readText(arena, r);
                    const value = (try nextValue(arena, r)) orelse return error.InvalidPlist;
                    try entries.append(arena, .{ .key = key, .value = value });
                },
                .element_end => return .{ .dict = entries.items },
                .eof => return error.InvalidPlist,
                else => {},
            }
        }
    }
    if (std.mem.eql(u8, name, "array")) {
        var items: std.ArrayList(Value) = .empty;
        while (try nextValue(arena, r)) |value| try items.append(arena, value);
        return .{ .array = items.items };
    }
    const is_string = std.mem.eql(u8, name, "string");
    const is_true = std.mem.eql(u8, name, "true");
    const is_false = std.mem.eql(u8, name, "false");
    const text = try readText(arena, r);
    if (is_true or is_false) return .{ .boolean = is_true };
    return if (is_string) .{ .string = text } else .other;
}

// the nearest directory at or above `start` holding a pullfile, or null
pub fn findRoot(io: std.Io, arena: std.mem.Allocator, start: []const u8) !?[]const u8 {
    var dir: []const u8 = start;
    while (true) {
        const path = try std.Io.Dir.path.join(arena, &.{ dir, file_name });
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            if (stat.kind == .file) return dir;
        } else |_| {}
        dir = std.Io.Dir.path.dirname(dir) orelse return null;
    }
}

pub fn load(io: std.Io, arena: std.mem.Allocator, root: []const u8) !Pullfile {
    const path = try std.Io.Dir.path.join(arena, &.{ root, file_name });
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
    return parse(arena, data);
}

test "pullfile repos and cpull section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pf = try parse(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>identity</key>
        \\    <dict>
        \\        <key>email</key>
        \\        <string>local</string>
        \\        <key>require_signing</key>
        \\        <false/>
        \\    </dict>
        \\    <key>hooks</key>
        \\    <dict>
        \\        <key>precommit</key>
        \\        <array>
        \\            <string>cp &quot;$PULL_ROOT/pullfile.plist&quot; x &amp;&amp; true</string>
        \\        </array>
        \\        <key>postcommit</key>
        \\        <array/>
        \\    </dict>
        \\    <key>cpull</key>
        \\    <dict>
        \\        <key>events</key>
        \\        <string>dotenv</string>
        \\    </dict>
        \\    <key>lint</key>
        \\    <dict>
        \\        <key>max_subject_length</key>
        \\        <integer>40</integer>
        \\    </dict>
        \\    <key>repos</key>
        \\    <array>
        \\        <dict>
        \\            <key>name</key>
        \\            <string>core</string>
        \\            <key>upstream</key>
        \\            <string>file:///tmp/core.git</string>
        \\            <key>branch</key>
        \\            <string>master</string>
        \\            <key>commit</key>
        \\            <string>0123456789abcdef0123456789abcdef01234567</string>
        \\        </dict>
        \\        <dict>
        \\            <key>name</key>
        \\            <string>group/app</string>
        \\            <key>upstream</key>
        \\            <string>https://example.test/app</string>
        \\        </dict>
        \\    </array>
        \\</dict>
        \\</plist>
    );
    try std.testing.expectEqual(2, pf.repos.len);
    try std.testing.expectEqualStrings("core", pf.repos[0].name);
    try std.testing.expectEqualStrings("master", pf.repos[0].branch);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", pf.repos[0].commit.?);
    try std.testing.expectEqualStrings("group/app", pf.repos[1].name);
    try std.testing.expectEqualStrings("main", pf.repos[1].branch);
    try std.testing.expectEqual(null, pf.repos[1].commit);
    try std.testing.expectEqualStrings("dotenv", pf.events_repo.?);
    try std.testing.expect(!pf.require_ci and pf.ci_issues and pf.close_issues);
    try std.testing.expectError(error.InvalidPlist, parse(arena.allocator(), "<plist><array/></plist>"));
}

test "pullfile haxy section (before the rename) still names the events repo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pf = try parse(arena.allocator(),
        \\<plist version="1.0"><dict><key>haxy</key><dict><key>events</key><string>dotenv</string></dict><key>repos</key><array/></dict></plist>
    );
    try std.testing.expectEqualStrings("dotenv", pf.events_repo.?);
}


test "pullfile cpull section switches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const pf = try parse(arena.allocator(),
        \\<plist version="1.0"><dict><key>cpull</key><dict><key>events</key><string>dotenv</string><key>require_ci</key><true/><key>ci_issues</key><false/><key>close_issues</key><string>false</string></dict><key>repos</key><array/></dict></plist>
    );
    try std.testing.expect(pf.require_ci);
    try std.testing.expect(!pf.ci_issues);
    try std.testing.expect(!pf.close_issues);
}
