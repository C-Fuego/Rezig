//! Command line parsing, plus the (rainbow printed) help and version text.
//!
//! The short options are the Ruby original's: `-p` spread, `-F` freq, `-S`
//! seed, `-a` animate, `-d` duration, `-s` speed, `-i` invert, `-t` truecolor,
//! `-f` force, `-v` version, `-h` help.

const std = @import("std");
const Io = std.Io;

pub const name = "zlolcat";
pub const version_text = "zlolcat 1.0.0 (c)2011 moe@busyloop.net";

pub const help_text =
    \\Usage: zlolcat [OPTION]... [FILE]...
    \\
    \\Concatenate FILE(s), or standard input, to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\Options:
    \\  -p, --spread=<f>      Rainbow spread (Default: 3.0)
    \\  -F, --freq=<f>        Rainbow frequency (Default: 0.1)
    \\  -S, --seed=<i>        Rainbow seed, 0 = random (Default: 0)
    \\  -a, --animate         Enable psychedelics
    \\  -d, --duration=<i>    Animation duration (Default: 12)
    \\  -s, --speed=<f>       Animation speed (Default: 20.0)
    \\  -i, --invert          Invert fg and bg
    \\  -t, --truecolor       24-bit (truecolor)
    \\  -f, --force           Force color even when stdout is not a tty
    \\  -v, --version         Print version and exit
    \\  -h, --help            Show this message
    \\
    \\Extensions:
    \\      --256                 Force the 256-colour palette
    \\      --invert-hue          Rotate the hue by half a cycle
    \\      --passthrough-color   Add no colour of our own, only copy the input
    \\      --no-color            Never colour: plain cat
    \\      --no-space-color      Do not colour spaces (they are invisible)
    \\  -D, --dialup              Random pause after every line
    \\
    \\Examples:
    \\  zlolcat f - g      Output f's contents, then stdin, then g's contents.
    \\  zlolcat            Copy standard input to standard output.
    \\  fortune | zlolcat  Display a rainbow cookie.
    \\
    \\Report zlolcat bugs to <https://github.com/busyloop/lolcat/issues>
    \\lolcat home page: <https://github.com/busyloop/lolcat/>
    \\
;

pub const Options = struct {
    seed: f64 = 0,
    spread: f64 = 3.0,
    frequency: f64 = 0.1,
    animate: bool = false,
    duration: u32 = 12,
    speed: f64 = 20.0,
    invert: bool = false,
    /// extension: rotate the hue by half a cycle
    invert_hue: bool = false,
    /// `-f/--force`: colour even when stdout is not a tty
    force_color: bool = false,
    /// extension: plain cat
    no_color: bool = false,
    truecolor: bool = false,
    /// extension: force Paint.mode = 256
    force_256: bool = false,
    /// extension: inject no colour of our own
    passthrough_color: bool = false,
    /// extension: do not spend a colour escape on a space
    no_space_color: bool = false,
    /// extension (ur0/lolcat): pause after every line
    dialup: bool = false,
    help: bool = false,
    version: bool = false,
    files: []const []const u8 = &.{},
};

pub const Error = error{ InvalidArgs, OutOfMemory };

fn invalid(errw: *Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    errw.print("{s}: " ++ fmt ++ "\n", .{name} ++ args) catch {};
    return error.InvalidArgs;
}

fn parseFloatValue(errw: *Io.Writer, opt: []const u8, text: []const u8) Error!f64 {
    return std.fmt.parseFloat(f64, text) catch
        return invalid(errw, "invalid value for '{s}': '{s}'", .{ opt, text });
}

fn parseU32Value(errw: *Io.Writer, opt: []const u8, text: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, text, 10) catch
        return invalid(errw, "invalid value for '{s}': '{s}'", .{ opt, text });
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
    if (index.* + 1 >= argv.len) {
        return invalid(errw, "option '{s}' requires an argument", .{opt});
    }
    index.* += 1;
    return argv[index.*];
}

pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const [:0]const u8,
    errw: *Io.Writer,
) Error!Options {
    var opts = Options{};
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(allocator);

    var i: usize = 1;
    var only_files = false;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];

        if (only_files) {
            try files.append(allocator, arg);
            continue;
        }
        if (eq(arg, "--")) {
            only_files = true;
            continue;
        }

        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            const body = arg[2..];
            const eq_pos = std.mem.indexOfScalar(u8, body, '=');
            const key = if (eq_pos) |p| body[0..p] else body;
            const inline_value: ?[]const u8 = if (eq_pos) |p| body[p + 1 ..] else null;

            if (eq(key, "help")) {
                opts.help = true;
            } else if (eq(key, "version")) {
                opts.version = true;
            } else if (eq(key, "animate")) {
                opts.animate = true;
            } else if (eq(key, "invert")) {
                opts.invert = true;
            } else if (eq(key, "invert-hue")) {
                opts.invert_hue = true;
            } else if (eq(key, "force") or eq(key, "force-color")) {
                opts.force_color = true;
            } else if (eq(key, "no-color")) {
                opts.no_color = true;
            } else if (eq(key, "truecolor")) {
                opts.truecolor = true;
            } else if (eq(key, "256") or eq(key, "color256")) {
                opts.force_256 = true;
            } else if (eq(key, "passthrough-color") or eq(key, "passthrough")) {
                opts.passthrough_color = true;
            } else if (eq(key, "no-space-color") or eq(key, "no-space")) {
                opts.no_space_color = true;
            } else if (eq(key, "dialup")) {
                opts.dialup = true;
            } else if (eq(key, "seed")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--seed");
                opts.seed = try parseFloatValue(errw, "--seed", v);
            } else if (eq(key, "spread")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--spread");
                opts.spread = try parseFloatValue(errw, "--spread", v);
            } else if (eq(key, "frequency") or eq(key, "freq")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--frequency");
                opts.frequency = try parseFloatValue(errw, "--frequency", v);
            } else if (eq(key, "duration")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--duration");
                opts.duration = try parseU32Value(errw, "--duration", v);
            } else if (eq(key, "speed")) {
                const v = try nextValue(inline_value, argv, &i, errw, "--speed");
                opts.speed = try parseFloatValue(errw, "--speed", v);
            } else {
                return invalid(errw, "unknown option '--{s}'", .{key});
            }
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                const rest: []const u8 = arg[j + 1 ..];
                switch (c) {
                    // value options take the rest of the token, or the next argument
                    'p', 'F', 'S', 's', 'd' => {
                        const inline_value: ?[]const u8 = if (rest.len > 0) rest else null;
                        const label: []const u8 = switch (c) {
                            'p' => "-p/--spread",
                            'F' => "-F/--freq",
                            'S' => "-S/--seed",
                            's' => "-s/--speed",
                            else => "-d/--duration",
                        };
                        const v = try nextValue(inline_value, argv, &i, errw, label);
                        switch (c) {
                            'p' => opts.spread = try parseFloatValue(errw, label, v),
                            'F' => opts.frequency = try parseFloatValue(errw, label, v),
                            'S' => opts.seed = try parseFloatValue(errw, label, v),
                            's' => opts.speed = try parseFloatValue(errw, label, v),
                            else => opts.duration = try parseU32Value(errw, label, v),
                        }
                        break; // the whole token is consumed
                    },
                    'a' => opts.animate = true,
                    'i' => opts.invert = true,
                    't' => opts.truecolor = true,
                    'f' => opts.force_color = true,
                    'D' => opts.dialup = true,
                    'h' => opts.help = true,
                    'v' => opts.version = true,
                    else => return invalid(errw, "unknown option '-{c}'", .{c}),
                }
            }
            continue;
        }

        try files.append(allocator, arg);
    }

    // `p.die :spread, "must be >= 0.1"` and friends
    if (opts.spread < 0.1) return invalid(errw, "spread must be >= 0.1", .{});
    if (opts.speed < 0.1) return invalid(errw, "speed must be >= 0.1", .{});
    if (opts.duration < 1) return invalid(errw, "duration must be >= 0.1", .{});

    if (files.items.len > 0) opts.files = try files.toOwnedSlice(allocator);
    return opts;
}

const testing = std.testing;

test "parses the lolcat style flags" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const argv = [_][:0]const u8{
        "zlolcat", "-p", "1", "-F", "0.5", "-S", "42", "-s", "60", "-d", "3", "-a", "-i", "-t", "-f", "file.txt",
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const opts = try parse(arena.allocator(), &argv, &w);
    try testing.expectEqual(@as(f64, 1.0), opts.spread);
    try testing.expectEqual(@as(f64, 0.5), opts.frequency);
    try testing.expectEqual(@as(f64, 42.0), opts.seed);
    try testing.expectEqual(@as(f64, 60.0), opts.speed);
    try testing.expectEqual(@as(u32, 3), opts.duration);
    try testing.expect(opts.animate);
    try testing.expect(opts.invert);
    try testing.expect(opts.truecolor);
    try testing.expect(opts.force_color);
    try testing.expectEqual(@as(usize, 1), opts.files.len);
    try testing.expectEqualStrings("file.txt", opts.files[0]);
}

test "attached values and --opt=value both work" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "zlolcat", "-p1.5", "--seed=7", "--speed", "5", "-" };
    const o = try parse(arena.allocator(), &argv, &w);
    try testing.expectEqual(@as(f64, 1.5), o.spread);
    try testing.expectEqual(@as(f64, 7.0), o.seed);
    try testing.expectEqual(@as(f64, 5.0), o.speed);
    try testing.expectEqualStrings("-", o.files[0]);
}

test "unknown options and bad values are rejected" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad1 = [_][:0]const u8{ "zlolcat", "--nope" };
    try testing.expectError(error.InvalidArgs, parse(arena.allocator(), &bad1, &w));
    const bad2 = [_][:0]const u8{ "zlolcat", "-p", "0.01" };
    try testing.expectError(error.InvalidArgs, parse(arena.allocator(), &bad2, &w));
    const bad3 = [_][:0]const u8{ "zlolcat", "--seed", "abc" };
    try testing.expectError(error.InvalidArgs, parse(arena.allocator(), &bad3, &w));
}

test "--no-space-color is opt-in" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const plain = [_][:0]const u8{"zlolcat"};
    try testing.expect(!(try parse(arena.allocator(), &plain, &w)).no_space_color);

    const on = [_][:0]const u8{ "zlolcat", "--no-space-color" };
    try testing.expect((try parse(arena.allocator(), &on, &w)).no_space_color);
}
