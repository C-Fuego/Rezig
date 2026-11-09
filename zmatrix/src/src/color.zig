//! 颜色：与 cmatrix 完全相同的 8 种 ANSI 基色（30-37），
//! 另外提供 `--fade` 才启用的 256 色渐隐色阶。
//!
//! 关键约定：`Style` 是「完整」属性（前色 + 粗体），输出时总是补齐需要变化的
//! 部分，所以不会出现「上一个格子的加粗泄漏到下一个格子」这种事——这正是
//! 之前 256 色/16 色观感错配的根因。
const std = @import("std");

pub const Name = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    pub fn displayName(self: Name) []const u8 {
        return @tagName(self);
    }
};

pub const Depth = enum { ansi16, ansi256 };

/// 渐隐色阶数（`--fade` 时的尾部亮度档位数）。
pub const levels: u8 = 5;

/// 每种基色在 256 色立方体/灰度表上从亮到暗的 5 档。
pub const ramps256: [8][levels]u8 = .{
    .{ 240, 238, 236, 234, 232 }, // black  -> 灰度表
    .{ 196, 160, 124, 88, 52 }, // red
    .{ 46, 40, 34, 28, 22 }, // green
    .{ 226, 184, 142, 100, 58 }, // yellow
    .{ 21, 20, 19, 18, 17 }, // blue
    .{ 201, 164, 127, 90, 53 }, // magenta
    .{ 51, 44, 37, 30, 23 }, // cyan
    .{ 255, 253, 251, 248, 245 }, // white -> 灰度表
};

/// 一个格子要输出的完整前景属性。
pub const Style = struct {
    pub const Kind = enum { none, ansi, c256 };

    kind: Kind = .none,
    /// kind == .ansi 时是 SGR 前色码（30-37 / 90-97）；
    /// kind == .c256 时是 256 色调色板下标。
    code: u8 = 0,
    bold: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.kind == b.kind and a.code == b.code and a.bold == b.bold;
    }
};

/// cmatrix 的「矩阵色」：普通 8 色。
pub fn ansi(name: Name, bold: bool) Style {
    return .{ .kind = .ansi, .code = 30 + @as(u8, @intFromEnum(name)), .bold = bold };
}

/// cmatrix 的头部：白色（COLOR_WHITE = 37），加粗由 -b/-B/-n 决定。
pub fn white(bold: bool) Style {
    return .{ .kind = .ansi, .code = 37, .bold = bold };
}

/// `--fade` 时的头部：亮白，和拖尾的高反差配合更好看。
pub fn brightWhite(bold: bool) Style {
    return .{ .kind = .ansi, .code = 97, .bold = bold };
}

/// `--fade` 时拖尾按距离取档：1 最亮 -> levels 最暗。
pub fn fade(name: Name, level: u8, bold: bool, depth: Depth) Style {
    const idx: usize = if (level == 0) 0 else @min(level - 1, levels - 1);
    return switch (depth) {
        .ansi256 => .{
            .kind = .c256,
            .code = ramps256[@intFromEnum(name)][idx],
            .bold = bold,
        },
        // 16 色终端只有「加粗/不加粗」两档亮度，做不出 5 级色阶；
        // 这里退化成 2 档，和 cmatrix 本身的亮度档位一致。
        .ansi16 => .{
            .kind = .ansi,
            .code = 30 + @as(u8, @intFromEnum(name)),
            .bold = bold or level <= 2,
        },
    };
}

/// 输出从 prev 到 next 需要的 SGR 增量。属性没变时一个字节都不写。
pub fn emit(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    prev: Style,
    next: Style,
) !void {
    if (Style.eql(prev, next)) return;
    if (next.kind == .none) {
        try out.appendSlice(gpa, "\x1b[0m");
        return;
    }
    var tmp: [24]u8 = undefined;
    const bold_changed = next.bold != prev.bold;
    const s: []const u8 = if (next.kind == .c256)
        (if (bold_changed)
            std.fmt.bufPrint(&tmp, "\x1b[{s}38;5;{d}m", .{
                if (next.bold) "1;" else "22;", next.code,
            }) catch "\x1b[0m"
        else
            std.fmt.bufPrint(&tmp, "\x1b[38;5;{d}m", .{next.code}) catch "\x1b[0m")
    else if (bold_changed)
        std.fmt.bufPrint(&tmp, "\x1b[{s}{d}m", .{
            if (next.bold) "1;" else "22;", next.code,
        }) catch "\x1b[0m"
    else
        std.fmt.bufPrint(&tmp, "\x1b[{d}m", .{next.code}) catch "\x1b[0m";
    try out.appendSlice(gpa, s);
}

