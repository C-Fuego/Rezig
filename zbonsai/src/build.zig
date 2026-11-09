//! build.zig -- Zig 0.17 build script for zbonsai.
//!
//! Notes on 0.17 specifics:
//!   * `Build` has no `b.args` field any more; extra CLI arguments are passed
//!     through with `Run.addPassthruArgs()`.
//!   * Executables/tests are declared with an explicit root module created by
//!     `b.createModule` (`root_module = ...` instead of `root_source_file`).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One module shared by the executable and the unit-test binary.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Pure Zig: no libc, no third-party packages.
        .link_libc = false,
    });

    const exe = b.addExecutable(.{
        .name = "zbonsai",
        .root_module = mod,
    });
    // Release 下去掉调试符号：体积约降 85%，性能不变
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    // `zig build run -- -p -s 42`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zbonsai");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
