//! TOIlet command-line parsing for ztoilet.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const render = textfig.render;
const filter = @import("filter.zig");
const exp = @import("export.zig");
const color = @import("color.zig");

pub const name = "ztoilet";
pub const version_text =
    \\ztoilet 1.0.0 - TOIlet compatible
    \\TOIlet Copyright 2006 Sam Hocevar
    \\Internet: <sam@hocevar.net>
    \\
    \\ztoilet, along with the various TOIlet fonts and documentation, may be
    \\freely copied and distributed.
    \\
    \\If you use TOIlet, please send an e-mail message to <sam@hocevar.net>.
    \\
    \\The latest version of TOIlet is available from the web site,
    \\        http://libcaca.zoy.org/toilet.html
    \\
    \\Usage: ztoilet [ -hkostvSW ] [ -d fontdirectory ]
    \\               [ -f fontfile ] [ -F filter ] [ -w outputwidth ]
    \\               [ -I infocode ] [ -E format ] [ message ]
    \\
;

pub const help_text =
    \\  -f, --font <name>        select the font
    \\  -d, --directory <dir>    specify font directory
    \\  -s, -S, -k, -W, -o       render mode (default, force smushing,
    \\                           kerning, full width, overlap)
    \\  -w, --width <width>      set output width
    \\  -t, --termwidth          adapt to terminal's width
    \\  -F, --filter <filters>   apply one or several filters to the text
    \\  -F, --filter list        list available filters
    \\      --rainbow            rainbow filter (same as -F rainbow)
    \\      --metal              metal filter (same as -F metal)
    \\  -E, --export <format>    select export format
    \\  -E, --export list        list available export formats
    \\      --irc                output IRC colour codes (same as -E irc)
    \\      --html               output an HTML document (same as -E html)
    \\  -h, --help               display this help and exit
    \\  -I, --infocode <code>    print FIGlet-compatible infocode
    \\  -v, --version            output version information and exit
    \\
    \\Extended options:
    \\  -i, --file <file>        render a file ("-" = stdin); repeatable
    \\      --gay                same as --rainbow
    \\      --flip, --flop       same as -F flip / -F flop
    \\      --crop, --border     same as -F crop / -F border
    \\      --180, --left, --right
    \\                           same as -F 180 / -F left / -F right
    \\      --color <spec>       solid colour: 0..255, #rrggbb, #rgb, r,g,b
    \\      --no-color           never emit escape or colour codes
    \\      --truecolor          use 24-bit escapes for utf8 export
    \\      --256                use xterm-256 escapes for utf8 export
    \\
    \\Filter values: crop, rainbow (gay), metal, flip, flop, 180, left, right,
    \\border; applied in order of appearance, ':' or ',' separated.
    \\Infocodes: 0 version and usage, 1 version integer (20201), 2 font
    \\directory, 3 font name, 4 output width, 5 supported formats.
    \\Font search order: -d DIR, $FIGLET_FONTDIR, $XDG_DATA_HOME/figlet (or
    \\~/.local/share/figlet), /usr/share/figlet, then the current directory.
    \\Names expand to name, name.flf[.gz|.zip], name.tlf[.gz|.zip].
    \\Compressed fonts use the system zlib; the built-in "term" font always
    \\works (one row, no smushing).
    \\
    \\Usage: ztoilet [ -hkostvSW ] [ -d fontdirectory ]
    \\               [ -f fontfile ] [ -F filter ] [ -w outputwidth ]
    \\               [ -I infocode ] [ -E format ] [ message ]
    \\
;

pub const Options = struct {
    help: bool = false,
    version: bool = false,
    infocode: ?i32 = null,
    list_filters: bool = false,
    list_exports: bool = false,

    font: []const u8 = "standard",
    font_explicit: bool = false,
    font_dir: ?[]const u8 = null,
    layout_ops: std.ArrayList(render.LayoutOp) = .empty,
    width_value: ?usize = null,
    use_term_width: bool = false,

    filters: std.ArrayList(filter.Kind) = .empty,
    export_format: exp.Format = .utf8,
    solid: color.ColorSpec = .none,
    no_color: bool = false,
    truecolor: bool = false,
    force256: bool = false,

    files: std.ArrayList([]const u8) = .empty,
    operands: std.ArrayList([]const u8) = .empty,
};

pub const Error = error{ InvalidArgs, OutOfMemory };

