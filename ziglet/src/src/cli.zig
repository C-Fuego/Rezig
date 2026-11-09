//! Merged FIGlet 2.2.5 and TOIlet 1.x command-line parsing for ziglet.
//!
//! FIGlet owns the short options, in particular -E (German off), -h (help),
//! -s (font layout) and the layout controls. TOIlet features are reached
//! through -F (filter chain) and long options (--export, --irc, --html,
//! --color, filter shortcuts). FIGlet's HZ input mode is --hz.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;
const render = textfig.render;
const filter = @import("filter.zig");
const exp = @import("export.zig");
const color = @import("color.zig");

pub const name = "ziglet";

pub const version_text =
    \\ziglet 1.0.0
    \\FIGlet 2.2.5 semantics plus TOIlet 1.x filters, colours and export formats
    \\FIGlet Copyright (C) 1991-2012 Glenn Chappell, Ian Chai, John Cowan,
    \\Christiaan Keet and Claudio Matsuoka
    \\TOIlet Copyright 2006 Sam Hocevar
    \\Internet: <info@figlet.org>
    \\
    \\ziglet, along with the various FIGlet and TOIlet fonts and
    \\documentation, may be freely copied and distributed.
    \\
    \\The latest versions are available from the web sites,
    \\        http://www.figlet.org/
    \\        http://libcaca.zoy.org/toilet.html
    \\
    \\Usage: ziglet [ -cklnoprstvxDELNRSWX ] [ -d fontdirectory ]
    \\               [ -f fontfile ] [ -m smushmode ] [ -w outputwidth ]
    \\               [ -C controlfile ] [ -I infocode ] [ -F filter ]
    \\               [ --export format ] [ message ]
    \\
;

