//! idl projects in the workspace: discovery, `idl list` targets, git state (a port
//! of the Rust idlci's projects.rs). Git state comes from the git CLI rather than xit,
//! because workspace repos may be linked worktrees, which xit rejects.
const std = @import("std");
const db = @import("db.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Project = struct {
    /// Path relative to the workspace root ("." for the root itself).
    path: []const u8,
    /// Absolute directory.
    dir: []const u8,
};

const skip = [_][]const u8{ "target", "node_modules", "build", "DerivedData", "Pods" };

/// Every directory holding an `idlproj.yml`, up to 5 levels below the root,
/// skipping dot dirs and build output; sorted by path.
pub fn discover(io: Io, a: Allocator, root: []const u8) ![]Project {
    var out: std.ArrayList(Project) = .empty;
    var root_dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return out.items;
    defer root_dir.close(io);
    try walk(io, a, root, root_dir, "", 0, &out);
    std.mem.sort(Project, out.items, {}, struct {
        fn lt(_: void, x: Project, y: Project) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.items;
}

fn walk(io: Io, a: Allocator, root: []const u8, dir: Io.Dir, rel: []const u8, depth: usize, out: *std.ArrayList(Project)) !void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => if (std.mem.eql(u8, entry.name, "idlproj.yml")) {
                try out.append(a, .{
                    .path = if (rel.len == 0) "." else try a.dupe(u8, rel),
                    .dir = if (rel.len == 0) root else try std.fs.path.join(a, &.{ root, rel }),
                });
            },
            .directory => {
                // walkdir's max_depth(5) reaches files 5 levels down, so dirs up to depth 4
                if (depth + 1 >= 5) continue;
                if (entry.name[0] == '.') continue;
                if (for (skip) |s| (if (std.mem.eql(u8, s, entry.name)) break true) else false) continue;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                const sub_rel = if (rel.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, entry.name });
                try walk(io, a, root, sub, sub_rel, depth + 1, out);
            },
            else => {},
        }
    }
}

fn lastSegment(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

pub const ResolveError = error{UnknownProject};

/// Find a project by relative path, pull repo name, or unique last path segment.
/// `repo_of` names the pull repo (relative to the root) holding a project dir.
/// On failure `msg` says which projects exist.
pub fn resolve(
    a: Allocator,
    root: []const u8,
    projects: []const Project,
    arg_in: []const u8,
    repo_of: anytype,
    msg: *[]const u8,
) !Project {
    const arg = std.mem.trimEnd(u8, arg_in, "/");
    for (projects) |p| if (std.mem.eql(u8, p.path, arg)) return p;
    // pull repo name: the project at the repo root, or the repo's only project
    var in_repo: std.ArrayList(Project) = .empty;
    for (projects) |p| if (repo_of.get(p.dir)) |r| if (std.mem.eql(u8, r, arg)) try in_repo.append(a, p);
    const at_root = try std.fs.path.join(a, &.{ root, arg });
    for (in_repo.items) |p| if (std.mem.eql(u8, p.dir, at_root)) return p;
    if (in_repo.items.len == 1) return in_repo.items[0];
    var found: ?Project = null;
    var count: usize = 0;
    for (projects) |p| if (std.mem.eql(u8, lastSegment(p.path), arg)) {
        found = p;
        count += 1;
    };
    if (count == 1) return found.?;
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("unknown project \"{s}\"; projects: ", .{arg});
    for (projects, 0..) |p, i| try w.writer.print("{s}{s}", .{ if (i > 0) ", " else "", p.path });
    msg.* = w.written();
    return error.UnknownProject;
}

pub const Target = struct {
    name: []const u8,
    kind: []const u8,
    builder: []const u8,
    bundle_id: ?[]const u8,
    platform: []const u8,
    dir: []const u8,
};

const kinds = [_][]const u8{ "app", "framework", "dylib", "appex", "static", "test" };

/// Parse `idl list`: `NAME KIND BUILDER [BUNDLE_ID] PLATFORM VERSION DIR` per line.
pub fn parseList(a: Allocator, text: []const u8) ![]Target {
    var out: std.ArrayList(Target) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var tokens: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        while (it.next()) |t| try tokens.append(a, t);
        const t = tokens.items;
        const n = t.len;
        if (n < 6) continue;
        if (for (kinds) |k| (if (std.mem.eql(u8, k, t[1])) break false) else true) continue;
        try out.append(a, .{
            .name = t[0],
            .kind = t[1],
            .builder = t[2],
            .bundle_id = if (n > 6) try std.mem.join(a, " ", t[3 .. n - 3]) else null,
            .platform = try std.fmt.allocPrint(a, "{s} {s}", .{ t[n - 3], t[n - 2] }),
            .dir = t[n - 1],
        });
    }
    return out.items;
}

/// Run a command to completion; null when it can't start or fails.
pub fn output(io: Io, a: Allocator, argv: []const []const u8, cwd: ?[]const u8) ?[]const u8 {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch return null;
    if (!r.term.success()) return null;
    return r.stdout;
}

