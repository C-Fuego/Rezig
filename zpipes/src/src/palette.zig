const std = @import("std");

/// 调色板大小。8/16 使用经典 ANSI 颜色，88/256 使用扩展色号。
pub const Mode = enum(u16) {
    c8 = 8,
    c16 = 16,
    c88 = 88,
    c256 = 256,
};

/// 颜色来源模式。
pub const ColorMode = enum {
    ansi,
    rgb,
    none,
};

pub const Theme = enum {
    default,
    darker,
    pastel,
    matrix,
};

pub const Kind = enum {
    none,
    ansi,
    rgb,
};

/// 一个实际要被渲染的颜色。
pub const Color = struct {
    kind: Kind = .none,
    index: u8 = 0,
    mode: Mode = .c8,
    custom: bool = false,
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    bold: bool = false,
};

pub const AnsiRange = struct {
    lo: u8,
    hi: u8,
};

/// RGB 主题的 HSV 取色范围（H 0-360，S/V 0-1）。
pub const RgbRange = struct {
    hue_lo: f32,
    hue_hi: f32,
    sat_lo: f32,
    sat_hi: f32,
    val_lo: f32,
    val_hi: f32,
};

pub fn parseMode(s: []const u8) !Mode {
    if (std.mem.eql(u8, s, "8")) return .c8;
    if (std.mem.eql(u8, s, "16")) return .c16;
    if (std.mem.eql(u8, s, "88")) return .c88;
    if (std.mem.eql(u8, s, "256")) return .c256;
    return error.InvalidMode;
}

pub fn parseColorMode(s: []const u8) !ColorMode {
    if (std.mem.eql(u8, s, "ansi")) return .ansi;
    if (std.mem.eql(u8, s, "rgb")) return .rgb;
    if (std.mem.eql(u8, s, "none")) return .none;
    return error.InvalidColorMode;
}

pub fn parseTheme(s: []const u8) !Theme {
    if (std.mem.eql(u8, s, "default")) return .default;
    if (std.mem.eql(u8, s, "darker")) return .darker;
    if (std.mem.eql(u8, s, "pastel")) return .pastel;
    if (std.mem.eql(u8, s, "matrix")) return .matrix;
    return error.InvalidTheme;
}

/// 各主题在给定调色板下使用的 ANSI 色号范围。
pub fn themeAnsiRange(theme: Theme, mode: Mode) AnsiRange {
    return switch (theme) {
        .default => switch (mode) {
            .c8 => .{ .lo = 1, .hi = 7 },
            .c16 => .{ .lo = 1, .hi = 15 },
            .c88 => .{ .lo = 16, .hi = 87 },
            .c256 => .{ .lo = 16, .hi = 255 },
        },
        .darker => switch (mode) {
            .c8 => .{ .lo = 1, .hi = 6 },
            .c16 => .{ .lo = 1, .hi = 7 },
            .c88 => .{ .lo = 16, .hi = 31 },
            .c256 => .{ .lo = 16, .hi = 51 },
        },
        .pastel => switch (mode) {
            .c8 => .{ .lo = 1, .hi = 7 },
            .c16 => .{ .lo = 9, .hi = 15 },
            .c88 => .{ .lo = 64, .hi = 79 },
            .c256 => .{ .lo = 153, .hi = 231 },
        },
        .matrix => switch (mode) {
            .c8 => .{ .lo = 2, .hi = 2 },
            .c16 => .{ .lo = 2, .hi = 10 },
            .c88 => .{ .lo = 28, .hi = 47 },
            .c256 => .{ .lo = 22, .hi = 226 },
        },
    };
}

const matrix_c8 = [_]u8{2};
const matrix_c16 = [_]u8{ 2, 10 };
const matrix_c88 = [_]u8{ 28, 29, 30, 31, 44, 45, 46, 47 };
const matrix_c256 = [_]u8{ 22, 28, 34, 40, 46, 82, 118, 154, 190, 226 };

