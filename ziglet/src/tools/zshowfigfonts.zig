//! zshowfigfonts - print a sample of every available FIGlet font.
//!
//! The output follows figlet's showfigfonts script: "name :" followed by a
//! rendered sample and a blank line. Without a word, the font's own name is
//! used as the sample, exactly like the script.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;
const render = textfig.render;

pub const name = "zshowfigfonts";

pub const version_text =
    \\zshowfigfonts 1.0.0 - print samples of FIGlet fonts
    \\
;

pub const help_text =
    \\Usage: zshowfigfonts [ -d fontdirectory ] [ -f font ] [ --brief ]
    \\                     [ word ... ]
    \\
    \\zshowfigfonts prints every FIGlet font in the search path together with
    \\a sample. The sample is the word arguments joined by spaces, or the
    \\font's own name when no word is given.
    \\
    \\  -d, --font-dir DIR Change the font directory.  The default is
    \\                     $FIGLET_FONTDIR, then $XDG_DATA_HOME/figlet, then
    \\                     ~/.local/share/figlet, then /usr/share/figlet, then
    \\                     the current directory.
    \\  -f, --font FONT    Print only this font instead of every font.
    \\  -w, --width N      Set the output width for the samples (normally 80).
    \\      --brief        Print only the font names.
    \\  -h, --help         Display this help and exit.
    \\  -v, --version      Display version information and exit.
    \\
;

const Options = struct {
    help: bool = false,
    version: bool = false,
    brief: bool = false,
    font_dir: ?[]const u8 = null,
    font_name: ?[]const u8 = null,
    width: usize = 80,
    words: std.ArrayList([]const u8) = .empty,
};

const Error = error{ InvalidArgs, OutOfMemory };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn invalid(errw: *Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    errw.print("{s}: " ++ fmt ++ "\n", .{name} ++ args) catch {};
    return error.InvalidArgs;
}

fn nextValue(
    inline_value: ?[]const u8,
    argv: []const [:0]const u8,
    index: *usize,
    errw: *Io.Writer,
    opt: []const u8,
) Error![]const u8 {
    if (inline_value) |v| return v;
    if (index.* + 1 >= argv.len) return invalid(errw, "option '{s}' requires an argument", .{opt});
    index.* += 1;
    return argv[index.*];
}

fn parse(a: std.mem.Allocator, argv: []const [:0]const u8, errw: *Io.Writer) Error!Options {
    var opts = Options{};
    var only_operands = false;
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (only_operands) {
            try opts.words.append(a, arg);
            continue;
        }
        if (eq(arg, "--")) {
            only_operands = true;
            continue;
        }
        if (arg.len > 2 and std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            var key = body;
            var inline_value: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, body, '=')) |p| {
                key = body[0..p];
                inline_value = body[p + 1 ..];
            }
            if (eq(key, "help")) {
                opts.help = true;
            } else if (eq(key, "version")) {
                opts.version = true;
            } else if (eq(key, "brief")) {
                opts.brief = true;
            } else if (eq(key, "font")) {
                opts.font_name = try nextValue(inline_value, argv, &i, errw, "--font");
            } else if (eq(key, "font-dir") or eq(key, "fontdir") or eq(key, "directory")) {
                opts.font_dir = try nextValue(inline_value, argv, &i, errw, "--font-dir");
            } else if (eq(key, "width")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--width");
                const n = std.fmt.parseInt(usize, v, 10) catch
                    return invalid(errw, "invalid value for '--width': '{s}'", .{v});
                if (n > 0) opts.width = n;
            } else {
                return invalid(errw, "invalid option '{s}'", .{arg});
            }
            continue;
        }
        if (arg.len >= 2 and arg[0] == '-') {
            if (eq(arg, "-h")) {
                opts.help = true;
            } else if (eq(arg, "-v")) {
                opts.version = true;
            } else if (eq(arg, "-d")) {
                opts.font_dir = try nextValue(null, argv, &i, errw, "-d");
            } else if (eq(arg, "-f")) {
                opts.font_name = try nextValue(null, argv, &i, errw, "-f");
            } else if (eq(arg, "-w")) {
                const v = try nextValue(null, argv, &i, errw, "-w");
                const n = std.fmt.parseInt(usize, v, 10) catch
                    return invalid(errw, "invalid value for '-w': '{s}'", .{v});
                if (n > 0) opts.width = n;
            } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-d")) {
                opts.font_dir = arg[2..];
            } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-f")) {
                opts.font_name = arg[2..];
            } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-w")) {
                const v = arg[2..];
                const n = std.fmt.parseInt(usize, v, 10) catch
                    return invalid(errw, "invalid value for '-w': '{s}'", .{v});
                if (n > 0) opts.width = n;
            } else {
                return invalid(errw, "invalid option '{s}'", .{arg});
            }
            continue;
        }
        try opts.words.append(a, arg);
    }

    return opts;
}

