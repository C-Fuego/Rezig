//! Colour values, ANSI/256-colour conversion, mIRC palette mapping and the
//! `--color` spec parser.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    pub fn hex(self: Rgb) [6]u8 {
        const digits = "0123456789abcdef";
        return .{
            digits[self.r >> 4],
            digits[self.r & 0xf],
            digits[self.g >> 4],
            digits[self.g & 0xf],
            digits[self.b >> 4],
            digits[self.b & 0xf],
        };
    }
};

/// libcaca's ANSI palette (12-bit values from caca/attr.c), which is what
/// TOIlet's filters use. Index 0..7 normal, 8..15 bright.
pub const ansi16 = [16]Rgb{
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, // black
    .{ .r = 0x00, .g = 0x00, .b = 0xaa }, // blue
    .{ .r = 0x00, .g = 0xaa, .b = 0x00 }, // green
    .{ .r = 0x00, .g = 0xaa, .b = 0xaa }, // cyan
    .{ .r = 0xaa, .g = 0x00, .b = 0x00 }, // red
    .{ .r = 0xaa, .g = 0x00, .b = 0xaa }, // magenta
    .{ .r = 0xaa, .g = 0x55, .b = 0x00 }, // brown
    .{ .r = 0xaa, .g = 0xaa, .b = 0xaa }, // light grey
    .{ .r = 0x55, .g = 0x55, .b = 0x55 }, // dark grey
    .{ .r = 0x55, .g = 0x55, .b = 0xff }, // light blue
    .{ .r = 0x55, .g = 0xff, .b = 0x55 }, // light green
    .{ .r = 0x55, .g = 0xff, .b = 0xff }, // light cyan
    .{ .r = 0xff, .g = 0x55, .b = 0x55 }, // light red
    .{ .r = 0xff, .g = 0x55, .b = 0xff }, // light magenta
    .{ .r = 0xff, .g = 0xff, .b = 0x55 }, // yellow
    .{ .r = 0xff, .g = 0xff, .b = 0xff }, // white
};

/// TOIlet's rainbow filter palette, in libcaca order.
pub const rainbow_palette = [6]u8{ 13, 12, 14, 10, 11, 9 };
/// TOIlet's metal filter palette: light blue, blue, light grey, dark grey.
pub const metal_palette = [4]u8{ 9, 1, 7, 8 };

/// Standard xterm 256-colour cube quantisation (same formula as lolcat).
pub fn quantize256(c: Rgb) u8 {
    const cube = struct {
        fn idx(v: u8) u8 {
            return @intCast((@as(u16, v) * 6) / 256);
        }
    };
    return 16 + 36 * cube.idx(c.r) + 6 * cube.idx(c.g) + cube.idx(c.b);
}