fn invalid(errw: *Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    errw.print("{s}: " ++ fmt ++ "\n", .{name} ++ args) catch {};
    return error.InvalidArgs;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
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

fn parseUsize(errw: *Io.Writer, opt: []const u8, text: []const u8) Error!usize {
    return std.fmt.parseInt(usize, text, 10) catch
        return invalid(errw, "invalid value for '{s}': '{s}'", .{ opt, text });
}

fn parseI32(errw: *Io.Writer, opt: []const u8, text: []const u8) Error!i32 {
    return std.fmt.parseInt(i32, text, 10) catch
        return invalid(errw, "invalid value for '{s}': '{s}'", .{ opt, text });
}

fn addFilter(opts: *Options, a: std.mem.Allocator, text: []const u8, errw: *Io.Writer) Error!void {
    const chain = filter.parseChain(a, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownFilter => return invalid(errw, "unknown filter near '{s}' (try -F list)", .{text}),
    };
    try opts.filters.appendSlice(a, chain);
}

fn setExport(opts: *Options, text: []const u8, errw: *Io.Writer) Error!void {
    if (eq(text, "list")) {
        opts.list_exports = true;
        return;
    }
    opts.export_format = exp.Format.parse(text) orelse
        return invalid(errw, "unknown export format '{s}' (try -E list)", .{text});
}

fn setColor(opts: *Options, text: []const u8, errw: *Io.Writer) Error!void {
    opts.solid = color.parseColorSpec(text) catch
        return invalid(errw, "invalid --color value '{s}' (use 0..255, #rrggbb or r,g,b)", .{text});
}

pub fn parse(
    a: std.mem.Allocator,
    argv: []const [:0]const u8,
    errw: *Io.Writer,
) Error!Options {
    var opts = Options{};
    var only_operands = false;
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (only_operands) {
            try opts.operands.append(a, arg);
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
            } else if (eq(key, "font")) {
                opts.font = try nextValue(inline_value, argv, &i, errw, "--font");
                opts.font_explicit = true;
            } else if (eq(key, "directory") or eq(key, "font-dir") or eq(key, "fontdir")) {
                opts.font_dir = try nextValue(inline_value, argv, &i, errw, "--directory");
            } else if (eq(key, "width")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--width");
                const n = try parseUsize(errw, "--width", v);
                // figlet ignores -w0 (only positive values change the width).
                if (n > 0) {
                    opts.width_value = n;
                    opts.use_term_width = false;
                }
            } else if (eq(key, "termwidth") or eq(key, "term-width")) {
                opts.use_term_width = true;
            } else if (eq(key, "filter")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--filter");
                if (eq(v, "list")) {
                    opts.list_filters = true;
                } else {
                    try addFilter(&opts, a, v, errw);
                }
            } else if (eq(key, "gay") or eq(key, "rainbow")) {
                try opts.filters.append(a, .rainbow);
            } else if (eq(key, "metal")) {
                try opts.filters.append(a, .metal);
            } else if (eq(key, "flip")) {
                try opts.filters.append(a, .flip);
            } else if (eq(key, "flop")) {
                try opts.filters.append(a, .flop);
            } else if (eq(key, "crop")) {
                try opts.filters.append(a, .crop);
            } else if (eq(key, "border")) {
                try opts.filters.append(a, .border);
            } else if (eq(key, "180") or eq(key, "rotate")) {
                try opts.filters.append(a, .rot180);
            } else if (eq(key, "left")) {
                try opts.filters.append(a, .left);
            } else if (eq(key, "right")) {
                try opts.filters.append(a, .right);
            } else if (eq(key, "export")) {
                try setExport(&opts, try nextValue(inline_value, argv, &i, errw, "--export"), errw);
            } else if (eq(key, "irc")) {
                opts.export_format = .irc;
            } else if (eq(key, "html")) {
                opts.export_format = .html;
            } else if (eq(key, "color") or eq(key, "colour")) {
                try setColor(&opts, try nextValue(inline_value, argv, &i, errw, "--color"), errw);
            } else if (eq(key, "no-color") or eq(key, "no-colour")) {
                opts.no_color = true;
            } else if (eq(key, "truecolor") or eq(key, "true-colour")) {
                opts.truecolor = true;
            } else if (eq(key, "256")) {
                opts.force256 = true;
            } else if (eq(key, "file") or eq(key, "input-file") or eq(key, "input")) {
                try opts.files.append(a, try nextValue(inline_value, argv, &i, errw, "--file"));
            } else if (eq(key, "infocode")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--infocode");
                opts.infocode = try parseI32(errw, "--infocode", v);
            } else {
                return invalid(errw, "unrecognized option '--{s}'", .{key});
            }
            continue;
        }

        if (arg.len >= 2 and arg[0] == '-' and arg[1] != '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                const attached: ?[]const u8 = if (j + 1 < arg.len) arg[j + 1 ..] else null;
                switch (ch) {
                    'h' => opts.help = true,
                    'v' => opts.version = true,
                    't' => opts.use_term_width = true,
                    's' => try opts.layout_ops.append(a, .font_default),
                    'S' => try opts.layout_ops.append(a, .force_smush),
                    'k' => try opts.layout_ops.append(a, .kern),
                    'W' => try opts.layout_ops.append(a, .full_width),
                    'o' => try opts.layout_ops.append(a, .overlap),
                    'f', 'd', 'w', 'F', 'E', 'I', 'i' => {
                        const val = try nextValue(attached, argv, &i, errw, "-");
                        switch (ch) {
                            'f' => {
                                opts.font = val;
                                opts.font_explicit = true;
                            },
                            'd' => opts.font_dir = val,
                            'w' => {
                                const n = try parseUsize(errw, "-w", val);
                                if (n > 0) {
                                    opts.width_value = n;
                                    opts.use_term_width = false;
                                }
                            },
                            'F' => {
                                if (eq(val, "list")) {
                                    opts.list_filters = true;
                                } else {
                                    try addFilter(&opts, a, val, errw);
                                }
                            },
                            'E' => try setExport(&opts, val, errw),
                            'I' => opts.infocode = try parseI32(errw, "-I", val),
                            'i' => try opts.files.append(a, val),
                            else => unreachable,
                        }
                        break;
                    },
                    else => return invalid(errw, "invalid option -- '{c}'", .{ch}),
                }
            }
            continue;
        }

        try opts.operands.append(a, arg);
    }

    if (opts.font.len == 0) return invalid(errw, "font name must not be empty", .{});
    if (opts.files.items.len != 0 and opts.operands.items.len != 0) {
        return invalid(errw, "--file cannot be combined with message arguments", .{});
    }
    return opts;
}