fn fontName(file_name: []const u8) ?[]const u8 {
    var n = file_name;
    if (std.mem.endsWith(u8, n, ".gz")) {
        n = n[0 .. n.len - 3];
    } else if (std.mem.endsWith(u8, n, ".zip")) {
        n = n[0 .. n.len - 4];
    }
    if (std.mem.endsWith(u8, n, ".flf") or std.mem.endsWith(u8, n, ".tlf")) {
        if (n.len == 4) return null;
        return n[0 .. n.len - 4];
    }
    return null;
}

const Lists = struct {
    fonts: []const []const u8,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn dedupe(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var last: ?[]const u8 = null;
    for (items) |item| {
        if (last) |prev| {
            if (eq(item, prev)) continue;
        }
        last = item;
        try out.append(a, item);
    }
    return out.toOwnedSlice(a);
}

fn collect(io: Io, a: std.mem.Allocator, dirs: []const []const u8) !Lists {
    var fonts: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir| {
        var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (fontName(entry.name)) |n| try fonts.append(a, try a.dupe(u8, n));
        }
    }
    try fonts.append(a, "term");
    std.mem.sort([]const u8, fonts.items, {}, lessThan);
    return .{ .fonts = try dedupe(a, fonts.items) };
}

fn sampleText(a: std.mem.Allocator, font_name: []const u8, words: []const []const u8) ![]const u8 {
    if (words.len == 0) return font_name;
    var text: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, idx| {
        if (idx != 0) try text.append(a, ' ');
        try text.appendSlice(a, word);
    }
    return text.toOwnedSlice(a);
}

