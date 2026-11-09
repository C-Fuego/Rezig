//! `Lol.rainbow` and the two output modes, straight from the Ruby original:
//!
//!     def self.rainbow(freq, i)
//!        red   = Math.sin(freq*i + 0) * 127 + 128
//!        green = Math.sin(freq*i + 2*Math::PI/3) * 127 + 128
//!        blue  = Math.sin(freq*i + 4*Math::PI/3) * 127 + 128
//!        "#%02X%02X%02X" % [ red, green, blue ]
//!     end
//!
//! `i` is `os + index/spread`: the line offset plus the character index inside
//! the line divided by the spread.  `%02X` truncates the float towards zero,
//! which is what `@intFromFloat` does.
//!
//! `Paint.color(...)` turns that "#RRGGBB" into `\e[38;2;r;g;bm` when the Paint
//! mode is 24-bit, and into `\e[38;5;Nm` (nearest entry of the xterm-256
//! palette) otherwise.  `-t` forces the former; without it the mode follows
//! `$COLORTERM`, exactly like `Lol.set_mode`.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Mode = enum {
    /// Paint.mode = 0xffffff
    truecolor,
    /// Paint.mode = 256
    ansi256,
};

/// `rainbow(freq, i)`: i is `os + index/spread`.
pub fn rgbAt(i: f64, frequency: f64, invert_hue: bool) Rgb {
    var angle = frequency * i;
    if (invert_hue) angle += std.math.pi; // extension: complementary colours
    return .{
        .r = channel(std.math.sin(angle)),
        // the phases are written the way Ruby multiplies them, so that the
        // floating point values (and therefore the truncated bytes) match
        .g = channel(std.math.sin(angle + phase_g)),
        .b = channel(std.math.sin(angle + phase_b)),
    };
}

/// The two extra phases of `rainbow`, as named constants so that every path
/// adds exactly the same numbers: `2 * pi / 3` and `4 * pi / 3`.
const phase_g: f64 = 2.0 * std.math.pi / 3.0;
const phase_b: f64 = 4.0 * std.math.pi / 3.0;

/// `sin(2pi/3)`, `cos(2pi/3)`, `sin(4pi/3)`, `cos(4pi/3)`: the constants the
/// fast path expands `sin(angle + phase)` with.
const sin_g: f64 = @sin(phase_g);
const cos_g: f64 = @cos(phase_g);
const sin_b: f64 = @sin(phase_b);
const cos_b: f64 = @cos(phase_b);

/// `sin()` (-1..1) mapped to a byte, truncated like `%02X`.
inline fn channel(s: f64) u8 {
    const v = s * 127.0 + 128.0;
    return @intFromFloat(std.math.clamp(v, 0.0, 255.0));
}

/// Where the value of a channel may sit before the byte it truncates to can
/// change.  The rotation below is off the exact `sin()` by far less than this
/// (see `Rainbow`), so a value closer than `guard` to the next integer - or to
/// the 0/255 clamp - is recomputed the slow, bit-exact way.
const guard = 1e-4;

