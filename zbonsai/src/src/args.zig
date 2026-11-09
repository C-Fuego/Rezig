//! Command line parsing for zbonsai.
//!
//! The option set mirrors cbonsai's getopt table (short + long forms, values
//! attached (`-t0.03`, `--time=0.03`) or separate). Options that cbonsai has
//! but zbonsai deliberately omits are rejected with an explicit message rather
//! than silently ignored.
const std = @import("std");
const builtin = @import("builtin");
const term = @import("term.zig");

pub const version = "0.1.0";

pub const Allocator = std.mem.Allocator;

pub const Config = struct {
    live: bool = false,
    infinite: bool = false,
    screensaver: bool = false,
    print_tree: bool = false,
    verbose: u32 = 0,
    /// Delay between growth steps in live mode (nanoseconds).
    time_step_ns: u64 = 30_000_000,
    /// Pause between trees in infinite mode (nanoseconds).
    wait_ns: u64 = 4_000_000_000,
    base_type: u8 = 1,
    multiplier: i32 = 5,
    life_start: i32 = 32,
    seed: u64 = 0,
    seed_given: bool = false,
    message: ?[]const u8 = null,
    /// Leaf glyphs, in priority order; chosen uniformly at random.
    leaves: std.ArrayList([]const u8) = .empty,
    /// dark leaves, dark wood, light leaves, light wood
    colors: [4]u8 = .{ 2, 3, 10, 11 },

    pub fn deinit(self: *Config, gpa: Allocator) void {
        self.leaves.deinit(gpa);
    }

    pub fn leafList(self: *const Config) []const []const u8 {
        return self.leaves.items;
    }
};

pub const Result = union(enum) {
    run: Config,
    help,
    version,
};

pub const ParseError = error{ InvalidArgument, OutOfMemory };

const unsupported = [_][]const u8{ "text-origin", "geometry", "save", "load" };

fn err(comptime fmt: []const u8, args: anytype) ParseError {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "invalid argument";
    // Unit tests provoke errors on purpose; don't spam their output.
    if (builtin.is_test) return error.InvalidArgument;
    std.debug.print("zbonsai: {s}\n", .{text});
    std.debug.print("Try 'zbonsai --help' for more information.\n", .{});
    return error.InvalidArgument;
}

pub fn printHelp() void {
    const text =
        \\Usage: zbonsai [OPTION]...
        \\
        \\zbonsai is a beautifully random bonsai tree generator.
        \\
        \\Options:
        \\  -l, --live             live mode: show each step of growth
        \\  -t, --time=TIME        in live mode, wait TIME secs between steps of
        \\                           growth (must be larger than 0) [default: 0.03]
        \\  -i, --infinite         infinite mode: keep growing trees
        \\  -w, --wait=TIME        in infinite mode, wait TIME between each tree
        \\                           generation [default: 4.00]
        \\  -S, --screensaver      screensaver mode; equivalent to -li and quit on
        \\                           any keypress
        \\  -m, --message=STR      attach message next to the tree
        \\  -b, --base=INT         ascii-art plant base to use, 0 is none
        \\  -c, --leaf=LIST        list of comma-delimited strings randomly chosen
        \\                           for leaves [default: &]
        \\  -k, --color=LIST       list of 4 comma-delimited color indices (0-255) for
        \\                           each of dark leaves, dark wood, light leaves, and
        \\                           light wood, in that order [default: 2,3,10,11]
        \\  -M, --multiplier=INT   branch multiplier; higher -> more
        \\                           branching (0-20) [default: 5]
        \\  -L, --life=INT         life; higher -> more growth (0-200) [default: 32]
        \\  -p, --print            print tree to terminal when finished
        \\  -s, --seed=INT         seed random number generator
        \\  -v, --verbose          increase output verbosity
        \\  -h, --help             show help
        \\  -V, --version          show version
        \\
    ;
    term.writeAll(1, text);
}

pub fn printVersion() void {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "zbonsai {s}\n", .{version}) catch return;
    term.writeAll(1, text);
}

fn parseSeconds(value: []const u8, what: []const u8) ParseError!u64 {
    const secs = std.fmt.parseFloat(f64, value) catch
        return err("error: invalid {s}: '{s}'", .{ what, value });
    if (!(secs > 0) or std.math.isNan(secs) or secs > 1_000_000)
        return err("error: invalid {s}: '{s}'", .{ what, value });
    return @intFromFloat(secs * @as(f64, std.time.ns_per_s));
}

fn parseInt(comptime T: type, value: []const u8, what: []const u8) ParseError!T {
    return std.fmt.parseInt(T, std.mem.trim(u8, value, " \t"), 10) catch
        return err("error: invalid {s}: '{s}'", .{ what, value });
}

