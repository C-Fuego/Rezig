const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.17: createModule + root_module，没有 root_source_file 字段，也没有 linkLibC。
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zclock",
        .root_module = exe_mod,
    });
    // Release 下去掉调试符号：体积约降 85%，性能不变
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // 0.17 的 Build 没有 b.args，用 addPassthruArgs 让 `zig build run -- -s` 生效。
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zclock");
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