pub const help_text =
    \\Usage: ziglet [ -cklnoprstvxDELNRSWX ] [ -d fontdirectory ]
    \\               [ -f fontfile ] [ -m smushmode ] [ -w outputwidth ]
    \\               [ -C controlfile ] [ -I infocode ] [ -F filter ]
    \\               [ --export format ] [ message ]
    \\
    \\ziglet prints "message", or standard input, using large FIGcharacters
    \\made of ordinary sub-characters. Message arguments are words joined by
    \\spaces. The default is FIGlet behaviour: FIGcharacters are smushed
    \\according to the font and the options below. Options are read from left to
    \\right and only the last option that affects a parameter has any effect;
    \\almost every option has an inverse.
    \\
    \\  -f fontfile        Select the font.  The .flf suffix may be left off of
    \\                     fontfile; .tlf and compressed .flf/.tlf files are
    \\                     accepted as well.
    \\  -d fontdirectory   Change the default font directory.
    \\  -c                 Center the output horizontally.
    \\  -l                 Make the output flush-left.
    \\  -r                 Make the output flush-right.
    \\  -x                 Set the justification according to whether
    \\                     left-to-right or right-to-left text is selected
    \\                     (default).
    \\  -t                 Set the outputwidth to the terminal width.
    \\  -w outputwidth     Set the outputwidth (normally 80).  An outputwidth of
    \\                     1 prints each non-space FIGcharacter on a separate
    \\                     line, no matter how wide it is.
    \\  -p                 Paragraph mode: a line break inside a paragraph is
    \\                     treated as a blank between words.
    \\  -n                 Normal mode: every newline produces a line break
    \\                     (default).
    \\  -D                 Switch to the German (ISO 646-DE) character set.
    \\  -E                 Turn off -D processing (default).  This option keeps
    \\                     FIGlet's meaning; the export format is --export.
    \\  -C controlfile     Add controlfile to the control file list.
    \\  -N                 Clear the control file list.
    \\  -m smushmode       Set the layout mode: -1 full width, 0 kerning, 1..63
    \\                     controlled smushing rule bits, -2 font default.
    \\  -s                 Use the font's own layout (default).
    \\  -S                 Force smushing.
    \\  -k                 Kern: characters touch, but never overlap.
    \\  -W                 Render every FIGcharacter at full width.
    \\  -o                 Universal overlapping.
    \\  -L                 Force left-to-right printing.
    \\  -R                 Force right-to-left printing.
    \\  -X                 Use the font's print direction (default).
    \\  -A                 Take input only from the message arguments.
    \\  -v                 Print version and copyright information, then the
    \\                     usage line.
    \\  -I infocode        Print a FIGlet info code and exit: 0 copyright and
    \\                     version, 1 version integer (20205), 2 font directory,
    \\                     3 font name, 4 output width, 5 supported formats.
    \\                     -1 means normal operation.
    \\
    \\Long options:
    \\  -h, --help             Display this help and exit.  (FIGlet's -h is the
    \\                         HZ input mode, available as --hz.)
    \\      --hz               Select FIGlet's HZ input mode.  Accepted for
    \\                         compatibility; input is always UTF-8, so the
    \\                         mode has no effect.
    \\  -i, --file FILE        Render FILE ("-" = stdin); repeatable.
    \\      --list-fonts       List the fonts in the search path and exit.
    \\      --font NAME        Same as -f; --font-dir DIR is the same as -d.
    \\      --directory DIR    Same as -d (TOIlet's spelling).
    \\      --control FILE     Same as -C; --no-controls is the same as -N.
    \\      --layout MODE      Same as -m, or "default" for the font's layout.
    \\      --force-smush      Same as -S; --smush is accepted too.
    \\      --kerning          Same as -k.
    \\      --full-width       Same as -W.
    \\      --overflow         Same as -o.
    \\      --default-layout   Same as -s.
    \\      --width N          Same as -w; --term-width is the same as -t.
    \\      --center           Same as -c.
    \\      --justify MODE     left, center, right or default, same as -l, -c,
    \\                         -r and -x.
    \\      --left-to-right, --right-to-left, --default-direction
    \\                         Same as -L, -R and -X.
    \\      --paragraph, --no-paragraph
    \\                         Same as -p and -n.
    \\      --german, --no-german
    \\                         Same as -D and -E.
    \\      --infocode CODE    Same as -I; --version is the same as -v.
    \\
    \\Extended options:
    \\  -F, --filter LIST      Apply TOIlet filters in order.  LIST is
    \\                         separated by ':' or ','; "list" prints the
    \\                         available filters.
    \\      --export FORMAT    Export through the canvas pipeline as utf8
    \\                         (default), ansi, irc or html; "list" prints the
    \\                         formats.  -E keeps FIGlet's meaning (German
    \\                         off), so the export format has no short form.
    \\      --irc, --html      Same as --export irc / --export html.
    \\      --rainbow, --gay   Same as -F rainbow.
    \\      --metal            Same as -F metal.
    \\      --flip, --flop     Mirror the figure horizontally / vertically.
    \\      --crop             Remove blank borders.
    \\      --border           Surround the figure with a box.
    \\      --180              Rotate the figure 180 degrees.
    \\      --left, --right    Rotate the figure 90 degrees counter-clockwise /
    \\                         clockwise.  (Justification is -l, -r or
    \\                         --justify.)
    \\      --color SPEC       Solid colour: 0..255, #rrggbb, #rgb or r,g,b.
    \\      --no-color         Never emit colour escapes.
    \\      --truecolor        Use 24-bit escapes for utf8 export.
    \\      --256              Use xterm-256 escapes for utf8 export.
    \\
    \\Option ownership: -E is FIGlet's German off (use --export for the export
    \\format), -h is help (FIGlet's HZ mode is --hz), -s is FIGlet's font
    \\layout (use --layout default for TOIlet's default layout), and -F is
    \\TOIlet's filter chain. The shared options -f -d -w -t -k -S -W -o -I -v
    \\mean the same in both CLIs.
    \\
    \\The FIGlet pipeline is used when no TOIlet option is present: rendered
    \\rows are printed directly, with FIGlet smushing, control files, direction
    \\and justification.  Giving any of -F/--filter, --export, --irc, --html,
    \\--color, --no-color, --truecolor, --256 or a filter shortcut switches to
    \\the TOIlet canvas pipeline: every rendered line becomes a canvas, the
    \\filters run in order, and the result is written in the selected export
    \\format.  Layout options (-s/-k/-S/-W/-o/-m) apply to both pipelines.
    \\
    \\Font search order: -d DIR, $FIGLET_FONTDIR, $XDG_DATA_HOME/figlet (or
    \\~/.local/share/figlet), /usr/share/figlet, /usr/share/ziglet/fonts,
    \\then the current directory.
    \\Names expand to name, name.flf[.gz|.zip], name.tlf[.gz|.zip].
    \\Compressed fonts use the system zlib. The built-in "term" font always
    \\works (one row, no smushing).
    \\
;

pub const Options = struct {
    help: bool = false,
    version: bool = false,
    list_fonts: bool = false,
    list_filters: bool = false,
    list_exports: bool = false,
    infocode: ?i32 = null,

    font: []const u8 = "standard",
    font_explicit: bool = false,
    font_dir: ?[]const u8 = null,
    controls: std.ArrayList([]const u8) = .empty,

    layout_ops: std.ArrayList(render.LayoutOp) = .empty,
    width_value: ?usize = null,
    use_term_width: bool = false,

    justify: ?font.Justify = null,
    direction: union(enum) { auto, ltr, rtl } = .auto,

    paragraph: bool = false,
    german: bool = false,
    hz: bool = false,
    cmd_input: bool = false,

    files: std.ArrayList([]const u8) = .empty,
    operands: std.ArrayList([]const u8) = .empty,

    // TOIlet pipeline. `canvas` is set as soon as one TOIlet option is seen;
    // the FIGlet pipeline is used otherwise.
    canvas: bool = false,
    filters: std.ArrayList(filter.Kind) = .empty,
    export_format: exp.Format = .utf8,
    solid: color.ColorSpec = .none,
    no_color: bool = false,
    truecolor: bool = false,
    force256: bool = false,
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

fn appendFilter(opts: *Options, a: std.mem.Allocator, kind: filter.Kind) Error!void {
    try opts.filters.append(a, kind);
    opts.canvas = true;
}

fn addFilterChain(opts: *Options, a: std.mem.Allocator, text: []const u8, errw: *Io.Writer) Error!void {
    if (eq(text, "list")) {
        opts.list_filters = true;
        return;
    }
    const chain = filter.parseChain(a, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnknownFilter => return invalid(errw, "unknown filter near '{s}' (try -F list)", .{text}),
    };
    try opts.filters.appendSlice(a, chain);
    opts.canvas = true;
}

fn setExport(opts: *Options, text: []const u8, errw: *Io.Writer) Error!void {
    if (eq(text, "list")) {
        opts.list_exports = true;
        return;
    }
    opts.export_format = exp.Format.parse(text) orelse
        return invalid(errw, "unknown export format '{s}' (try --export list)", .{text});
    opts.canvas = true;
}

fn setColor(opts: *Options, text: []const u8, errw: *Io.Writer) Error!void {
    opts.solid = color.parseColorSpec(text) catch
        return invalid(errw, "invalid --color value '{s}' (use 0..255, #rrggbb or r,g,b)", .{text});
    opts.canvas = true;
}

fn setJustify(opts: *Options, text: []const u8, errw: *Io.Writer) Error!void {
    if (eq(text, "left")) {
        opts.justify = .left;
    } else if (eq(text, "center") or eq(text, "centre")) {
        opts.justify = .center;
    } else if (eq(text, "right")) {
        opts.justify = .right;
    } else if (eq(text, "default") or eq(text, "auto")) {
        opts.justify = null;
    } else {
        return invalid(errw, "invalid --justify value '{s}' (use left, center, right or default)", .{text});
    }
}

/// The arena is expected to outlive Options; it owns the option lists.
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
            } else if (eq(key, "hz")) {
                // FIGlet's -h input mode, accepted and ignored: textfig is
                // UTF-8 only, like modern FIGlet control files.
                opts.hz = true;
            } else if (eq(key, "list-fonts")) {
                opts.list_fonts = true;
            } else if (eq(key, "font")) {
                opts.font = try nextValue(inline_value, argv, &i, errw, "--font");
                opts.font_explicit = true;
            } else if (eq(key, "font-dir") or eq(key, "fontdir") or eq(key, "directory")) {
                opts.font_dir = try nextValue(inline_value, argv, &i, errw, "--font-dir");
            } else if (eq(key, "control")) {
                try opts.controls.append(a, try nextValue(inline_value, argv, &i, errw, "--control"));
            } else if (eq(key, "no-controls")) {
                opts.controls.clearRetainingCapacity();
            } else if (eq(key, "layout") or eq(key, "layoutmode")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--layout");
                if (eq(v, "default")) {
                    try opts.layout_ops.append(a, .font_default);
                } else {
                    try opts.layout_ops.append(a, .{ .mode = try parseI32(errw, "--layout", v) });
                }
            } else if (eq(key, "kerning") or eq(key, "kern")) {
                try opts.layout_ops.append(a, .kern);
            } else if (eq(key, "full-width") or eq(key, "fullwidth")) {
                try opts.layout_ops.append(a, .full_width);
            } else if (eq(key, "force-smush") or eq(key, "smush")) {
                try opts.layout_ops.append(a, .force_smush);
            } else if (eq(key, "overflow") or eq(key, "overlap")) {
                try opts.layout_ops.append(a, .overlap);
            } else if (eq(key, "default-layout")) {
                try opts.layout_ops.append(a, .font_default);
            } else if (eq(key, "width")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--width");
                const n = try parseUsize(errw, "--width", v);
                // figlet ignores -w0 (only positive values change the width).
                if (n > 0) {
                    opts.width_value = n;
                    opts.use_term_width = false;
                }
            } else if (eq(key, "term-width") or eq(key, "termwidth")) {
                opts.use_term_width = true;
            } else if (eq(key, "center") or eq(key, "centre")) {
                opts.justify = .center;
            } else if (eq(key, "justify")) {
                try setJustify(&opts, try nextValue(inline_value, argv, &i, errw, "--justify"), errw);
            } else if (eq(key, "default-justify")) {
                opts.justify = null;
            } else if (eq(key, "left-to-right")) {
                opts.direction = .ltr;
            } else if (eq(key, "right-to-left")) {
                opts.direction = .rtl;
            } else if (eq(key, "default-direction")) {
                opts.direction = .auto;
            } else if (eq(key, "paragraph")) {
                opts.paragraph = true;
            } else if (eq(key, "no-paragraph")) {
                opts.paragraph = false;
            } else if (eq(key, "german")) {
                opts.german = true;
            } else if (eq(key, "no-german")) {
                opts.german = false;
            } else if (eq(key, "file") or eq(key, "input-file") or eq(key, "input")) {
                try opts.files.append(a, try nextValue(inline_value, argv, &i, errw, "--file"));
            } else if (eq(key, "infocode")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--infocode");
                opts.infocode = try parseI32(errw, "--infocode", v);
            } else if (eq(key, "filter")) {
                try addFilterChain(&opts, a, try nextValue(inline_value, argv, &i, errw, "--filter"), errw);
            } else if (eq(key, "export")) {
                try setExport(&opts, try nextValue(inline_value, argv, &i, errw, "--export"), errw);
            } else if (eq(key, "irc")) {
                opts.export_format = .irc;
                opts.canvas = true;
            } else if (eq(key, "html")) {
                opts.export_format = .html;
                opts.canvas = true;
            } else if (eq(key, "color") or eq(key, "colour")) {
                try setColor(&opts, try nextValue(inline_value, argv, &i, errw, "--color"), errw);
            } else if (eq(key, "no-color") or eq(key, "no-colour")) {
                opts.no_color = true;
                opts.canvas = true;
            } else if (eq(key, "truecolor") or eq(key, "true-colour")) {
                opts.truecolor = true;
                opts.canvas = true;
            } else if (eq(key, "256")) {
                opts.force256 = true;
                opts.canvas = true;
            } else if (eq(key, "rainbow") or eq(key, "gay")) {
                try appendFilter(&opts, a, .rainbow);
            } else if (eq(key, "metal")) {
                try appendFilter(&opts, a, .metal);
            } else if (eq(key, "flip")) {
                try appendFilter(&opts, a, .flip);
            } else if (eq(key, "flop")) {
                try appendFilter(&opts, a, .flop);
            } else if (eq(key, "crop")) {
                try appendFilter(&opts, a, .crop);
            } else if (eq(key, "border")) {
                try appendFilter(&opts, a, .border);
            } else if (eq(key, "180") or eq(key, "rotate")) {
                try appendFilter(&opts, a, .rot180);
            } else if (eq(key, "left")) {
                try appendFilter(&opts, a, .left);
            } else if (eq(key, "right")) {
                try appendFilter(&opts, a, .right);
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
                    'A' => opts.cmd_input = true,
                    'D' => opts.german = true,
                    'E' => opts.german = false,
                    'N' => opts.controls.clearRetainingCapacity(),
                    'L' => opts.direction = .ltr,
                    'R' => opts.direction = .rtl,
                    'X' => opts.direction = .auto,
                    'x' => opts.justify = null,
                    'l' => opts.justify = .left,
                    'c' => opts.justify = .center,
                    'r' => opts.justify = .right,
                    'p' => opts.paragraph = true,
                    'n' => opts.paragraph = false,
                    's' => try opts.layout_ops.append(a, .font_default),
                    'k' => try opts.layout_ops.append(a, .kern),
                    'W' => try opts.layout_ops.append(a, .full_width),
                    'S' => try opts.layout_ops.append(a, .force_smush),
                    'o' => try opts.layout_ops.append(a, .overlap),
                    't' => opts.use_term_width = true,
                    'f', 'd', 'C', 'm', 'w', 'I', 'i', 'F' => {
                        const val = try nextValue(attached, argv, &i, errw, "-");
                        switch (ch) {
                            'f' => {
                                opts.font = val;
                                opts.font_explicit = true;
                            },
                            'd' => opts.font_dir = val,
                            'C' => try opts.controls.append(a, val),
                            'm' => try opts.layout_ops.append(a, .{ .mode = try parseI32(errw, "-m", val) }),
                            'w' => {
                                const n = try parseUsize(errw, "-w", val);
                                if (n > 0) {
                                    opts.width_value = n;
                                    opts.use_term_width = false;
                                }
                            },
                            'I' => opts.infocode = try parseI32(errw, "-I", val),
                            'i' => try opts.files.append(a, val),
                            'F' => try addFilterChain(&opts, a, val, errw),
                            else => unreachable,
                        }
                        break; // the rest of the cluster was the value
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

test "figlet options: justification, width order and message words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ziglet", "-c", "-w", "40", "-t", "Hello", "world" };
    const o = try parseArgs(a, &argv);
    try testing.expectEqual(font.Justify.center, o.justify.?);
    try testing.expect(o.use_term_width);
    try testing.expectEqual(@as(usize, 40), o.width_value.?);
    try testing.expectEqual(@as(usize, 2), o.operands.items.len);
    try testing.expect(!o.canvas);
}

test "figlet options: clustered flags and layout order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ziglet", "-ptk", "-m15", "-W", "-c" };
    const o = try parseArgs(a, &argv);
    try testing.expect(o.paragraph);
    try testing.expectEqual(@as(usize, 3), o.layout_ops.items.len);
    try testing.expectEqual(render.LayoutOp.kern, o.layout_ops.items[0]);
    try testing.expectEqual(@as(i32, 15), o.layout_ops.items[1].mode);
    try testing.expectEqual(render.LayoutOp.full_width, o.layout_ops.items[2]);

    const combined = blk: {
        var s: u32 = 143;
        for (o.layout_ops.items) |op| s = render.applyLayoutOp(s, 143, op);
        break :blk s;
    };
    try testing.expectEqual(@as(u32, 0), combined); // -W wins
}

