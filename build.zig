//! idlci: local CI for the idl projects of a pull workspace (one Zig program:
//! `idlci serve|mcp|queue|jobs|log|cancel|retry|patch|stack|cleanup`).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};

    // SQLite's C library is always built optimized, so debug builds don't run a debug SQLite
    const sqlite_mod = b.dependency("sqlite", .{ .target = target, .optimize = .ReleaseFast }).module("sqlite");
    const xml_mod = b.dependency("xml", .{}).module("xml");
    const parley_mod = b.dependency("parley", .{ .target = target, .optimize = optimize }).module("parley");
    const theme_dep = b.dependency("theme", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("sqlite", sqlite_mod);
    mod.addImport("xml", xml_mod);
    mod.addImport("parley", parley_mod);
    mod.addImport("theme", theme_dep.module("theme"));
    mod.addImport("discovery", theme_dep.module("discovery"));

    const exe = b.addExecutable(.{ .name = "idlci", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run idlci").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the tests").dependOn(&run_tests.step);
}
