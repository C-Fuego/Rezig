//! zlolcat - rainbow colouring for the console, lolcat style.

const std = @import("std");
const cli = @import("cli.zig");
const color = @import("color.zig");
const render = @import("render.zig");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // The reader went away, e.g. `ls | zlolcat | head -2`: exit quietly the
        // way `cat` does instead of dumping a raw error trace.
        error.WriteFailed => std.process.exit(1),
        // already reported to stderr, just set the exit status
        error.FileError => std.process.exit(1),
        else => {
            std.debug.print("zlolcat: {t}\n", .{err});
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [64 * 1024]u8 = undefined;
    var out_file_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_file_writer.interface;

    var err_buffer: [8 * 1024]u8 = undefined;
    var err_file_writer = std.Io.File.stderr().writer(io, &err_buffer);
    const errw = &err_file_writer.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const opts = cli.parse(arena, argv, errw) catch |err| switch (err) {
        error.InvalidArgs => {
            try errw.writeAll("Try 'zlolcat --help' for more information.\n");
            try errw.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    // Seed 0 means "pick one for me": `rand(256)` in cat.rb.
    var seed = opts.seed;
    if (seed == 0.0) {
        var raw: [2]u8 = undefined;
        io.random(&raw);
        seed = @floatFromInt(std.mem.readInt(u16, &raw, .little) % 256);
    }

    const mode = color.detectMode(init.environ_map.get("COLORTERM"), opts.truecolor, opts.force_256);
    const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;

    // cat.rb: `if $stdout.tty? or opts[:force]` - otherwise lolcat is `cat`.
    const colorize = !opts.no_color and (stdout_is_tty or opts.force_color);

    if (opts.help) {
        // Optimist's HelpNeeded rescue renders the help with its own rainbow:
        // spread 8.0, freq 0.3, a random start, and then one extra newline.
        var raw: [8]u8 = undefined;
        io.random(&raw);
        const fraction = @as(f64, @floatFromInt(std.mem.readInt(u64, &raw, .little))) / 18446744073709551616.0;
        var help_opts = opts;
        help_opts.spread = 8.0;
        help_opts.frequency = 0.3;
        help_opts.animate = false;
        var help_renderer = render.Renderer.init(out, io, arena, help_opts, mode, fraction * 8192.0, true, stdout_is_tty);
        defer help_renderer.deinit();
        try help_renderer.start();
        try help_renderer.feed(cli.help_text);
        try help_renderer.finish();
        help_renderer.endCat();
        try out.writeByte('\n');
        try out.flush();
        return;
    }
    if (opts.version) {
        try out.print("{s}\n", .{cli.version_text});
        try out.flush();
        return;
    }

    var r = render.Renderer.init(out, io, arena, opts, mode, seed, colorize, stdout_is_tty);
    defer r.deinit();

    if (opts.files.len == 0) {
        try r.runFile(std.Io.File.stdin());
    } else {
        for (opts.files) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try r.runFile(std.Io.File.stdin());
                continue;
            }
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                const msg: []const u8 = switch (err) {
                    error.FileNotFound => "No such file or directory",
                    error.AccessDenied => "Permission denied",
                    error.PermissionDenied => "Permission denied",
                    error.IsDir => "Is a directory",
                    else => @errorName(err),
                };
                try out.print("zlolcat: {s}: {s}\n", .{ path, msg });
                try out.flush();
                return error.FileError;
            };
            defer file.close(io);
            // opening a directory works; reading it is what fails
            if (file.stat(io)) |st| {
                if (st.kind == .directory) {
                    try out.print("zlolcat: {s}: Is a directory\n", .{path});
                    try out.flush();
                    return error.FileError;
                }
            } else |_| {}
            try r.runFile(file);
        }
    }

    try out.flush();
}

test {
    _ = cli;
    _ = color;
    _ = render;
}
