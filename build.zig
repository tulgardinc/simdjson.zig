const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/json_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests in all modes.");
    const tests = b.addTest(.{ .root_module = lib_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
