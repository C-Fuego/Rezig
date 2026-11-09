const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.17: 用 createModule + root_module，不再有 root_source_file 字段
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Release 下不带调试符号：4.1 MB -> 0.5 MB，运行性能不变
        .strip = optimize != .debug,
    });

    const exe = b.addExecutable(.{
        .name = "zmatrix",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // 0.17 的 Build 没有 b.args，运行参数请直接跑 zig-out/bin/zmatrix
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zmatrix");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
