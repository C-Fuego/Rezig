//! zfiglist - list the FIGlet fonts and control files in the font search path.
//!
//! The output follows figlet's figlist script: a "Default font"/"Font
//! directory" header followed by one name per line. Unlike the script, every
//! directory in the search path is scanned, duplicates are removed and the
//! names are sorted. Plain, .gz and .zip font containers are all listed.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;

pub const name = "zfiglist";

pub const version_text =
    \\zfiglist 1.0.0 - FIGlet font and control file lister
    \\
;

pub const help_text =
    \\Usage: zfiglist [ -d fontdirectory ]
    \\
    \\zfiglist lists the FIGlet fonts and control files available in the font
    \\search path, one name per line and sorted alphabetically. Plain, gzip
    \\(.flf.gz) and zip (.flf.zip) compressed fonts are listed as well, as is
    \\the built-in "term" font.
    \\
    \\  -d, --font-dir DIR Change the font directory.  The default is
    \\                     $FIGLET_FONTDIR, then $XDG_DATA_HOME/figlet, then
    \\                     ~/.local/share/figlet, then /usr/share/figlet, then
    \\                     the current directory.
    \\  -h, --help         Display this help and exit.
    \\  -v, --version      Display version information and exit.
    \\
;

const Options = struct {
    help: bool = false,
    version: bool = false,
    font_dir: ?[]const u8 = null,
};

const Error = error{InvalidArgs};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn invalid(errw: *Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    errw.print("{s}: " ++ fmt ++ "\n", .{name} ++ args) catch {};
    return error.InvalidArgs;
}

fn parse(argv: []const [:0]const u8, errw: *Io.Writer) Error!Options {
    var opts = Options{};
    var only_operands = false;
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (only_operands) return invalid(errw, "unexpected argument '{s}'", .{arg});
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
            } else if (eq(key, "font-dir") or eq(key, "fontdir") or eq(key, "directory")) {
                opts.font_dir = inline_value orelse blk: {
                    if (i + 1 >= argv.len) return invalid(errw, "option '{s}' requires an argument", .{arg});
                    i += 1;
                    break :blk argv[i];
                };
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
                if (i + 1 >= argv.len) return invalid(errw, "option '-d' requires an argument", .{});
                i += 1;
                opts.font_dir = argv[i];
            } else if (arg.len > 2 and std.mem.startsWith(u8, arg, "-d")) {
                opts.font_dir = arg[2..];
            } else {
                return invalid(errw, "invalid option '{s}'", .{arg});
            }
            continue;
        }
        return invalid(errw, "unexpected argument '{s}'", .{arg});
    }

    return opts;
}

/// Font base name for a directory entry: strips an optional .gz/.zip
/// container suffix and then the .flf/.tlf font suffix.
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

fn controlName(file_name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, file_name, ".flc") or std.mem.endsWith(u8, file_name, ".tlc")) {
        if (file_name.len == 4) return null;
        return file_name[0 .. file_name.len - 4];
    }
    return null;
}

const Lists = struct {
    fonts: []const []const u8,
    controls: []const []const u8,
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Scan every search directory. The returned slices live in `a`.
fn collect(
    io: Io,
    a: std.mem.Allocator,
    dirs: []const []const u8,
    include_term: bool,
) !Lists {
    var fonts: std.ArrayList([]const u8) = .empty;
    var controls: std.ArrayList([]const u8) = .empty;

    for (dirs) |dir| {
        var d = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind == .directory) continue;
            if (fontName(entry.name)) |n| {
                try fonts.append(a, try a.dupe(u8, n));
            } else if (controlName(entry.name)) |n| {
                try controls.append(a, try a.dupe(u8, n));
            }
        }
    }

    if (include_term) try fonts.append(a, "term");
    std.mem.sort([]const u8, fonts.items, {}, lessThan);
    std.mem.sort([]const u8, controls.items, {}, lessThan);
    return .{
        .fonts = try fonts.toOwnedSlice(a),
        .controls = try controls.toOwnedSlice(a),
    };
}

fn countUnique(items: []const []const u8) usize {
    var count: usize = 0;
    var last: ?[]const u8 = null;
    for (items) |item| {
        if (last) |l| {
            if (eq(item, l)) continue;
        }
        last = item;
        count += 1;
    }
    return count;
}

