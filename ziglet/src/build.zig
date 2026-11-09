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

    // Keep libz on the final link line as well: textfig itself may be cached
    // as a module, but font decompression is a runtime dependency of the CLI.
    mod.linkSystemLibrary("z", .{});
    mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "ziglet",
        .root_module = mod,
    });
    // Release 下去掉调试符号：体积约降 85%，性能不变
    exe.root_module.strip = optimize != .debug;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ziglet");
    run_step.dependOn(&run_cmd.step);

    // Companion tools: they share the textfig module with the main program
    // and are installed next to it.
    const tools = [_][]const u8{ "zfiglist", "zshowfigfonts", "zchkfont" };
    const test_step = b.step("test", "Run ziglet and tool unit tests");

    for (tools) |tool_name| {
        const tool_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{tool_name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "textfig", .module = textfig_dep.module("textfig") },
            },
        });
        tool_mod.linkSystemLibrary("z", .{});
        tool_mod.link_libc = true;

        const tool_exe = b.addExecutable(.{
            .name = tool_name,
            .root_module = tool_mod,
        });
        tool_exe.root_module.strip = optimize != .debug;
        b.installArtifact(tool_exe);

        const tool_tests = b.addTest(.{ .root_module = tool_mod });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }

    const unit_tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_tests.step);
}