test "figlet options: infocode, font, control and -N" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ziglet", "-f", "big.flf", "-C", "up", "-C", "down", "-N", "-C", "again", "-I3" };
    const o = try parseArgs(a, &argv);
    try testing.expectEqualStrings("big.flf", o.font);
    try testing.expect(o.font_explicit);
    try testing.expectEqual(@as(usize, 1), o.controls.items.len);
    try testing.expectEqualStrings("again", o.controls.items[0]);
    try testing.expectEqual(@as(i32, 3), o.infocode.?);
}

test "conflict resolution: -E, -h, -s and -F keep their owners" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e = try parseArgs(a, &[_][:0]const u8{ "ziglet", "-E" });
    try testing.expect(!e.german);
    try testing.expectEqual(exp.Format.utf8, e.export_format);
    try testing.expect(!e.canvas); // -E does not select an export

    const h = try parseArgs(a, &[_][:0]const u8{ "ziglet", "-h" });
    try testing.expect(h.help);

    const s = try parseArgs(a, &[_][:0]const u8{ "ziglet", "-s", "--layout", "default" });
    try testing.expectEqual(@as(usize, 2), s.layout_ops.items.len);
    try testing.expectEqual(render.LayoutOp.font_default, s.layout_ops.items[0]);
    try testing.expectEqual(render.LayoutOp.font_default, s.layout_ops.items[1]);

    const f = try parseArgs(a, &[_][:0]const u8{ "ziglet", "-F", "flip,rainbow" });
    try testing.expectEqual(@as(usize, 2), f.filters.items.len);
    try testing.expectEqual(filter.Kind.flip, f.filters.items[0]);
    try testing.expectEqual(filter.Kind.rainbow, f.filters.items[1]);
    try testing.expect(f.canvas);
}

