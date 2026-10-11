const std = @import("std");

pub fn build(b: *std.Build) void {
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

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Filter tests by string match",
    ) orelse &.{};

    const unit_tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
        .use_llvm = true,
    });
    b.installArtifact(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    b.getInstallStep().dependOn(&run_unit_tests.step);
}
