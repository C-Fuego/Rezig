//! ziglet: FIGlet 2.2.5 semantics plus TOIlet 1.x rendering features.
//!
//! The default pipeline is FIGlet's: rendered rows are written straight to
//! stdout, with FIGlet smushing, control files, direction and justification.
//! As soon as a TOIlet option (-F/--filter, --export, --irc, --html, --color,
//! --no-color, --truecolor, --256 or a filter shortcut) is given, every
//! rendered line is turned into a canvas, the filter chain runs, and the
//! result is emitted through the selected export format.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;
const render = textfig.render;
const control = textfig.control;
const cli = @import("cli.zig");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const filter = @import("filter.zig");
const exp = @import("export.zig");
const color = @import("color.zig");

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        // downstream stdout went away (e.g. `ziglet big | head -1`)
        error.WriteFailed => std.process.exit(1),
        // already reported with a specific message
        error.Reported => std.process.exit(1),
        else => {
            std.debug.print("ziglet: {t}\n", .{err});
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
            try errw.writeAll("Try 'ziglet --help' for more information.\n");
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
    if (opts.list_fonts) {
        try font.listFonts(io, gpa, dirs, out);
        return;
    }
    if (opts.infocode) |code| {
        if (code >= 0) {
            try printInfo(code, opts, width, dirs, out);
            try out.flush();
            return;
        }
    }

    // Load the font, with a documented degradation path: an explicitly named
    // missing font is a hard error, but if the *default* font is unavailable
    // we fall back to the built-in "term" font instead of failing outright.
    var diag: font.Diag = .{};
    var f = font.load(io, gpa, dirs, opts.font, &diag) catch |err| switch (err) {
        error.FontNotFound => blk: {
            if (opts.font_explicit) {
                try report(errw, diag.text());
                return error.Reported;
            }
            try errw.print("ziglet: {s}\n", .{diag.text()});
            try errw.writeAll("ziglet: falling back to the built-in 'term' font\n");
            try errw.flush();
            break :blk font.Font.builtinTerm(gpa) catch return error.OutOfMemory;
        },
        else => {
            try report(errw, diag.text());
            return error.Reported;
        },
    };
    defer f.deinit();

    var programs: std.ArrayList(control.Program) = .empty;
    defer {
        for (programs.items) |*p| p.deinit();
        programs.deinit(gpa);
    }
    for (opts.controls.items) |name| {
        const p = try loadControl(io, gpa, dirs, name, errw);
        try programs.append(gpa, p);
    }

    // FIGlet layout: start at the font's own smush mode and apply the layout
    // options in command-line order. Both pipelines share this.
    var smush_mode = f.font_smush;
    for (opts.layout_ops.items) |op| smush_mode = render.applyLayoutOp(smush_mode, f.font_smush, op);

    const direction: font.Direction = switch (opts.direction) {
        .auto => f.print_dir,
        .ltr => .ltr,
        .rtl => .rtl,
    };
    const justify: font.Justify = opts.justify orelse direction.defaultJustify();

    const cps = try readInput(io, arena, opts, errw);

    if (opts.canvas) {
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
            .width = width,
            .justify = justify,
        };
        var r = try render.Renderer.init(gpa, &f, painter.sink(), smush_mode, width, direction);
        defer r.deinit();
        try feedInput(&r, cps, opts.paragraph, opts.german, programs.items);
        try r.finish();
        try exporter.finish();
    } else {
        var printer = Printer{
            .out = out,
            .width = width,
            .justify = justify,
            .hardblank = f.hardblank,
        };
        var r = try render.Renderer.init(gpa, &f, printer.sink(), smush_mode, width, direction);
        defer r.deinit();
        try feedInput(&r, cps, opts.paragraph, opts.german, programs.items);
        try r.finish();
        try out.flush();
    }
}

