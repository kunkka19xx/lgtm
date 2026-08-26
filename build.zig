// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const profile = b.option(bool, "profile", "Enable timing spans and the --profile report") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "profile", profile);

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    }).module("vaxis");

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addOptions("build_options", build_options);
    root.addImport("vaxis", vaxis);

    const exe = b.addExecutable(.{
        .name = "lgtm",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run lgtm").dependOn(&run.step);

    // Tests import src/main.zig, which pulls in every module via its test block.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", build_options);
    test_module.addImport("vaxis", vaxis);

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .name = "lgtm-test",
        .root_module = test_module,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // Anchor harness: the phase 1 go/no-go gate. Exits non-zero below the
    // required hit rate, so it can gate CI.
    const anchor_mod = b.createModule(.{
        .root_source_file = b.path("src/core/anchor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_mod = b.createModule(.{
        .root_source_file = b.path("src/io/fs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("src/harness/anchor_harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_mod.addImport("anchor", anchor_mod);
    harness_mod.addImport("fs", fs_mod);

    const harness = b.addExecutable(.{
        .name = "anchor-harness",
        .root_module = harness_mod,
    });
    const run_harness = b.addRunArtifact(harness);
    run_harness.setCwd(b.path("."));
    if (b.args) |a| run_harness.addArgs(a);
    b.step("anchor", "Run the anchor re-anchoring harness").dependOn(&run_harness.step);

    // Licence header check. Runs as its own step and as part of `zig build check`.
    const spdx = b.addExecutable(.{
        .name = "check-spdx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_spdx.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // Resolved paths, not relative ones: the check must behave the same whether
    // `zig build` is invoked from the repo root or a subdirectory.
    const run_spdx = b.addRunArtifact(spdx);
    run_spdx.addDirectoryArg(b.path("src"));
    run_spdx.addDirectoryArg(b.path("tools"));
    run_spdx.addFileArg(b.path("build.zig"));
    const spdx_step = b.step("spdx", "Check SPDX headers");
    spdx_step.dependOn(&run_spdx.step);

    const check = b.step("check", "Run tests and the SPDX header check");
    check.dependOn(&run_tests.step);
    check.dependOn(&run_spdx.step);
}
