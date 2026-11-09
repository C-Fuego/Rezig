//! ztoilet: TOIlet semantics (coloured glyphs, filters, export formats) on
//! top of the textfig renderer.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;
const render = textfig.render;
const cli = @import("cli.zig");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const filter = @import("filter.zig");
const exp = @import("export.zig");
const color = @import("color.zig");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(1),
        error.Reported => std.process.exit(1),
        else => {
            std.debug.print("ztoilet: {t}\n", .{err});
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    var err_buf: [16 * 1024]u8 = undefined;
    var err_file = Io.File.stderr().writer(io, &err_buf);
    const errw = &err_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const opts = cli.parse(arena, argv, errw) catch |err| switch (err) {
        error.InvalidArgs => {
            try errw.writeAll("Try 'ztoilet --help' for more information.\n");
            try errw.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    const width = resolveWidth(opts, io, init.environ_map);
    const dirs = try font.searchDirs(arena, .{
        .explicit_dir = opts.font_dir,
        .env_fontdir = init.environ_map.get("FIGLET_FONTDIR"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .home = init.environ_map.get("HOME"),
    });

    if (opts.help) {
        try out.writeAll(cli.help_text);
        try out.flush();
        return;
    }
    if (opts.version) {
        try out.writeAll(cli.version_text);
        try out.flush();
        return;
    }
    if (opts.list_filters) {
        try out.writeAll(filter.listText());
        try out.flush();
        return;
    }
    if (opts.list_exports) {
        try out.writeAll(exportListText());
        try out.flush();
        return;
    }
    if (opts.infocode) |code| {
        if (code >= 0) {
            try printInfo(code, opts, width, dirs, out);
            try out.flush();
            return;
        }
    }

    var diag: font.Diag = .{};
    var f = font.load(io, gpa, dirs, opts.font, &diag) catch |err| switch (err) {
        error.FontNotFound => blk: {
            if (opts.font_explicit) {
                try report(errw, diag.text());
                return error.Reported;
            }
            try errw.print("ztoilet: {s}\n", .{diag.text()});
            try errw.writeAll("ztoilet: falling back to the built-in 'term' font\n");
            try errw.flush();
            break :blk font.Font.builtinTerm(gpa) catch return error.OutOfMemory;
        },
        else => {
            try report(errw, diag.text());
            return error.Reported;
        },
    };
    defer f.deinit();

    // TOIlet's -s default, following libcaca's update_figfont_settings().
    const default_smush = toiletDefaultSmush(&f);
    var smush_mode = default_smush;
    for (opts.layout_ops.items) |op| smush_mode = render.applyLayoutOp(smush_mode, default_smush, op);

    const color_mode: exp.ColorMode = blk: {
        if (opts.truecolor) break :blk .truecolor;
        if (opts.force256) break :blk .ansi256;
        break :blk switch (opts.solid) {
            .rgb => .truecolor,
            else => .ansi256,
        };
    };

    var exporter = exp.Exporter{
        .out = out,
        .format = opts.export_format,
        .color_mode = color_mode,
        .colors_enabled = !opts.no_color,
    };

    var painter = Painter{
        .a = gpa,
        .exporter = &exporter,
        .filters = opts.filters.items,
        .solid = opts.solid.asRgb(),
        .hardblank = f.hardblank,
    };

    var r = try render.Renderer.init(gpa, &f, painter.sink(), smush_mode, width, .ltr);
    defer r.deinit();

    var text: std.ArrayList(u8) = .empty;
    if (opts.files.items.len != 0) {
        for (opts.files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try appendStdin(io, arena, &text);
            } else {
                const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| {
                    try errw.print("ztoilet: {s}: {t}\n", .{ path, err });
                    try errw.flush();
                    return error.Reported;
                };
                try text.appendSlice(arena, bytes);
            }
        }
    } else if (opts.operands.items.len != 0) {
        for (opts.operands.items, 0..) |word, idx| {
            if (idx != 0) try text.append(arena, ' ');
            try text.appendSlice(arena, word);
        }
    } else {
        try appendStdin(io, arena, &text);
    }

    const cps = try decodeUtf8(arena, text.items);
    for (cps) |c| try r.feed(c);
    try r.finish();
    try exporter.finish();
}

fn toiletDefaultSmush(f: *const font.Font) u32 {
    const fl = f.full_layout orelse 0;
    if (f.old_layout == -1) return 0; // full width
    if (f.old_layout == 0 and (fl & 0xc0) == 0x40) return font.SM_KERN;
    if ((f.old_layout & 0x3f) != 0 and (fl & 0x3f) != 0 and (fl & 0x80) != 0) {
        return (fl & 0x3f) | font.SM_SMUSH;
    }
    if (f.old_layout == 0 and (fl & 0xbf) == 0x80) return font.SM_SMUSH; // universal
    // Anything else (notably a font whose only information is full width but
    // which is not old_layout -1) falls back to TOIlet's overlapping mode.
    return font.SM_SMUSH;
}

fn report(errw: *Io.Writer, msg: []const u8) !void {
    try errw.print("ztoilet: {s}\n", .{msg});
    try errw.flush();
}

fn exportListText() []const u8 {
    return "Available export formats:\n" ++
        "\"utf8\": UTF-8 text with ANSI colour escapes\n" ++
        "\"ansi\": ANSI 16-colour text\n" ++
        "\"irc\": mIRC colour codes\n" ++
        "\"html\": a UTF-8 HTML document with colour spans\n";
}

fn printInfo(code: i32, opts: cli.Options, width: usize, dirs: []const []const u8, out: *Io.Writer) !void {
    switch (code) {
        0 => {
            try out.writeAll(cli.version_text);
        },
        1 => try out.writeAll("20201\n"),
        2 => try out.print("{s}\n", .{font.primaryDir(dirs)}),
        3 => {
            var n = opts.font;
            if (std.mem.endsWith(u8, n, ".flf") or std.mem.endsWith(u8, n, ".tlf")) n = n[0 .. n.len - 4];
            try out.print("{s}\n", .{n});
        },
        4 => try out.print("{d}\n", .{width}),
        5 => try out.writeAll("flf2 tlf2\n"),
        else => {},
    }
}

fn appendStdin(io: Io, a: std.mem.Allocator, text: *std.ArrayList(u8)) !void {
    var buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    const bytes = reader.interface.allocRemaining(a, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.StreamTooLong,
        error.ReadFailed => return reader.err.?,
    };
    try text.appendSlice(a, bytes);
}

fn resolveWidth(opts: cli.Options, io: Io, environ: *std.process.Environ.Map) usize {
    var w: usize = opts.width_value orelse 80;
    if (opts.use_term_width) {
        if (termWidth(io)) |tw| {
            w = tw;
        } else if (envColumns(environ)) |ew| {
            w = ew;
        }
    }
    if (w == 0) w = 80;
    return w;
}

fn envColumns(environ: *std.process.Environ.Map) ?usize {
    const raw = environ.get("COLUMNS") orelse return null;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t"), 10) catch return null;
    if (n == 0) return null;
    return n;
}

fn termWidth(io: Io) ?usize {
    _ = io;
    const files = [_]Io.File{ Io.File.stdout(), Io.File.stderr(), Io.File.stdin() };
    for (files) |file| {
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(file.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(rc)) >= 0 and ws.col != 0) return ws.col;
    }
    return null;
}

/// UTF-8 decode with U+FFFD replacement and CRLF normalisation (same helper as
/// zfiglet's CLI; the textfig renderer deliberately stays I/O agnostic).
fn decodeUtf8(a: std.mem.Allocator, bytes: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    try out.ensureTotalCapacity(a, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            i += 1;
            continue;
        }
        if (b < 0x80) {
            out.appendAssumeCapacity(b);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        };
        if (i + n > bytes.len) {
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch {
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        };
        out.appendAssumeCapacity(cp);
        i += n;
    }
    return out.toOwnedSlice(a);
}

/// Turns a rendered FIGlet line into a canvas, runs the filter chain, then
/// hands the result to the exporter.
const Painter = struct {
    a: std.mem.Allocator,
    exporter: *exp.Exporter,
    filters: []const filter.Kind,
    solid: ?color.Rgb,
    hardblank: u21,
    phase: usize = 0,

    fn sink(self: *Painter) render.Sink {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, line: *const render.RenderedLine) anyerror!void {
        const self: *Painter = @ptrCast(@alignCast(ptr));
        var cv = try Canvas.fromLine(self.a, line, self.hardblank);
        defer cv.deinit();
        if (self.solid) |c| cv.fillColor(c);
        for (self.filters) |kind| try filter.apply(kind, &cv, self.phase);
        try self.exporter.emit(&cv);
        self.phase += cv.height;
    }
};

test {
    _ = cli;
    _ = canvas_mod;
    _ = filter;
    _ = exp;
    _ = color;
}

test "end-to-end: tiny font renders through canvas and exporter" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(std.testing.allocator, textfig.fixtures.tiny_flf, "tiny", &diag);
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var exporter = exp.Exporter{ .out = &w, .format = .utf8, .color_mode = .ansi256 };
    var painter = Painter{
        .a = std.testing.allocator,
        .exporter = &exporter,
        .filters = &.{},
        .solid = null,
        .hardblank = f.hardblank,
    };
    var r = try render.Renderer.init(std.testing.allocator, &f, painter.sink(), 0, 80, .ltr);
    defer r.deinit();
    for ("Hi") |ch| try r.feed(ch);
    try r.finish();
    try exporter.finish();

    try std.testing.expectEqualStrings(
        "      \n" ++
            " H  i \n" ++
            "      \n",
        buf[0..w.end],
    );
}