/// One line's worth of `rainbow(opts[:freq], os + index/spread)`, advanced one
/// character at a time.
///
/// The angles of a line are `angle + k * (freq/spread)`, an arithmetic
/// progression, so the sine and cosine of the next character are one rotation
/// away:
///
///     sin(a + d) = sin(a)cos(d) + cos(a)sin(d)
///     cos(a + d) = cos(a)cos(d) - sin(a)sin(d)
///
/// That is five floating point operations and one `sin`/`cos` pair per *64*
/// characters instead of three libm `sin` calls per character (which is what
/// `rgbAt` costs, and what dominated the profile of a cmatrix stream).  The
/// three channels come from the same (sin, cos) pair through the phase
/// identities `sin(a+p) = sin(a)cos(p) + cos(a)sin(p)`.
///
/// The result is not the same float as `rgbAt` - it is a few ULP away, and the
/// distance grows with the number of rotations since the anchor - so every
/// channel is checked against `guard` before it is truncated to a byte:
/// whenever the value is close enough to a truncation boundary to be at risk,
/// the exact `sin()` is evaluated for that channel.  With an anchor every 64
/// characters the accumulated error stays below 1e-9 of a byte step even for
/// absurdly long lines, i.e. 100000x under the guard, so the bytes printed are
/// the ones `rgbAt` prints.
pub const Rainbow = struct {
    frequency: f64,
    spread: f64,
    shift: f64,
    invert_hue: bool,
    os: f64,

    /// angle advance per character: `freq/spread`
    step: f64,
    cos_step: f64,
    sin_step: f64,

    /// `sin`/`cos` of the angle of character `index`
    s: f64,
    c: f64,
    index: usize,
    /// character the rotation state above was computed for exactly
    anchor: usize,
    /// false when the angle is not finite (spread 0, NaN options): then every
    /// character goes through `rgbAt`, as before
    fast: bool,

    /// characters per exact `sin`/`cos` pair
    const anchor_every = 64;

    pub fn init(frequency: f64, spread: f64, invert_hue: bool, os: f64) Rainbow {
        const step = frequency / spread;
        var self: Rainbow = .{
            .frequency = frequency,
            .spread = spread,
            .shift = if (invert_hue) std.math.pi else 0,
            .invert_hue = invert_hue,
            .os = os,
            .step = step,
            .cos_step = 0,
            .sin_step = 0,
            .s = 0,
            .c = 0,
            .index = 0,
            .anchor = 0,
            .fast = std.math.isFinite(step) and spread != 0,
        };
        if (self.fast) {
            self.cos_step = @cos(step);
            self.sin_step = @sin(step);
            self.anchorAt(0);
        }
        return self;
    }

    /// `rgbAt` for the next character of the line.
    pub fn next(self: *Rainbow) Rgb {
        if (!self.fast) {
            const i = self.os + @as(f64, @floatFromInt(self.index)) / self.spread;
            self.index += 1;
            return rgbAt(i, self.frequency, self.invert_hue);
        }
        if (self.index - self.anchor >= anchor_every) self.anchorAt(self.index);

        const s = self.s;
        const c = self.c;
        // sin(angle + phase) for the three channels
        const sines = [3]f64{ s, s * cos_g + c * sin_g, s * cos_b + c * sin_b };
        var rgb: Rgb = undefined;
        inline for (0..3) |k| {
            const v = sines[k] * 127.0 + 128.0;
            const frac = v - @floor(v);
            // too close to a truncation boundary: ask `sin()` itself
            const byte: u8 = if (frac < guard or frac > 1.0 - guard)
                self.exactChannel(k)
            else
                @intFromFloat(std.math.clamp(v, 0.0, 255.0));
            switch (k) {
                0 => rgb.r = byte,
                1 => rgb.g = byte,
                else => rgb.b = byte,
            }
        }

        // rotate to the next character
        self.s = s * self.cos_step + c * self.sin_step;
        self.c = c * self.cos_step - s * self.sin_step;
        self.index += 1;
        return rgb;
    }

    /// Bit-exact `channel()` of one channel for the current character.
    fn exactChannel(self: *Rainbow, comptime k: usize) u8 {
        const i = self.os + @as(f64, @floatFromInt(self.index)) / self.spread;
        const angle = self.frequency * i + self.shift;
        const phase = switch (k) {
            0 => 0.0,
            1 => phase_g,
            else => phase_b,
        };
        return channel(@sin(angle + phase));
    }

    fn anchorAt(self: *Rainbow, index: usize) void {
        const i = self.os + @as(f64, @floatFromInt(index)) / self.spread;
        const angle = self.frequency * i + self.shift;
        if (!std.math.isFinite(angle)) {
            self.fast = false;
            return;
        }
        self.s = @sin(angle);
        self.c = @cos(angle);
        self.index = index;
        self.anchor = index;
    }
};