const testing = std.testing;

fn parseArgs(a: std.mem.Allocator, list: []const [:0]const u8) !Options {
    var buf: [4096]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    return parse(a, list, &w);
}

test "toilet options: filters, export and colour" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{
        "ztoilet", "-F",      "flip,rainbow", "--metal", "-E",    "irc",
        "--color", "#ff8800", "-w",           "40",      "Hello",
    };
    const o = try parseArgs(a, &argv);
    try testing.expectEqual(@as(usize, 3), o.filters.items.len);
    try testing.expectEqual(filter.Kind.flip, o.filters.items[0]);
    try testing.expectEqual(filter.Kind.rainbow, o.filters.items[1]);
    try testing.expectEqual(filter.Kind.metal, o.filters.items[2]);
    try testing.expectEqual(exp.Format.irc, o.export_format);
    try testing.expectEqual(@as(u8, 0xff), o.solid.rgb.r);
    try testing.expectEqual(@as(usize, 40), o.width_value.?);
    try testing.expectEqual(@as(usize, 1), o.operands.items.len);
}

test "toilet options: list modes and short aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ztoilet", "-F", "list", "-E", "list", "--irc", "--html" };
    const o = try parseArgs(a, &argv);
    try testing.expect(o.list_filters);
    try testing.expect(o.list_exports);
    try testing.expectEqual(exp.Format.html, o.export_format);

    const argv2 = [_][:0]const u8{ "ztoilet", "-s", "-S", "-k", "-W", "-o" };
    const o2 = try parseArgs(a, &argv2);
    try testing.expectEqual(@as(usize, 5), o2.layout_ops.items.len);
}

test "toilet options: unknown filter reports a clean error" {
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const argv = [_][:0]const u8{ "ztoilet", "-F", "flip,nope" };
    try testing.expectError(error.InvalidArgs, parse(testing.allocator, &argv, &w));
    try testing.expect(std.mem.indexOf(u8, w.buffer[0..w.end], "unknown filter") != null);
}