/// matrix 主题的绿色系离散色号。
pub fn matrixIndexes(mode: Mode) []const u8 {
    return switch (mode) {
        .c8 => &matrix_c8,
        .c16 => &matrix_c16,
        .c88 => &matrix_c88,
        .c256 => &matrix_c256,
    };
}

pub fn themeRgbRange(theme: Theme) RgbRange {
    return switch (theme) {
        .default => .{ .hue_lo = 0, .hue_hi = 360, .sat_lo = 0.55, .sat_hi = 1.0, .val_lo = 0.75, .val_hi = 1.0 },
        .darker => .{ .hue_lo = 0, .hue_hi = 360, .sat_lo = 0.45, .sat_hi = 0.90, .val_lo = 0.30, .val_hi = 0.60 },
        .pastel => .{ .hue_lo = 0, .hue_hi = 360, .sat_lo = 0.25, .sat_hi = 0.55, .val_lo = 0.85, .val_hi = 1.0 },
        .matrix => .{ .hue_lo = 100, .hue_hi = 140, .sat_lo = 0.55, .sat_hi = 1.0, .val_lo = 0.45, .val_hi = 1.0 },
    };
}

fn toByte(v: f32) u8 {
    const clamped = @min(@max(v, 0.0), 1.0);
    return @intFromFloat(clamped * 255.0 + 0.5);
}

fn hsvToRgb(hue: f32, sat: f32, val: f32) Color {
    // hue 先归一化到 [0, 360)，再映射到 6 个扇区。
    var h = hue - @floor(hue / 360.0) * 360.0;
    if (h < 0.0) h += 360.0;
    const hh = h / 60.0;
    const sector: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = val * (1.0 - sat);
    const q = val * (1.0 - sat * f);
    const t = val * (1.0 - sat * (1.0 - f));

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    switch (sector) {
        0 => {
            r = val;
            g = t;
            b = p;
        },
        1 => {
            r = q;
            g = val;
            b = p;
        },
        2 => {
            r = p;
            g = val;
            b = t;
        },
        3 => {
            r = p;
            g = q;
            b = val;
        },
        4 => {
            r = t;
            g = p;
            b = val;
        },
        else => {
            r = val;
            g = p;
            b = q;
        },
    }

    return .{ .kind = .rgb, .r = toByte(r), .g = toByte(g), .b = toByte(b) };
}

fn rgbToHsv(c: Color) struct { h: f32, s: f32, v: f32 } {
    const r = @as(f32, @floatFromInt(c.r)) / 255.0;
    const g = @as(f32, @floatFromInt(c.g)) / 255.0;
    const b = @as(f32, @floatFromInt(c.b)) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const d = max - min;

    var h: f32 = 0;
    if (d != 0) {
        if (max == r) {
            h = 60.0 * ((g - b) / d);
            if (h < 0) h += 360.0;
        } else if (max == g) {
            h = 60.0 * ((b - r) / d + 2.0);
        } else {
            h = 60.0 * ((r - g) / d + 4.0);
        }
    }
    const s = if (max == 0) 0 else d / max;
    return .{ .h = h, .s = s, .v = max };
}

/// 只对 RGB 颜色做色相旋转，用于 --rainbow。
pub fn rotateHue(c: Color, degrees: u8) Color {
    if (c.kind != .rgb or degrees == 0) return c;
    const hsv = rgbToHsv(c);
    var nc = hsvToRgb(hsv.h + @as(f32, @floatFromInt(degrees)), hsv.s, hsv.v);
    nc.bold = c.bold;
    return nc;
}

fn randomRgb(theme: Theme, rng: std.Random) Color {
    const r = themeRgbRange(theme);
    const hue = r.hue_lo + rng.float(f32) * (r.hue_hi - r.hue_lo);
    const sat = r.sat_lo + rng.float(f32) * (r.sat_hi - r.sat_lo);
    const val = r.val_lo + rng.float(f32) * (r.val_hi - r.val_lo);
    return hsvToRgb(hue, sat, val);
}

