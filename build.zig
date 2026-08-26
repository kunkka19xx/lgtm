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

    const tests = b.addTest(.{
        .name = "lgtm-test",
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