/// The 16 system colours of the xterm palette.
const system_colors = [16][3]u8{
    .{ 0, 0, 0 },       .{ 128, 0, 0 },   .{ 0, 128, 0 },   .{ 128, 128, 0 },
    .{ 0, 0, 128 },     .{ 128, 0, 128 }, .{ 0, 128, 128 }, .{ 192, 192, 192 },
    .{ 128, 128, 128 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
    .{ 0, 0, 255 },     .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
};

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

fn palette(i: u8) [3]u8 {
    if (i < 16) return system_colors[i];
    if (i < 232) {
        const n = i - 16;
        return .{ cube_levels[n / 36], cube_levels[(n / 6) % 6], cube_levels[n % 6] };
    }
    const v: u8 = @intCast(8 + 10 * (i - 232));
    return .{ v, v, v };
}

/// Nearest xterm-256 palette entry, Euclidean distance in RGB, lowest index on
/// a tie - the way Paint picks a colour for a 24-bit value.
///
/// The palette has three regions with a fixed index order (0..15 system,
/// 16..231 cube, 232..255 greys), and the distance to each of them can be
/// minimised without walking 256 entries: the cube's distance is separable per
/// channel, and the greys form a one-dimensional quadratic whose vertex is the
/// mean of the channels.  Both are still exact - the entry this returns is
/// byte for byte the one the flat scan returns, tie-breaks included - see the
/// tests, which compare it against `quantize256Scan` over the whole grey and
/// cube boundary neighbourhoods.
pub fn quantize256(color: Rgb) u8 {
    var best: u8 = 0;
    var best_dist: i32 = std.math.maxInt(i32);

    // 0..15: the system colours, in index order
    for (system_colors, 0..) |entry, i| {
        const dist = distance(entry, color);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(i);
        }
    }

    // 16..231: the cube.  Each channel contributes its own squared distance, so
    // every entry with the minimum total is built from the per-channel
    // minimum, and the first of those in scan order is the one with the
    // smallest level index per channel.
    const cr = nearestLevel(color.r);
    const cg = nearestLevel(color.g);
    const cb = nearestLevel(color.b);
    const cube_dist = cr.dist + cg.dist + cb.dist;
    if (cube_dist < best_dist) {
        best_dist = cube_dist;
        best = 16 + 36 * cr.index + 6 * cg.index + cb.index;
    }

    // 232..255: the greys, 8 + 10k.  The distance is 3(v - mean)^2 + const, so
    // the nearest grey level to the mean wins (lowest k on a tie).
    const sum: i32 = @as(i32, color.r) + @as(i32, color.g) + @as(i32, color.b);
    const t = sum - 3 * 8; // 3 * (v - 8) with v = 8 + 10k is 30k
    var k: i32 = if (t <= 0) 0 else @divTrunc(t + 14, 30); // ties towards the lower level
    if (k > 23) k = 23;
    const grey: u8 = @intCast(8 + 10 * k);
    const grey_dist = distance(.{ grey, grey, grey }, color);
    if (grey_dist < best_dist) {
        best_dist = grey_dist;
        best = @intCast(232 + k);
    }

    return best;
}

fn distance(entry: [3]u8, color: Rgb) i32 {
    const dr = @as(i32, entry[0]) - @as(i32, color.r);
    const dg = @as(i32, entry[1]) - @as(i32, color.g);
    const db = @as(i32, entry[2]) - @as(i32, color.b);
    return dr * dr + dg * dg + db * db;
}

/// Nearest entry of `cube_levels`, lowest level on a tie.
const Level = struct {
    index: u8,
    dist: i32,
};

fn nearestLevel(v: u8) Level {
    // -1..255, the midpoints between 0, 95, 135, 175, 215 and 255
    const index: u8 = if (v <= 47)
        0
    else if (v <= 115)
        1
    else if (v <= 155)
        2
    else if (v <= 195)
        3
    else if (v <= 235)
        4
    else
        5;
    const d = @as(i32, cube_levels[index]) - @as(i32, v);
    return .{ .index = index, .dist = d * d };
}