fn randomAnsi(theme: Theme, mode: Mode, rng: std.Random) u8 {
    if (theme == .matrix) {
        const list = matrixIndexes(mode);
        return list[rng.uintLessThan(usize, list.len)];
    }
    const range = themeAnsiRange(theme, mode);
    return rng.intRangeAtMost(u8, range.lo, range.hi);
}

/// 颜色来源：没有 -c 时按颜色模式/主题取色；有 -c 时按列表轮换。
pub const Colors = struct {
    color_mode: ColorMode = .ansi,
    palette: Mode = .c8,
    theme: Theme = .default,
    // pipes.sh 默认 BOLD=1，不亮就跟原版差一截。
    bold: bool = true,
    explicit: [256]u8 = @splat(0),
    explicit_len: usize = 0,
    next_explicit: usize = 0,
    // pipes.sh 初始化时颜色是"随机起点 + 依次递增"，不是各自随机。
    cycle_pos: usize = 0,
    cycle_started: bool = false,

    /// pipes.sh 的默认配色表 C=(1 2 3 4 5 6 7 0)，含 0 号黑。
    const default_cycle = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 0 };

    fn list(self: *const Colors) []const u8 {
        if (self.explicit_len > 0) return self.explicit[0..self.explicit_len];
        return &default_cycle;
    }

    /// 是否走 pipes.sh 那套"8 色固定表"的取色逻辑。
    /// 用了主题、88/256 扩展色或 RGB 时仍走原来的随机取色。
    fn usesClassicList(self: *const Colors) bool {
        return self.color_mode == .ansi and self.theme == .default and self.palette == .c8;
    }

    fn makeAnsi(self: *const Colors, index: u8) Color {
        return .{
            .kind = .ansi,
            .index = index,
            .mode = self.palette,
            .custom = self.explicit_len > 0,
            .bold = self.bold,
        };
    }

    /// pipes.sh 的 init_pipes：起点随机，之后沿列表顺序循环。
    pub fn cycle(self: *Colors, rng: std.Random) Color {
        if (!self.usesClassicList()) return self.pick(rng);
        const l = self.list();
        if (l.len == 0) return .{ .kind = .none, .bold = self.bold };
        if (!self.cycle_started) {
            self.cycle_pos = rng.uintLessThan(usize, l.len);
            self.cycle_started = true;
        }
        const idx = l[self.cycle_pos % l.len];
        self.cycle_pos = (self.cycle_pos + 1) % l.len;
        return self.makeAnsi(idx);
    }

    /// pipes.sh 的 `CN * RANDOM / M`：从当前配色列表里随机挑一个。
    pub fn pick(self: *Colors, rng: std.Random) Color {
        switch (self.color_mode) {
            .none => return .{ .kind = .none, .bold = self.bold },
            .rgb => {
                var c = randomRgb(self.theme, rng);
                c.bold = self.bold;
                return c;
            },
            .ansi => {},
        }
        if (!self.usesClassicList()) {
            return .{
                .kind = .ansi,
                .index = randomAnsi(self.theme, self.palette, rng),
                .mode = self.palette,
                .custom = self.explicit_len > 0,
                .bold = self.bold,
            };
        }
        const l = self.list();
        if (l.len == 0) return .{ .kind = .none, .bold = self.bold };
        return self.makeAnsi(l[rng.uintLessThan(usize, l.len)]);
    }

    pub fn addExplicit(self: *Colors, spec: []const u8) !void {
        var it = std.mem.splitScalar(u8, spec, ',');
        while (it.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t");
            if (part.len == 0) return error.InvalidColor;
            const n = std.fmt.parseInt(u16, part, 10) catch return error.InvalidColor;
            if (n < 1 or n > 255) return error.InvalidColor;
            if (self.explicit_len >= self.explicit.len) return error.InvalidColor;
            self.explicit[self.explicit_len] = @intCast(n);
            self.explicit_len += 1;
        }
    }

    /// 旧名字，语义等同 pick()：随机取一个颜色。
    pub fn next(self: *Colors, rng: std.Random) Color {
        return self.pick(rng);
    }
};