test "toilet options: --export, --color and filter shortcuts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{
        "ziglet", "--export", "irc", "--color", "#ff8800", "--metal", "--flip", "Hi",
    };
    const o = try parseArgs(a, &argv);
    try testing.expectEqual(exp.Format.irc, o.export_format);
    try testing.expectEqual(@as(u8, 0xff), o.solid.rgb.r);
    try testing.expectEqual(@as(usize, 2), o.filters.items.len);
    try testing.expectEqual(filter.Kind.metal, o.filters.items[0]);
    try testing.expectEqual(filter.Kind.flip, o.filters.items[1]);
    try testing.expect(o.canvas);
    try testing.expectEqual(@as(usize, 1), o.operands.items.len);
}

test "toilet options: --left/--right are filters, --justify is alignment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ziglet", "--left", "--justify", "right", "-l" };
    const o = try parseArgs(a, &argv);
    try testing.expectEqual(@as(usize, 1), o.filters.items.len);
    try testing.expectEqual(filter.Kind.left, o.filters.items[0]);
    try testing.expectEqual(font.Justify.left, o.justify.?); // -l wins over --justify
}

test "list modes and --hz" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][:0]const u8{ "ziglet", "-F", "list", "--export", "list", "--hz" };
    const o = try parseArgs(a, &argv);
    try testing.expect(o.list_filters);
    try testing.expect(o.list_exports);
    try testing.expect(o.hz);
    try testing.expect(!o.canvas);
}

test "unknown filter, export and option are reported cleanly" {
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    const argv = [_][:0]const u8{ "ziglet", "-F", "flip,nope" };
    try testing.expectError(error.InvalidArgs, parse(testing.allocator, &argv, &w));
    try testing.expect(std.mem.indexOf(u8, w.buffer[0..w.end], "unknown filter") != null);

    var buf2: [512]u8 = undefined;
    var w2 = Io.Writer.fixed(&buf2);
    const argv2 = [_][:0]const u8{ "ziglet", "--export", "png" };
    try testing.expectError(error.InvalidArgs, parse(testing.allocator, &argv2, &w2));
    try testing.expect(std.mem.indexOf(u8, w2.buffer[0..w2.end], "unknown export") != null);

    var buf3: [512]u8 = undefined;
    var w3 = Io.Writer.fixed(&buf3);
    const argv3 = [_][:0]const u8{ "ziglet", "-Z" };
    try testing.expectError(error.InvalidArgs, parse(testing.allocator, &argv3, &w3));
    try testing.expect(std.mem.indexOf(u8, w3.buffer[0..w3.end], "invalid option") != null);
}