fn parseLeaves(gpa: Allocator, list: *std.ArrayList([]const u8), value: []const u8) ParseError!void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |token| {
        if (token.len == 0) continue;
        // A cell holds one codepoint; longer glyph strings are accepted but only
        // the first codepoint is drawn.
        try list.append(gpa, token);
        if (list.items.len >= 64) break;
    }
    if (list.items.len == 0) return err("error: no leaf glyph given", .{});
}

fn parseColors(colors: *[4]u8, value: []const u8) ParseError!void {
    var it = std.mem.splitScalar(u8, value, ',');
    var count: usize = 0;
    while (it.next()) |token| {
        if (count >= 4) return err("error: too many color indices provided", .{});
        const trimmed = std.mem.trim(u8, token, " \t");
        colors[count] = std.fmt.parseInt(u8, trimmed, 10) catch
            return err("error: invalid color index: '{s}'", .{token});
        count += 1;
    }
    if (count < 4) return err("error: too few color indices provided", .{});
}

const Applier = struct {
    cfg: *Config,
    gpa: Allocator,

    fn flag(self: *Applier, c: u8) ParseError!?Result {
        switch (c) {
            'l' => self.cfg.live = true,
            'i' => self.cfg.infinite = true,
            'S' => {
                self.cfg.screensaver = true;
                self.cfg.live = true;
                self.cfg.infinite = true;
            },
            'p' => self.cfg.print_tree = true,
            'v' => self.cfg.verbose += 1,
            'h' => return .help,
            'V' => return .version,
            else => return err("error: invalid option -- '{c}'", .{c}),
        }
        return null;
    }

    fn value(self: *Applier, c: u8, val: []const u8) ParseError!void {
        switch (c) {
            't' => self.cfg.time_step_ns = try parseSeconds(val, "step time"),
            'w' => {
                const secs = std.fmt.parseFloat(f64, val) catch
                    return err("error: invalid wait time: '{s}'", .{val});
                if (!(secs >= 0) or std.math.isNan(secs) or secs > 1_000_000)
                    return err("error: invalid wait time: '{s}'", .{val});
                self.cfg.wait_ns = @intFromFloat(secs * @as(f64, std.time.ns_per_s));
            },
            'm' => self.cfg.message = val,
            'b' => {
                const n = try parseInt(i32, val, "base index");
                if (n < 0 or n > 255) return err("error: invalid base index: '{s}'", .{val});
                self.cfg.base_type = @intCast(n);
            },
            'c' => {
                self.cfg.leaves.clearRetainingCapacity();
                try parseLeaves(self.gpa, &self.cfg.leaves, val);
            },
            'k' => try parseColors(&self.cfg.colors, val),
            'M' => {
                const n = try parseInt(i32, val, "multiplier");
                if (n < 0 or n > 20) return err("error: multiplier must be 0-20, got '{s}'", .{val});
                self.cfg.multiplier = n;
            },
            'L' => {
                const n = try parseInt(i32, val, "initial life");
                if (n < 0 or n > 200) return err("error: life must be 0-200, got '{s}'", .{val});
                self.cfg.life_start = n;
            },
            's' => {
                const n = try parseInt(u64, val, "seed");
                self.cfg.seed = n;
                self.cfg.seed_given = true;
            },
            else => return err("error: invalid option -- '{c}'", .{c}),
        }
    }

    fn takesValue(c: u8) bool {
        return switch (c) {
            't', 'w', 'm', 'b', 'c', 'k', 'M', 'L', 's' => true,
            else => false,
        };
    }

    fn longName(name: []const u8) ?u8 {
        const table = [_]struct { name: []const u8, short: u8 }{
            .{ .name = "live", .short = 'l' },
            .{ .name = "time", .short = 't' },
            .{ .name = "infinite", .short = 'i' },
            .{ .name = "wait", .short = 'w' },
            .{ .name = "screensaver", .short = 'S' },
            .{ .name = "message", .short = 'm' },
            .{ .name = "base", .short = 'b' },
            .{ .name = "leaf", .short = 'c' },
            .{ .name = "leaves", .short = 'c' },
            .{ .name = "colors", .short = 'k' },
            .{ .name = "color", .short = 'k' },
            .{ .name = "colour", .short = 'k' },
            .{ .name = "multiplier", .short = 'M' },
            .{ .name = "life", .short = 'L' },
            .{ .name = "print", .short = 'p' },
            .{ .name = "seed", .short = 's' },
            .{ .name = "verbose", .short = 'v' },
            .{ .name = "help", .short = 'h' },
            .{ .name = "version", .short = 'V' },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.short;
        }
        return null;
    }
};

