//! 字符集：取值区间与 cmatrix 原版逐字对齐。
//!
//! 原版（cmatrix.c）：
//!   默认  randmin = 33,  highnum = 123 -> rand() % 90  + 33  = '!'..'z'（90 个）
//!   -c    randmin = 0xff66, highnum = 0xff9d -> rand() % 55 + 0xff66
//!         = U+FF66..U+FF9C（55 个，注意不含 U+FF9D）
//!   -l/-x randmin = 166, highnum = 217（控制台/X 位图字体码位，纯终端下不可用）
//!
//! 之前这里默认用了 33..126（94 个）、片假名用了 U+FF66..U+FF9D（56 个），
//! 都比原版多，于是字符密度和字形分布跟原版对不上。
const std = @import("std");

pub const Kind = enum {
    ascii,
    katakana,
    custom,

    pub fn displayName(self: Kind) []const u8 {
        return switch (self) {
            .ascii => "ascii",
            .katakana => "katakana",
            .custom => "custom",
        };
    }
};

/// cmatrix 默认字符：'!'..'z'（33..122），共 90 个。
pub const ascii_chars: [90]u21 = blk: {
    var arr: [90]u21 = undefined;
    for (0..90) |i| arr[i] = @intCast(33 + i);
    break :blk arr;
};

/// cmatrix `-c` 的片假名：U+FF66..U+FF9C，共 55 个码位。
/// 选半角片假名（而不是全角 U+30A1..）是因为它在 UTF-8 终端里宽度为 1，
/// 一列一字符不会像全角那样占两格、破坏列对齐。
pub const katakana_chars: [55]u21 = blk: {
    var arr: [55]u21 = undefined;
    for (0..55) |i| arr[i] = @intCast(0xFF66 + i);
    break :blk arr;
};

/// 返回实际使用的字符表。custom 为空时回退到 ascii，避免除以 0。
pub fn glyphs(kind: Kind, custom: []const u21) []const u21 {
    return switch (kind) {
        .ascii => &ascii_chars,
        .katakana => &katakana_chars,
        .custom => if (custom.len == 0) &ascii_chars else custom,
    };
}

/// 从字符表里均匀取一个。原版是 rand() % randnum + randmin，
/// 对连续区间来说等价于按下标取。
pub fn pick(set: []const u21, r: std.Random) u21 {
    if (set.len == 0) return ' ';
    return set[r.uintLessThan(usize, set.len)];
}

/// 把 UTF-8 字符串拆成码位表（-l / -M 用）。
pub fn parseCodepoints(gpa: std.mem.Allocator, s: []const u8) ![]u21 {
    var list: std.ArrayList(u21) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > s.len) {
            try list.append(gpa, '?');
            break;
        }
        const cp: u21 = if (n == 1)
            s[i]
        else
            std.unicode.utf8Decode(s[i .. i + n]) catch '?';
        try list.append(gpa, cp);
        i += n;
    }
    return list.toOwnedSlice(gpa);
}

// ------------------------------------------------------------------ tests

test "ascii charset matches cmatrix range 33..122" {
    try std.testing.expectEqual(@as(usize, 90), ascii_chars.len);
    try std.testing.expectEqual(@as(u21, '!'), ascii_chars[0]);
    try std.testing.expectEqual(@as(u21, 'z'), ascii_chars[89]);
    for (ascii_chars) |c| {
        try std.testing.expect(c >= '!' and c <= 'z');
    }
}

test "katakana charset matches cmatrix range FF66..FF9C" {
    try std.testing.expectEqual(@as(usize, 55), katakana_chars.len);
    try std.testing.expectEqual(@as(u21, 0xFF66), katakana_chars[0]);
    try std.testing.expectEqual(@as(u21, 0xFF9C), katakana_chars[54]);
    for (katakana_chars) |c| {
        try std.testing.expect(c >= 0xFF66 and c <= 0xFF9C);
    }
}

test "custom charset falls back to ascii when empty" {
    try std.testing.expectEqual(ascii_chars.len, glyphs(.custom, &.{}).len);
    const mine = [_]u21{ '0', '1' };
    try std.testing.expectEqual(@as(usize, 2), glyphs(.custom, &mine).len);
}

test "pick only returns glyphs from the active set" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..500) |_| {
        const g = pick(&ascii_chars, r);
        try std.testing.expect(std.mem.indexOfScalar(u21, &ascii_chars, g) != null);
    }
}
