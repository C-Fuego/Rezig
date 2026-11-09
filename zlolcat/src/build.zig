const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module holds the whole program; the executable and the test runner
    // share it, so `zig build test` picks up the tests in every file.
    const zlolcat_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zlolcat",
        .root_module = zlolcat_mod,
    });
    // Release 下去掉调试符号：体积约降 85%，性能不变
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zlolcat");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = zlolcat_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