const SamplePrinter = struct {
    out: *Io.Writer,
    hardblank: u21,

    fn sink(self: *SamplePrinter) render.Sink {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, line: *const render.RenderedLine) anyerror!void {
        const self: *SamplePrinter = @ptrCast(@alignCast(ptr));
        var buf: [4]u8 = undefined;
        for (0..line.height) |y| {
            for (0..line.width) |x| {
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

fn feedText(r: *render.Renderer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b < 0x80) {
            const c: u21 = if (b == '\t') ' ' else b;
            if (c != '\r') try r.feed(c);
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            try r.feed(0xFFFD);
            i += 1;
            continue;
        };
        if (i + n > text.len) {
            try r.feed(0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            try r.feed(0xFFFD);
            i += 1;
            continue;
        };
        try r.feed(cp);
        i += n;
    }
}

/// Print the "name :" header, one rendered sample and the trailing blank
/// lines that separate fonts in the original script.
fn writeFont(
    out: *Io.Writer,
    a: std.mem.Allocator,
    display_name: []const u8,
    f: *font.Font,
    sample: []const u8,
    width: usize,
) !void {
    try out.print("{s} :\n", .{display_name});

    var printer = SamplePrinter{ .out = out, .hardblank = f.hardblank };
    var r = try render.Renderer.init(a, f, printer.sink(), f.font_smush, width, f.print_dir);
    defer r.deinit();
    try feedText(&r, sample);
    try r.finish();

    try out.writeAll("\n\n");
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(1),
        error.Reported => std.process.exit(1),
        else => {
            std.debug.print("zshowfigfonts: {t}\n", .{err});
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
    const opts = parse(arena, argv, errw) catch |err| switch (err) {
        error.InvalidArgs => {
            try errw.writeAll("Try 'zshowfigfonts --help' for more information.\n");
            try errw.flush();
            return error.Reported;
        },
        else => return err,
    };

    if (opts.help) {
        try out.writeAll(help_text);
        try out.flush();
        return;
    }
    if (opts.version) {
        try out.writeAll(version_text);
        try out.flush();
        return;
    }

    const dirs = try font.searchDirs(arena, .{
        .explicit_dir = opts.font_dir,
        .env_fontdir = init.environ_map.get("FIGLET_FONTDIR"),
        .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
        .home = init.environ_map.get("HOME"),
    });

    if (opts.font_dir) |dir| {
        var d = Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
            try errw.print("zshowfigfonts: cannot open font directory \"{s}\": {t}\n", .{ dir, err });
            try errw.flush();
            return error.Reported;
        };
        d.close(io);
    }

    // With -d, only that directory is used, as in the original
    // showfigfonts script; without it the whole search path is scanned.
    var load_dirs: []const []const u8 = dirs;
    if (opts.font_dir) |dir| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = dir;
        load_dirs = one;
    }

    var names: []const []const u8 = undefined;
    if (opts.font_name) |fname| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = fname;
        names = one;
    } else {
        const lists = try collect(io, arena, load_dirs);
        names = lists.fonts;
        if (names.len == 0) {
            try errw.print("zshowfigfonts: no fonts found in {s}\n", .{font.primaryDir(dirs)});
            try errw.flush();
            return error.Reported;
        }
    }

    var had_failure = false;
    for (names) |fname| {
        if (opts.brief) {
            try out.print("{s}\n", .{fname});
            continue;
        }

        var diag: font.Diag = .{};
        var f = font.load(io, gpa, load_dirs, fname, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try errw.print("zshowfigfonts: {s}: {s}\n", .{ fname, diag.text() });
                had_failure = true;
                continue;
            },
        };
        defer f.deinit();

        const sample = try sampleText(arena, fname, opts.words.items);
        try writeFont(out, arena, fname, &f, sample, opts.width);
    }

    try errw.flush();
    try out.flush();
    if (had_failure) return error.Reported;
}

const testing = std.testing;

test "zshowfigfonts options: font, directory, width, brief and words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const argv = [_][:0]const u8{
        "zshowfigfonts", "-d", "fonts", "-f", "big", "-w", "40", "--brief", "Hello", "world",
    };
    const opts = try parse(arena.allocator(), &argv, &w);
    try testing.expectEqualStrings("fonts", opts.font_dir.?);
    try testing.expectEqualStrings("big", opts.font_name.?);
    try testing.expectEqual(@as(usize, 40), opts.width);
    try testing.expect(opts.brief);
    try testing.expectEqual(@as(usize, 2), opts.words.items.len);
}

test "zshowfigfonts uses the font name when no word is given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("slant", try sampleText(a, "slant", &.{}));
    try testing.expectEqualStrings("The lazy dog", try sampleText(a, "slant", &.{ "The", "lazy", "dog" }));
}

test "zshowfigfonts output starts with the font name and a rendered sample" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(testing.allocator, textfig.fixtures.tiny_flf, "tiny", &diag);
    defer f.deinit();

    var buf: [64 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try writeFont(&w, testing.allocator, "tiny", &f, "Hi", 80);

    const text = buf[0..w.end];
    try testing.expect(std.mem.startsWith(u8, text, "tiny :\n"));
    try testing.expect(text.len > "tiny :\n\n\n".len);
    try testing.expect(std.mem.endsWith(u8, text, "\n\n"));
}