/// 把 Style 压成 u16，供帧差分逐格比较用：kind(2) | code(8) | bold(1)。
pub fn encode(s: Style) u16 {
    const kind: u16 = switch (s.kind) {
        .none => 0,
        .ansi => 1,
        .c256 => 2,
    };
    return kind | (@as(u16, s.code) << 2) | (@as(u16, @intFromBool(s.bold)) << 10);
}

pub fn decode(v: u16) Style {
    return .{
        .kind = switch (v & 0b11) {
            0 => .none,
            1 => .ansi,
            else => .c256,
        },
        .code = @intCast((v >> 2) & 0xff),
        .bold = ((v >> 10) & 1) == 1,
    };
}

/// 解析 -C 的值：颜色名（不区分大小写）或 0-7。
pub fn parseName(s: []const u8) ?Name {
    if (s.len == 1 and s[0] >= '0' and s[0] <= '7') {
        return @enumFromInt(@as(u8, s[0] - '0'));
    }
    inline for (@typeInfo(Name).@"enum".field_names, @typeInfo(Name).@"enum".field_values) |fname, fvalue| {
        if (std.ascii.eqlIgnoreCase(s, fname)) return @enumFromInt(fvalue);
    }
    return null;
}

/// 根据 TERM 选择色深，只有 `--fade` 用到。
pub fn detectDepth(term_name: ?[]const u8) Depth {
    const t = term_name orelse return .ansi16;
    if (t.len == 0) return .ansi16;
    if (std.mem.indexOf(u8, t, "256") != null) return .ansi256;
    if (std.mem.indexOf(u8, t, "16color") != null) return .ansi16;
    if (std.mem.indexOf(u8, t, "8color") != null) return .ansi16;
    const low = [_][]const u8{ "dumb", "linux", "vt100", "vt220", "vt52", "ansi" };
    for (low) |name| {
        if (std.ascii.eqlIgnoreCase(t, name)) return .ansi16;
    }
    return .ansi256;
}

// ------------------------------------------------------------------ tests

test "parse color names and digits" {
    try std.testing.expectEqual(Name.green, parseName("green").?);
    try std.testing.expectEqual(Name.red, parseName("RED").?);
    try std.testing.expectEqual(Name.white, parseName("7").?);
    try std.testing.expectEqual(Name.black, parseName("0").?);
    try std.testing.expect(parseName("nope") == null);
}

test "color depth detection" {
    try std.testing.expectEqual(Depth.ansi256, detectDepth("xterm-ghostty"));
    try std.testing.expectEqual(Depth.ansi256, detectDepth("xterm-256color"));
    try std.testing.expectEqual(Depth.ansi16, detectDepth("linux"));
    try std.testing.expectEqual(Depth.ansi16, detectDepth("dumb"));
    try std.testing.expectEqual(Depth.ansi16, detectDepth(null));
}

test "emit writes a bold reset when the head stops being bold" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    const prev = Style{};

    // 头部：白 + 粗体
    const head = white(true);
    try emit(gpa, &out, prev, head);
    try std.testing.expectEqualStrings("\x1b[1;37m", out.items);

    // 拖尾：绿色、不加粗 —— 必须显式关掉粗体，否则会泄漏
    out.clearRetainingCapacity();
    const tail = ansi(.green, false);
    try emit(gpa, &out, head, tail);
    try std.testing.expectEqualStrings("\x1b[22;32m", out.items);

    // 同色重复不会重复输出
    out.clearRetainingCapacity();
    try emit(gpa, &out, tail, tail);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "style encoding round-trips for the diff buffer" {
    const cases = [_]Style{
        .{},
        ansi(.green, false),
        ansi(.white, true),
        white(true),
        brightWhite(false),
        fade(.magenta, 3, true, .ansi256),
        fade(.black, 5, false, .ansi256),
    };
    for (cases) |st| {
        const back = decode(encode(st));
        try std.testing.expect(Style.eql(st, back));
    }
    // 不同的样式不会编码成同一个值
    try std.testing.expect(encode(ansi(.green, false)) != encode(ansi(.green, true)));
    try std.testing.expect(encode(ansi(.red, false)) != encode(ansi(.green, false)));
}

test "fade ramp gets darker and ansi16 has two levels" {
    var prev_code: u8 = 0;
    var lvl: u8 = 1;
    while (lvl <= levels) : (lvl += 1) {
        const st = fade(.green, lvl, false, .ansi256);
        try std.testing.expectEqual(Style.Kind.c256, st.kind);
        try std.testing.expect(st.code < prev_code or prev_code == 0);
        prev_code = st.code;
    }
    try std.testing.expectEqual(@as(u8, 46), ramps256[2][0]);
    try std.testing.expectEqual(@as(u8, 22), ramps256[2][4]);
    // 16 色只有两档：前两档粗体（亮），后面普通
    try std.testing.expect(fade(.green, 1, false, .ansi16).bold);
    try std.testing.expect(!fade(.green, 5, false, .ansi16).bold);
}