pub fn same(a: Color, b: Color) bool {
    return a.kind == b.kind and
        a.index == b.index and
        a.mode == b.mode and
        a.custom == b.custom and
        a.r == b.r and
        a.g == b.g and
        a.b == b.b and
        a.bold == b.bold;
}

pub fn hasSgr(c: Color) bool {
    return c.kind != .none or c.bold;
}

/// 根据颜色模式生成 SGR 序列，直接追加到输出缓冲。
pub fn appendSgr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: Color) !void {
    if (c.bold) try out.appendSlice(allocator, "\x1b[1m");

    switch (c.kind) {
        .none => {},
        .ansi => {
            var buf: [24]u8 = undefined;
            // pipes.sh 用 tput setaf：8 色终端下 -c 3 就是 \e[33m，不是 38;5;3。
            const s = if (c.mode == .c88 or c.mode == .c256 or c.index >= 8)
                try std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{c.index})
            else if (c.mode == .c8)
                try std.fmt.bufPrint(&buf, "\x1b[3{d}m", .{c.index})
            else if (c.index < 8)
                try std.fmt.bufPrint(&buf, "\x1b[3{d}m", .{c.index})
            else
                try std.fmt.bufPrint(&buf, "\x1b[9{d}m", .{c.index - 8});
            try out.appendSlice(allocator, s);
        },
        .rgb => {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
            try out.appendSlice(allocator, s);
        },
    }
}

test "主题 ANSI 取色都落在声明范围内" {
    const themes = [_]Theme{ .default, .darker, .pastel, .matrix };
    const modes = [_]Mode{ .c8, .c16, .c88, .c256 };
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rng = prng.random();

    for (themes) |theme| {
        for (modes) |mode| {
            var colors = Colors{ .theme = theme, .palette = mode, .color_mode = .ansi };
            var i: usize = 0;
            while (i < 80) : (i += 1) {
                const c = colors.next(rng);
                try std.testing.expectEqual(Kind.ansi, c.kind);
                if (theme == .matrix) {
                    var found = false;
                    for (matrixIndexes(mode)) |idx| {
                        if (c.index == idx) found = true;
                    }
                    try std.testing.expect(found);
                } else {
                    const range = themeAnsiRange(theme, mode);
                    // pipes.sh 的默认配色表是 (1 2 3 4 5 6 7 0)，含 0 号黑，要单独放行。
                    const allow_black = theme == .default and mode == .c8;
                    try std.testing.expect((c.index >= range.lo and c.index <= range.hi) or
                        (allow_black and c.index == 0));
                }
            }
        }
    }
}

test "matrix 主题 RGB 偏绿，rainbow 能旋转色相" {
    var prng = std.Random.DefaultPrng.init(0x5678);
    const rng = prng.random();
    var colors = Colors{ .color_mode = .rgb, .theme = .matrix };

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const c = colors.next(rng);
        try std.testing.expectEqual(Kind.rgb, c.kind);
        try std.testing.expect(c.g >= c.r and c.g >= c.b);
    }

    const red = Color{ .kind = .rgb, .r = 255, .g = 0, .b = 0 };
    const green = rotateHue(red, 120);
    try std.testing.expect(green.g > 200);
    try std.testing.expect(green.r < 60);
    try std.testing.expect(green.b < 60);
}

test "none 模式不产生颜色 SGR" {
    // bold 默认开，这里只验证"没有颜色"这一件事，所以显式关掉加粗。
    var colors = Colors{ .color_mode = .none, .bold = false };
    var prng = std.Random.DefaultPrng.init(1);
    const c = colors.next(prng.random());
    try std.testing.expectEqual(Kind.none, c.kind);
    try std.testing.expect(!hasSgr(c));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendSgr(&out, std.testing.allocator, c);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
