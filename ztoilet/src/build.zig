const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const textfig_dep = b.dependency("textfig", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "textfig", .module = textfig_dep.module("textfig") },
        },
    });

    // Keep libz on the final link line as well.
    mod.linkSystemLibrary("z", .{});
    mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "ztoilet",
        .root_module = mod,
    });
    // Release 下去掉调试符号：体积约降 85%，性能不变
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ztoilet");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run ztoilet unit tests");
    test_step.dependOn(&run_tests.step);
}