/// Parse `argv` (without the program name).
pub fn parse(gpa: Allocator, argv: []const []const u8) ParseError!Result {
    var cfg: Config = .{};
    errdefer cfg.deinit(gpa);
    var applier = Applier{ .cfg = &cfg, .gpa = gpa };

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < argv.len) return err("error: unexpected argument '{s}'", .{argv[i + 1]});
            break;
        }
        if (arg.len > 2 and arg[0] == '-' and arg[1] == '-') {
            var name = arg[2..];
            var inline_value: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
                inline_value = name[eq + 1 ..];
                name = name[0..eq];
            }
            for (unsupported) |u| {
                if (std.mem.eql(u8, name, u))
                    return err("error: --{s} is not implemented in zbonsai", .{u});
            }
            const short = Applier.longName(name) orelse
                return err("error: unrecognized option '--{s}'", .{name});
            if (Applier.takesValue(short)) {
                var val = inline_value;
                if (val == null) {
                    i += 1;
                    if (i >= argv.len) return err("error: option '--{s}' requires an argument", .{name});
                    val = argv[i];
                }
                try applier.value(short, val.?);
            } else {
                if (inline_value != null)
                    return err("error: option '--{s}' doesn't allow an argument", .{name});
                if (try applier.flag(short)) |r| return r;
            }
            continue;
        }
        if (arg.len >= 2 and arg[0] == '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];
                if (Applier.takesValue(c)) {
                    var val: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        val = arg[j + 1 ..];
                    } else {
                        i += 1;
                        if (i >= argv.len) return err("error: option requires an argument -- '{c}'", .{c});
                        val = argv[i];
                    }
                    try applier.value(c, val);
                    break;
                }
                if (try applier.flag(c)) |r| return r;
            }
            continue;
        }
        // Bare words are ignored, like cbonsai (getopt leaves them alone).
    }

    if (cfg.leaves.items.len == 0) try cfg.leaves.append(gpa, "&");
    return .{ .run = cfg };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn parseArgs(gpa: Allocator, argv: []const []const u8) !Result {
    return parse(gpa, argv);
}

test "defaults match cbonsai" {
    const gpa = std.testing.allocator;
    const result = try parseArgs(gpa, &.{});
    var cfg = result.run;
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 30_000_000), cfg.time_step_ns);
    try std.testing.expectEqual(@as(u64, 4_000_000_000), cfg.wait_ns);
    try std.testing.expectEqual(@as(i32, 5), cfg.multiplier);
    try std.testing.expectEqual(@as(i32, 32), cfg.life_start);
    try std.testing.expectEqual(@as(u8, 1), cfg.base_type);
    try std.testing.expectEqual([4]u8{ 2, 3, 10, 11 }, cfg.colors);
    try std.testing.expectEqualStrings("&", cfg.leafList()[0]);
    try std.testing.expect(!cfg.live and !cfg.infinite and !cfg.print_tree);
}

test "short options, clusters and attached values" {
    const gpa = std.testing.allocator;
    const result = try parseArgs(gpa, &.{ "-li", "-t0.5", "-s", "42", "-M", "7", "-L", "64" });
    var cfg = result.run;
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.live);
    try std.testing.expect(cfg.infinite);
    try std.testing.expectEqual(@as(u64, 500_000_000), cfg.time_step_ns);
    try std.testing.expectEqual(@as(u64, 42), cfg.seed);
    try std.testing.expect(cfg.seed_given);
    try std.testing.expectEqual(@as(i32, 7), cfg.multiplier);
    try std.testing.expectEqual(@as(i32, 64), cfg.life_start);
}

test "long options with and without '='" {
    const gpa = std.testing.allocator;
    const result = try parseArgs(gpa, &.{
        "--live", "--time=0.01", "--message", "hello world", "--base=0",
        "--leaf=*,+,o", "--colors=1,2,3,4", "--seed=9", "--wait", "2.5",
    });
    var cfg = result.run;
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.live);
    try std.testing.expectEqual(@as(u64, 10_000_000), cfg.time_step_ns);
    try std.testing.expectEqualStrings("hello world", cfg.message.?);
    try std.testing.expectEqual(@as(u8, 0), cfg.base_type);
    try std.testing.expectEqual(@as(usize, 3), cfg.leaves.items.len);
    try std.testing.expectEqualStrings("+", cfg.leaves.items[1]);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, cfg.colors);
    try std.testing.expectEqual(@as(u64, 9), cfg.seed);
    try std.testing.expectEqual(@as(u64, 2_500_000_000), cfg.wait_ns);
}

test "screensaver implies live and infinite" {
    const gpa = std.testing.allocator;
    const result = try parseArgs(gpa, &.{"-S"});
    var cfg = result.run;
    defer cfg.deinit(gpa);
    try std.testing.expect(cfg.screensaver and cfg.live and cfg.infinite);
}

test "help and version" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Result.help, try parseArgs(gpa, &.{"-h"}));
    try std.testing.expectEqual(Result.version, try parseArgs(gpa, &.{"--version"}));
}

test "invalid values are rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{ "-t", "0" }));
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{"-M"}));
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{ "--multiplier=99" }));
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{ "--colors=1,2,3" }));
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{"--nope"}));
    try std.testing.expectError(error.InvalidArgument, parse(gpa, &.{"--geometry=1,2"}));
}