pub const ListError = error{IdlListFailed};

/// `idl list` in a project's dir; on failure `msg` holds idl's stderr.
pub fn targets(io: Io, a: Allocator, idl: []const u8, dir: []const u8, msg: *[]const u8) ![]Target {
    const r = std.process.run(a, io, .{
        .argv = &.{ idl, "list" },
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "running {s} list: {t}", .{ idl, e });
        return error.IdlListFailed;
    };
    if (!r.term.success()) {
        msg.* = try std.fmt.allocPrint(a, "idl list failed: {s}", .{std.mem.trim(u8, r.stderr, " \t\r\n")});
        return error.IdlListFailed;
    }
    return parseList(a, r.stdout);
}

/// The `idl` binary: $IDLCI_IDL (or cpull's $CPULL_IDL), else `idl` on PATH, else ~/.local/bin/idl.
pub fn idlPath(io: Io, a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("IDLCI_IDL") orelse env.get("CPULL_IDL")) |p| return a.dupe(u8, p);
    if (env.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |d| {
            const p = try std.fs.path.join(a, &.{ d, "idl" });
            const st = Io.Dir.cwd().statFile(io, p, .{}) catch continue;
            if (st.kind == .file) return p;
        }
    }
    if (env.get("HOME")) |home| {
        const p = try std.fs.path.join(a, &.{ home, ".local/bin/idl" });
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch null;
        if (st != null and st.?.kind == .file) return p;
    }
    return "idl";
}

/// The repo holding `dir`, relative to the root (null outside the root or at it).
pub fn repoName(io: Io, a: Allocator, root: []const u8, dir: []const u8) ?[]const u8 {
    const out = output(io, a, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" }, null) orelse return null;
    const top = std.mem.trimEnd(u8, out, "\n");
    if (!std.mem.startsWith(u8, top, root)) return null;
    const rel = std.mem.trim(u8, top[root.len..], "/");
    return if (rel.len == 0) null else rel;
}

/// Branch, short HEAD and dirty flag (untracked files count, submodules don't),
/// like idlci's libgit2 git_info. `repo` is filled in by the caller.
pub fn gitInfo(io: Io, a: Allocator, dir: []const u8) db.GitInfo {
    const out = output(io, a, &.{ "git", "-C", dir, "status", "--porcelain=v2", "--branch", "--untracked-files=normal", "--ignore-submodules=all" }, null) orelse return .{};
    var info: db.GitInfo = .{};
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "# branch.oid ")) {
            const oid = line["# branch.oid ".len..];
            if (!std.mem.eql(u8, oid, "(initial)")) info.head = oid[0..@min(7, oid.len)];
        } else if (std.mem.startsWith(u8, line, "# branch.head ")) {
            const head = line["# branch.head ".len..];
            // libgit2's shorthand of a detached HEAD is "HEAD"
            info.branch = if (std.mem.eql(u8, head, "(detached)")) "HEAD" else head;
        } else if (line[0] != '#') info.dirty = true;
    }
    return info;
}

/// The work tree and HEAD commit of the repo holding `dir` (for the watcher).
pub fn headOid(io: Io, a: Allocator, dir: []const u8) ?[]const u8 {
    const out = output(io, a, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel", "HEAD" }, null) orelse return null;
    return std.mem.trimEnd(u8, out, "\n");
}

test "parses idl list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\FossifyCalculator        app       direct  org.fossify.math.ios                 iOS 17.0   .
        \\CalculatorKit            static    direct                                       iOS 17.0   .
        \\FossifyCommons           static    direct                                       iOS 17.0   ../commons-ios
        \\warning: something
        \\
    ;
    const t = try parseList(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), t.len);
    try std.testing.expectEqualStrings("org.fossify.math.ios", t[0].bundle_id.?);
    try std.testing.expect(t[1].bundle_id == null);
    try std.testing.expectEqualStrings("iOS 17.0", t[1].platform);
    try std.testing.expectEqualStrings("../commons-ios", t[2].dir);
}

test "discovers and resolves" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "group/a-ios", "b", "b/target/x", ".hidden/c" }) |d| {
        try tmp.dir.createDirPath(io, d);
        const f = try tmp.dir.createFile(io, try std.fmt.allocPrint(a, "{s}/idlproj.yml", .{d}), .{});
        f.close(io);
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = try discover(io, a, root);
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("b", p[0].path);
    try std.testing.expectEqualStrings("group/a-ios", p[1].path);
    const NoRepos = struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var msg: []const u8 = "";
    try std.testing.expectEqualStrings("group/a-ios", (try resolve(a, root, p, "a-ios", NoRepos{}, &msg)).path);
    try std.testing.expectEqualStrings("group/a-ios", (try resolve(a, root, p, "group/a-ios/", NoRepos{}, &msg)).path);
    try std.testing.expectError(error.UnknownProject, resolve(a, root, p, "nope", NoRepos{}, &msg));
    try std.testing.expect(std.mem.indexOf(u8, msg, "projects: b, group/a-ios") != null);
}