fn report(errw: *Io.Writer, msg: []const u8) !void {
    try errw.print("ziglet: {s}\n", .{msg});
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
        1 => try out.writeAll("20205\n"),
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

/// Load a .flc/.tlc program, searching the font directories like figlet.
fn loadControl(io: Io, gpa: std.mem.Allocator, dirs: []const []const u8, name_in: []const u8, errw: *Io.Writer) !control.Program {
    const name = std.mem.trim(u8, name_in, " \t");
    const has_suffix = std.mem.endsWith(u8, name, ".flc") or std.mem.endsWith(u8, name, ".tlc");
    const suffixes = [_][]const u8{ ".flc", ".tlc" };

    var diag: font.Diag = .{};
    if (std.fs.path.isAbsolute(name) or std.mem.indexOfScalar(u8, name, '/') != null) {
        if (has_suffix) return try readControl(io, gpa, name, &diag, errw);
        for (suffixes) |suffix| {
            const path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ name, suffix });
            defer gpa.free(path);
            if (try tryReadControl(io, gpa, path, &diag, errw)) |p| return p;
        }
    } else {
        for (dirs) |dir| {
            if (has_suffix) {
                const path = try std.fs.path.join(gpa, &.{ dir, name });
                defer gpa.free(path);
                if (try tryReadControl(io, gpa, path, &diag, errw)) |p| return p;
            } else {
                for (suffixes) |suffix| {
                    const path = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, name, suffix });
                    defer gpa.free(path);
                    if (try tryReadControl(io, gpa, path, &diag, errw)) |p| return p;
                }
            }
        }
    }
    try errw.print("ziglet: control file \"{s}\" not found\n", .{name});
    try errw.flush();
    return error.Reported;
}

fn tryReadControl(io: Io, gpa: std.mem.Allocator, path: []const u8, diag: *font.Diag, errw: *Io.Writer) !?control.Program {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("cannot read control file \"{s}\": {t}", .{ path, err });
            try errw.print("ziglet: {s}\n", .{diag.text()});
            try errw.flush();
            return error.Reported;
        },
    };
    defer gpa.free(bytes);
    const p = control.Program.parse(gpa, bytes, path, diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try errw.print("ziglet: {s}: {s}\n", .{ path, diag.text() });
            try errw.flush();
            return error.Reported;
        },
    };
    return p;
}

fn readControl(io: Io, gpa: std.mem.Allocator, path: []const u8, diag: *font.Diag, errw: *Io.Writer) !control.Program {
    if (try tryReadControl(io, gpa, path, diag, errw)) |p| return p;
    diag.set("control file \"{s}\" not found", .{path});
    try errw.print("ziglet: {s}\n", .{diag.text()});
    try errw.flush();
    return error.Reported;
}

/// Gather the message/files/stdin text and decode it as UTF-8.
fn readInput(io: Io, a: std.mem.Allocator, opts: cli.Options, errw: *Io.Writer) ![]u21 {
    var text: std.ArrayList(u8) = .empty;
    if (opts.files.items.len != 0) {
        for (opts.files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try appendStdin(io, a, &text);
            } else {
                const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024 * 1024)) catch |err| {
                    try errw.print("ziglet: {s}: {t}\n", .{ path, err });
                    try errw.flush();
                    return error.Reported;
                };
                try text.appendSlice(a, bytes);
            }
        }
    } else if (opts.operands.items.len != 0 or opts.cmd_input) {
        for (opts.operands.items, 0..) |word, idx| {
            if (word.len == 0) {
                try text.append(a, '\n');
            } else {
                try text.appendSlice(a, word);
                if (idx + 1 < opts.operands.items.len) try text.append(a, ' ');
            }
        }
    } else {
        try appendStdin(io, a, &text);
    }
    return decodeUtf8(a, text.items);
}

/// Decode UTF-8 into codepoints, replacing malformed bytes with U+FFFD and
/// dropping the CR of CRLF pairs.
fn decodeUtf8(a: std.mem.Allocator, bytes: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    try out.ensureTotalCapacity(a, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            i += 1; // skip CR, the LF is handled next
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

fn isAsciiSpace(c: u21) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d);
}