fn dist2(a: Rgb, b: Rgb) u32 {
    const dr: i32 = @as(i32, a.r) - @as(i32, b.r);
    const dg: i32 = @as(i32, a.g) - @as(i32, b.g);
    const db: i32 = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

/// Nearest of the 16 ANSI colours (for the `ansi` export format).
pub fn nearest16(c: Rgb) u8 {
    var best: u8 = 0;
    var best_d: u32 = std.math.maxInt(u32);
    for (ansi16, 0..) |p, i| {
        const d = dist2(c, p);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

/// The mIRC 16-colour palette (approximate sRGB values as used by IRC clients).
pub const mirc16 = [16]Rgb{
    .{ .r = 0xff, .g = 0xff, .b = 0xff }, // 0 white
    .{ .r = 0x00, .g = 0x00, .b = 0x00 }, // 1 black
    .{ .r = 0x00, .g = 0x00, .b = 0x7f }, // 2 blue
    .{ .r = 0x00, .g = 0x93, .b = 0x00 }, // 3 green
    .{ .r = 0xff, .g = 0x00, .b = 0x00 }, // 4 red
    .{ .r = 0x7f, .g = 0x00, .b = 0x00 }, // 5 brown
    .{ .r = 0x9c, .g = 0x00, .b = 0x9c }, // 6 purple
    .{ .r = 0xfc, .g = 0x7f, .b = 0x00 }, // 7 orange
    .{ .r = 0xff, .g = 0xff, .b = 0x00 }, // 8 yellow
    .{ .r = 0x00, .g = 0xfc, .b = 0x00 }, // 9 light green
    .{ .r = 0x00, .g = 0x93, .b = 0x93 }, // 10 cyan
    .{ .r = 0x00, .g = 0xff, .b = 0xff }, // 11 light cyan
    .{ .r = 0x00, .g = 0x00, .b = 0xfc }, // 12 light blue
    .{ .r = 0xff, .g = 0x00, .b = 0xff }, // 13 pink
    .{ .r = 0x7f, .g = 0x7f, .b = 0x7f }, // 14 grey
    .{ .r = 0xd2, .g = 0xd2, .b = 0xd2 }, // 15 light grey
};

/// Exact ANSI-palette to mIRC-palette translation, used when a filter picked
/// one of libcaca's 16 colours (rainbow/metal do exactly that).
const ansi_to_mirc = [16]u8{ 1, 2, 3, 10, 4, 6, 5, 15, 14, 12, 9, 11, 4, 13, 8, 0 };

pub fn mircIndex(c: Rgb) u8 {
    for (ansi16, 0..) |p, i| {
        if (c.eql(p)) return ansi_to_mirc[i];
    }
    var best: u8 = 1;
    var best_d: u32 = std.math.maxInt(u32);
    for (mirc16, 0..) |p, i| {
        const d = dist2(c, p);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

pub const ColorSpec = union(enum) {
    none,
    palette: u8,
    rgb: Rgb,

    pub fn asRgb(self: ColorSpec) ?Rgb {
        return switch (self) {
            .none => null,
            .palette => |i| if (i < 16) ansi16[i] else cubeRgb(i),
            .rgb => |c| c,
        };
    }
};

fn cubeRgb(index: u8) Rgb {
    if (index < 16) return ansi16[index];
    if (index >= 232) {
        const v: u8 = @intCast(8 + (index - 232) * 10);
        return .{ .r = v, .g = v, .b = v };
    }
    const n = index - 16;
    const r = n / 36;
    const g = (n % 36) / 6;
    const b = n % 6;
    const conv = struct {
        fn c(v: u8) u8 {
            return if (v == 0) 0 else @intCast(55 + @as(u16, v) * 40);
        }
    };
    return .{ .r = conv.c(r), .g = conv.c(g), .b = conv.c(b) };
}

pub const ParseError = error{InvalidColor};

pub fn parseColorSpec(text_in: []const u8) ParseError!ColorSpec {
    const text = std.mem.trim(u8, text_in, " \t");
    if (text.len == 0) return error.InvalidColor;
    if (std.mem.eql(u8, text, "none") or std.mem.eql(u8, text, "never") or
        std.mem.eql(u8, text, "auto"))
        return .none;

    if (text[0] == '#') {
        return .{ .rgb = try parseHex(text[1..]) };
    }
    if (std.mem.indexOfScalar(u8, text, ',') != null) {
        var it = std.mem.splitScalar(u8, text, ',');
        var vals: [3]u8 = undefined;
        var n: usize = 0;
        while (it.next()) |part| {
            if (n == 3) return error.InvalidColor;
            vals[n] = std.fmt.parseInt(u8, std.mem.trim(u8, part, " "), 10) catch return error.InvalidColor;
            n += 1;
        }
        if (n != 3) return error.InvalidColor;
        return .{ .rgb = .{ .r = vals[0], .g = vals[1], .b = vals[2] } };
    }
    const idx = std.fmt.parseInt(u8, text, 10) catch return error.InvalidColor;
    return .{ .palette = idx };
}

fn parseHex(s: []const u8) ParseError!Rgb {
    if (s.len == 3) {
        const r = hexDigit(s[0]) catch return error.InvalidColor;
        const g = hexDigit(s[1]) catch return error.InvalidColor;
        const b = hexDigit(s[2]) catch return error.InvalidColor;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
    }
    if (s.len != 6) return error.InvalidColor;
    const r = try parseByte(s[0..2]);
    const g = try parseByte(s[2..4]);
    const b = try parseByte(s[4..6]);
    return .{ .r = r, .g = g, .b = b };
}

fn hexDigit(c: u8) !u8 {
    return std.fmt.charToDigit(c, 16);
}

fn parseByte(s: []const u8) ParseError!u8 {
    const hi = hexDigit(s[0]) catch return error.InvalidColor;
    const lo = hexDigit(s[1]) catch return error.InvalidColor;
    return hi * 16 + lo;
}

const testing = std.testing;

test "colour specs: palette, RGB hex and decimal triplets" {
    try testing.expectEqual(@as(u8, 196), (try parseColorSpec("196")).palette);
    const c = (try parseColorSpec("#ff8800")).rgb;
    try testing.expectEqual(@as(u8, 0xff), c.r);
    try testing.expectEqual(@as(u8, 0x88), c.g);
    try testing.expectEqual(@as(u8, 0), c.b);

    const c2 = (try parseColorSpec("#f80")).rgb;
    try testing.expectEqual(@as(u8, 0xff), c2.r);
    try testing.expectEqual(@as(u8, 0x88), c2.g);
    try testing.expectEqual(@as(u8, 0), c2.b);

    const c3 = (try parseColorSpec("255, 136, 0")).rgb;
    try testing.expectEqual(c, c3);
    try testing.expectError(error.InvalidColor, parseColorSpec("#zz0000"));
}

test "256-colour quantisation and mIRC mapping" {
    try testing.expectEqual(@as(u8, 196), quantize256(.{ .r = 255, .g = 0, .b = 0 }));
    // TOIlet rainbow light-magenta maps to IRC pink (13), light red to red (4).
    try testing.expectEqual(@as(u8, 13), mircIndex(ansi16[13]));
    try testing.expectEqual(@as(u8, 4), mircIndex(ansi16[12]));
    try testing.expectEqual(@as(u8, 12), mircIndex(ansi16[9]));
    try testing.expectEqual(@as(u8, 8), mircIndex(ansi16[14]));
    try testing.expectEqual(@as(u8, 9), mircIndex(ansi16[10]));
}
