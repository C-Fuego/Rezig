const std = @import("std");
const Build = std.Build;

/// assets/ is packed into db.bin and sprites.bin at build root by
/// tools/pack.zig, which the compile steps depend on. Both files are
/// gitignored and regenerated whenever their sources are newer.
pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pack = b.addExecutable(.{
        .name = "pack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });
    const run_pack = b.addRunArtifact(pack);
    run_pack.has_side_effects = true;
    run_pack.setCwd(b.path("."));

    const embed_module = b.createModule(.{ .root_source_file = b.path("embed.zig") });

    const exe = b.addExecutable(.{
        .name = "zeraora",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .version = .{ .major = 0, .minor = 3, .patch = 0 },
    });
    exe.root_module.addImport("embed", embed_module);
    exe.step.dependOn(&run_pack.step);
    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("embed", embed_module);
    const tests = b.addTest(.{ .root_module = test_module });
    tests.step.dependOn(&run_pack.step);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run zeraora");
    run_step.dependOn(&run_cmd.step);
}