fn printUnique(w: *Io.Writer, items: []const []const u8) !void {
    var last: ?[]const u8 = null;
    for (items) |item| {
        if (last) |l| {
            if (eq(item, l)) continue;
        }
        last = item;
        try w.print("{s}\n", .{item});
    }
}

/// The search path starts with the XDG location even when it does not exist
/// yet. Report the first directory that is actually present so the header
/// matches where the listed fonts come from.
fn displayDir(io: Io, dirs: []const []const u8) []const u8 {
    for (dirs) |dir| {
        var d = Io.Dir.cwd().openDir(io, dir, .{}) catch continue;
        d.close(io);
        return dir;
    }
    return font.primaryDir(dirs);
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(1),
        error.Reported => std.process.exit(1),
        else => {
            std.debug.print("zfiglist: {t}\n", .{err});
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    var err_buf: [16 * 1024]u8 = undefined;
    var err_file = Io.File.stderr().writer(io, &err_buf);
    const errw = &err_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const opts = parse(argv, errw) catch {
        try errw.writeAll("Try 'zfiglist --help' for more information.\n");
        try errw.flush();
        return error.Reported;
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

    // An explicitly requested directory must exist; system directories in
    // the fallback path are simply skipped when absent.
    if (opts.font_dir) |dir| {
        var d = Io.Dir.cwd().openDir(io, dir, .{}) catch |err| {
            try errw.print("zfiglist: cannot open font directory \"{s}\": {t}\n", .{ dir, err });
            try errw.flush();
            return error.Reported;
        };
        d.close(io);
    }

    // figlist's -d means "this directory"; only the implicit search path uses
    // the additional system/XDG fallbacks.
    var scan_dirs: []const []const u8 = dirs;
    if (opts.font_dir) |dir| {
        const one = try arena.alloc([]const u8, 1);
        one[0] = dir;
        scan_dirs = one;
    }
    const lists = try collect(io, arena, scan_dirs, true);

    try out.print("Default font: standard\n", .{});
    try out.print("Font directory: {s}\n", .{displayDir(io, dirs)});

    const scope = if (opts.font_dir != null) "this directory" else "search path";
    try out.print("Figlet fonts in {s}:\n", .{scope});
    if (countUnique(lists.fonts) == 0) {
        try out.print("No figlet fonts in {s}\n", .{scope});
    } else {
        try printUnique(out, lists.fonts);
    }

    try out.print("Figlet control files in {s}:\n", .{scope});
    if (countUnique(lists.controls) == 0) {
        try out.print("No figlet control files in {s}\n", .{scope});
    } else {
        try printUnique(out, lists.controls);
    }

    try out.flush();
}

const testing = std.testing;

test "zfiglist recognises plain and compressed font names" {
    try testing.expectEqualStrings("standard", fontName("standard.flf").?);
    try testing.expectEqualStrings("big", fontName("big.flf.gz").?);
    try testing.expectEqualStrings("slant", fontName("slant.flf.zip").?);
    try testing.expectEqualStrings("tiny", fontName("tiny.tlf").?);
    try testing.expect(fontName("646-ca.flc") == null);
    try testing.expect(fontName("README") == null);
    try testing.expectEqualStrings("646-ca", controlName("646-ca.flc").?);
    try testing.expect(controlName("standard.flf") == null);
}

test "zfiglist collects fonts and controls sorted and deduplicated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "gamma.flf.zip", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.flf", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.flf.gz", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "646-ca.flc", .data = "" });

    const dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/{s}",
        .{ std.testing.TmpDir.parent_dir_path, tmp.sub_path[0..] },
    );
    defer testing.allocator.free(dir);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const lists = try collect(io, arena.allocator(), &.{dir}, false);
    try testing.expectEqual(@as(usize, 3), lists.fonts.len);
    try testing.expectEqualStrings("alpha", lists.fonts[0]);
    try testing.expectEqualStrings("beta", lists.fonts[1]);
    try testing.expectEqualStrings("gamma", lists.fonts[2]);
    try testing.expectEqual(@as(usize, 1), lists.controls.len);
    try testing.expectEqualStrings("646-ca", lists.controls[0]);
}