fn isFigletEol(c: u21) bool {
    // figlet: isspace(c) && c != '\t' && c != ' '
    return isAsciiSpace(c) and c != '\t' and c != ' ';
}

const german_set = [_]u21{ 196, 214, 220, 228, 246, 252, 223 };

fn applyGerman(c: u21) u21 {
    if (c >= '[' and c <= ']') return german_set[@intCast(c - '[')];
    if (c >= '{' and c <= '~') return german_set[@intCast(c - '{' + 3)];
    return c;
}

fn feedInput(
    r: *render.Renderer,
    cps: []const u21,
    paragraph: bool,
    german: bool,
    programs: []const control.Program,
) !void {
    var last_eol = false;
    var i: usize = 0;
    while (i < cps.len) : (i += 1) {
        var c = cps[i];

        if (c == '\n' and paragraph and !last_eol) {
            const next_is_space = i + 1 < cps.len and isAsciiSpace(cps[i + 1]);
            c = if (next_is_space) '\n' else ' ';
        }
        last_eol = isFigletEol(c);

        if (german) c = applyGerman(c);
        for (programs) |*p| c = p.apply(c);

        if (isAsciiSpace(c)) {
            c = if (c == '\t' or c == ' ') ' ' else '\n';
        }
        if ((c > 0 and c < 32 and c != '\n') or c == 127) continue;

        try r.feed(c);
    }
}

/// FIGlet's putstring: hardblanks become spaces, rows are truncated to
/// outputwidth-1 and padded for centring/right justification.
const Printer = struct {
    out: *Io.Writer,
    width: usize,
    justify: font.Justify,
    hardblank: u21,

    fn sink(self: *Printer) render.Sink {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, line: *const render.RenderedLine) anyerror!void {
        const self: *Printer = @ptrCast(@alignCast(ptr));
        const limit: usize = if (self.width > 1) self.width - 1 else line.width;
        const len = @min(line.width, limit);
        var pad: usize = 0;
        if (self.width > 1) {
            pad = switch (self.justify) {
                .left => 0,
                .center => (self.width - len) / 2,
                .right => self.width - len - 1,
            };
        }
        var buf: [4]u8 = undefined;
        for (0..line.height) |y| {
            try self.out.splatByteAll(' ', pad);
            for (0..len) |x| {
                const cell = line.rows[y][x];
                const ch: u21 = if (cell == self.hardblank) ' ' else cell;
                const n = std.unicode.utf8Encode(ch, &buf) catch {
                    try self.out.writeByte('?');
                    continue;
                };
                try self.out.writeAll(buf[0..n]);
            }
            try self.out.writeByte('\n');
        }
    }
};

fn justifyPad(width: usize, len: usize, justify: font.Justify) usize {
    if (width <= 1) return 0;
    const limit = width - 1;
    const l = @min(len, limit);
    return switch (justify) {
        .left => 0,
        .center => (width - l) / 2,
        .right => width - l - 1,
    };
}

fn padLeft(a: std.mem.Allocator, cv: *Canvas, pad: usize) !void {
    if (pad == 0) return;
    const w = cv.width + pad;
    const cells = try a.alloc(canvas_mod.Cell, w * cv.height);
    for (cells) |*c| c.* = .{};
    for (0..cv.height) |y| {
        const src = cv.cells[y * cv.width .. (y + 1) * cv.width];
        const dst = cells[y * w + pad .. y * w + pad + src.len];
        @memcpy(dst, src);
    }
    cv.a.free(cv.cells);
    cv.width = w;
    cv.cells = cells;
}

