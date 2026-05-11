const std = @import("std");

pub fn build(b: *std.Build) void {
    const filter = b.option([]const u8, "filter", "Filter tests");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zcasp", .{
        .root_source_file = b.path("zcasp.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("regent", b.dependency("regent", .{
        .target = target,
        .optimize = optimize,
    }).module("regent"));

    const unit_tests = b.addTest(.{
        .root_module = module,
        .use_llvm = true,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    if (filter) |f| {
        const filter_slice = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
        unit_tests.filters = filter_slice;
    }

    const install_test = b.addInstallArtifact(unit_tests, .{
        .dest_sub_path = "debug-unit-tests",
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&install_test.step);

    const test_run_step = b.step("test-run", "Run unit tests");
    test_run_step.dependOn(&run_unit_tests.step);
}
