const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("tapedeck", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // Without this the library compiles at the default mode regardless of
        // -Doptimize, so releases shipped Debug library code and no test ever
        // ran in the configuration that ships.
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tapedeck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tapedeck", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tapedeck");
    run_step.dependOn(&run_cmd.step);

    // The end-to-end tests drive the shipped binary, so they need its path.
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("exe_path", exe.getEmittedBin());
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e_tests.root_module.addOptions("build_options", e2e_options);

    const failure_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/failure.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tapedeck", .module = mod }},
        }),
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
    test_step.dependOn(&b.addRunArtifact(failure_tests).step);
}