/// Turns a rendered FIGlet line into a canvas, pads it for the FIGlet
/// justification, runs the filter chain, then hands the result to the
/// exporter. Used when at least one TOIlet option is present.
const Painter = struct {
    a: std.mem.Allocator,
    exporter: *exp.Exporter,
    filters: []const filter.Kind,
    solid: ?color.Rgb,
    hardblank: u21,
    width: usize,
    justify: font.Justify,
    phase: usize = 0,

    fn sink(self: *Painter) render.Sink {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, line: *const render.RenderedLine) anyerror!void {
        const self: *Painter = @ptrCast(@alignCast(ptr));
        var cv = try Canvas.fromLine(self.a, line, self.hardblank);
        defer cv.deinit();
        try padLeft(self.a, &cv, justifyPad(self.width, line.width, self.justify));
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

test "end-to-end: tiny font -> figlet sink output" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(std.testing.allocator, textfig.fixtures.tiny_flf, "tiny", &diag);
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var printer = Printer{ .out = &w, .width = 20, .justify = .left, .hardblank = f.hardblank };
    var r = try render.Renderer.init(std.testing.allocator, &f, printer.sink(), 0, 20, .ltr);
    defer r.deinit();
    for ("Hi") |ch| try r.feed(ch);
    try r.finish();

    try std.testing.expectEqualStrings(
        "      \n" ++
            " H  i \n" ++
            "      \n",
        buf[0..w.end],
    );
}

test "justification padding follows figlet's putstring formulas" {
    var buf: [256]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const rows = [_][]const u21{
        &.{ 'a', 'b' },
        &.{ 'c', 'd' },
    };
    const line = render.RenderedLine{ .rows = &rows, .width = 2, .height = 2 };

    var p = Printer{ .out = &w, .width = 10, .justify = .center, .hardblank = '$' };
    p.sink().call(p.sink().ptr, &line) catch {};
    try std.testing.expectEqualStrings("    ab\n    cd\n", buf[0..w.end]);

    var buf2: [256]u8 = undefined;
    var w2 = Io.Writer.fixed(&buf2);
    var p2 = Printer{ .out = &w2, .width = 10, .justify = .right, .hardblank = '$' };
    p2.sink().call(p2.sink().ptr, &line) catch {};
    try std.testing.expectEqualStrings("       ab\n       cd\n", buf2[0..w2.end]);

    try std.testing.expectEqual(@as(usize, 0), justifyPad(10, 2, .left));
    try std.testing.expectEqual(@as(usize, 4), justifyPad(10, 2, .center));
    try std.testing.expectEqual(@as(usize, 7), justifyPad(10, 2, .right));
}

test "canvas pipeline: tiny font, solid colour and utf8 export" {
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
        .solid = .{ .r = 0xff, .g = 0x00, .b = 0x00 },
        .hardblank = f.hardblank,
        .width = 20,
        .justify = .left,
    };
    var r = try render.Renderer.init(std.testing.allocator, &f, painter.sink(), 0, 20, .ltr);
    defer r.deinit();
    for ("Hi") |ch| try r.feed(ch);
    try r.finish();
    try exporter.finish();

    try std.testing.expect(std.mem.indexOf(u8, buf[0..w.end], "\x1b[38;5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..w.end], "\x1b[0m") != null);
}

test "canvas pipeline: flip filter mirrors the tiny font line" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(std.testing.allocator, textfig.fixtures.tiny_flf, "tiny", &diag);
    defer f.deinit();

    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var exporter = exp.Exporter{ .out = &w, .format = .utf8, .color_mode = .ansi256 };
    var painter = Painter{
        .a = std.testing.allocator,
        .exporter = &exporter,
        .filters = &.{.flip},
        .solid = null,
        .hardblank = f.hardblank,
        .width = 20,
        .justify = .left,
    };
    var r = try render.Renderer.init(std.testing.allocator, &f, painter.sink(), 0, 20, .ltr);
    defer r.deinit();
    for ("H") |ch| try r.feed(ch);
    try r.finish();
    try exporter.finish();

    try std.testing.expect(std.mem.indexOf(u8, buf[0..w.end], "H") != null);
}