/// The plain scan `quantize256` used to do, kept as the reference the fast
/// version is tested against.
pub fn quantize256Scan(color: Rgb) u8 {
    var best: u8 = 0;
    var best_dist: i32 = std.math.maxInt(i32);
    var i: u8 = 0;
    while (true) : (i += 1) {
        const dist = distance(palette(i), color);
        if (dist < best_dist) {
            best_dist = dist;
            best = i;
        }
        if (i == 255) break;
    }
    return best;
}

/// `Lol.set_mode`: `%w[truecolor 24bit].include?(ENV['COLORTERM'])` selects
/// 24-bit, everything else 256 colours; `-t` forces 24-bit.
pub fn detectMode(colorterm: ?[]const u8, force_truecolor: bool, force_256: bool) Mode {
    if (force_256) return .ansi256;
    if (force_truecolor) return .truecolor;
    if (colorterm) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return .truecolor;
    }
    return .ansi256;
}

const testing = std.testing;

test "rainbow at i = 0 matches the Ruby reference bytes" {
    const c = rgbAt(0.0, 1.0, false);
    try testing.expectEqual(@as(u8, 128), c.r);
    try testing.expectEqual(@as(u8, 237), c.g);
    try testing.expectEqual(@as(u8, 18), c.b);
}

test "the hue advances freq/spread per character and freq per line" {
    // rainbow(freq, os + i/spread): one character is a step of 1/spread in `i`
    const freq = 0.1;
    const spread = 3.0;
    const a = rgbAt(7.0 + 0.0 / spread, freq, false);
    const b = rgbAt(7.0 + 1.0 / spread, freq, false);
    const c = rgbAt(7.0 + 2.0 / spread, freq, false);
    try testing.expect(!a.eql(b));
    try testing.expect(!b.eql(c));
}

test "invert-hue rotates by half a cycle" {
    const c = rgbAt(0.0, 1.0, false);
    const inv = rgbAt(0.0, 1.0, true);
    try testing.expectEqual(c.g, inv.b);
    try testing.expectEqual(c.b, inv.g);
}

test "256 colours land on the nearest palette entry" {
    try testing.expectEqual(@as(u8, 0), quantize256(.{ .r = 0, .g = 0, .b = 0 }));
    try testing.expectEqual(@as(u8, 15), quantize256(.{ .r = 255, .g = 255, .b = 255 }));
    try testing.expectEqual(@as(u8, 9), quantize256(.{ .r = 255, .g = 0, .b = 0 }));
    try testing.expectEqual(@as(u8, 10), quantize256(.{ .r = 0, .g = 255, .b = 0 }));
    try testing.expectEqual(@as(u8, 12), quantize256(.{ .r = 0, .g = 0, .b = 255 }));
    // exact cube and grey entries win outright
    try testing.expectEqual(@as(u8, 59), quantize256(.{ .r = 95, .g = 95, .b = 95 }));
    try testing.expectEqual(@as(u8, 232), quantize256(.{ .r = 8, .g = 8, .b = 8 }));
    try testing.expectEqual(@as(u8, 255), quantize256(.{ .r = 238, .g = 238, .b = 238 }));
}

test "colour depth detection follows COLORTERM" {
    try testing.expectEqual(Mode.truecolor, detectMode("truecolor", false, false));
    try testing.expectEqual(Mode.truecolor, detectMode("24bit", false, false));
    try testing.expectEqual(Mode.ansi256, detectMode(null, false, false));
    try testing.expectEqual(Mode.ansi256, detectMode("xterm-256color", false, false));
    // the Ruby test is an exact membership test, not a substring search
    try testing.expectEqual(Mode.ansi256, detectMode("TrueColor", false, false));
    try testing.expectEqual(Mode.truecolor, detectMode(null, true, false));
    try testing.expectEqual(Mode.ansi256, detectMode("truecolor", false, true));
}

