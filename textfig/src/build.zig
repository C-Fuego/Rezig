const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The whole library is one public module: font (parsing + search),
    // render (smushing + wrapping) and control (.flc/.tlc programs).
    const mod = b.addModule("textfig", .{
        .root_source_file = b.path("src/textfig.zig"),
        .target = target,
        .optimize = optimize,
    });
    // gzip/zip font containers use the system zlib (declared manually in
    // src/compressed.zig).
    mod.linkSystemLibrary("z", .{});
    // libz allocates through libc (malloc/tcache); without libc the dynamic
    // zlib can crash on first allocation in a non-libc Zig executable.
    mod.link_libc = true;

    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run textfig unit tests");
    test_step.dependOn(&run_tests.step);
}