test "the rotating rainbow prints exactly what rgbAt prints" {
    // lines longer than one anchor interval, several hues per character, and
    // the extremes of the option range: every byte has to match, otherwise the
    // speed-up is not allowed
    const spreads = [_]f64{ 3.0, 1.0, 0.5, 7.3, 0.1 };
    const freqs = [_]f64{ 0.1, 0.9, 0.42, 0.0, 2.5 };
    const seeds = [_]f64{ 1, 3, 7, 255, 0, 1024, 97 };
    for (spreads) |spread| {
        for (freqs) |freq| {
            for (seeds) |os| {
                inline for (.{ false, true }) |invert_hue| {
                    var rainbow = Rainbow.init(freq, spread, invert_hue, os);
                    var k: usize = 0;
                    while (k < 300) : (k += 1) {
                        const i = os + @as(f64, @floatFromInt(k)) / spread;
                        const want = rgbAt(i, freq, invert_hue);
                        const got = rainbow.next();
                        if (!want.eql(got)) {
                            std.debug.print("i={d} freq={d} spread={d} hue={} want=({d},{d},{d}) got=({d},{d},{d})\n", .{
                                i, freq, spread, invert_hue, want.r, want.g, want.b, got.r, got.g, got.b,
                            });
                            return error.TestUnexpectedResult;
                        }
                    }
                }
            }
        }
    }
}

test "the rotation stays exact on a very long line" {
    // `filtered.length/spread` can only grow @os by a whole line, but a block
    // without a newline lets a single line be arbitrarily long: keep rotating
    // for 200k characters and check every byte
    var rainbow = Rainbow.init(0.1, 3.0, false, 5);
    var k: usize = 0;
    while (k < 200_000) : (k += 1) {
        const want = rgbAt(5 + @as(f64, @floatFromInt(k)) / 3.0, 0.1, false);
        const got = rainbow.next();
        if (!want.eql(got)) return error.TestUnexpectedResult;
    }
}

test "the fractional-angle options still go through rgbAt" {
    // spread 0 / non-finite options cannot be rotated: they take the old path
    inline for (.{ 0.0, -0.0 }) |spread| {
        const rainbow = Rainbow.init(1.0, spread, false, 1);
        try testing.expect(!rainbow.fast);
    }
    var nan = Rainbow.init(1.0, 1.0, false, std.math.nan(f64));
    _ = nan.next();
    try testing.expect(!nan.fast);
}

test "the fast 256 colour quantiser agrees with the flat scan" {
    // the grey axis, every cube/grey boundary and its neighbourhoods, then a
    // deterministic sweep: this is the whole risk surface of the closed forms
    const levels = [_]u8{
        0, 1, 46, 47, 48, 49, 94, 95, 96, 114, 115, 116, 117,
        134, 135, 136, 154, 155, 156, 174, 175, 176, 194, 195, 196,
        214, 215, 216, 234, 235, 236, 254, 255,
    };
    for (0..256) |v| {
        const c = Rgb{ .r = @intCast(v), .g = @intCast(v), .b = @intCast(v) };
        try testing.expectEqual(quantize256Scan(c), quantize256(c));
    }
    for (levels) |g| {
        for (levels) |b| {
            var r: usize = 0;
            while (r < 256) : (r += 1) {
                const c = Rgb{ .r = @intCast(r), .g = g, .b = b };
                try testing.expectEqual(quantize256Scan(c), quantize256(c));
            }
        }
    }
    // a fixed pseudo-random sweep over the whole cube
    var state: u32 = 0x12345678;
    var n: usize = 0;
    while (n < 20_000) : (n += 1) {
        state = state *% 1664525 +% 1013904223;
        const c = Rgb{
            .r = @truncate(state),
            .g = @truncate(state >> 8),
            .b = @truncate(state >> 16),
        };
        try testing.expectEqual(quantize256Scan(c), quantize256(c));
    }
}
