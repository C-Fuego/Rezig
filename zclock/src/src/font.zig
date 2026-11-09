//! tty-clock 原版点阵（ttyclock.h 里的 `const bool number[][15]`）。
//! 每个数字是 3 列 × 5 行的布尔点阵，屏幕上每点横向复制成 2 列（原版
//! draw_number() 用 `wbkgdset(COLOR_PAIR(number[n][i/2]))` 连续画 30 格，
//! i/2 正是"每个点画两格"），所以可见尺寸是 6 列 × 5 行。
const std = @import("std");

pub const raw_cols: usize = 3;
pub const raw_rows: usize = 5;
/// 屏幕上一个数字占的列数 / 行数。
pub const cell_cols: usize = raw_cols * 2;
pub const cell_rows: usize = raw_rows;

pub const Pattern = [raw_rows][raw_cols]bool;

/// 与 ttyclock.h 的 number[][] 逐位一致（行优先，每行 3 位）。
pub const patterns: [10]Pattern = .{
    .{ .{ true, true, true }, .{ true, false, true }, .{ true, false, true }, .{ true, false, true }, .{ true, true, true } }, // 0
    .{ .{ false, false, true }, .{ false, false, true }, .{ false, false, true }, .{ false, false, true }, .{ false, false, true } }, // 1
    .{ .{ true, true, true }, .{ false, false, true }, .{ true, true, true }, .{ true, false, false }, .{ true, true, true } }, // 2
    .{ .{ true, true, true }, .{ false, false, true }, .{ true, true, true }, .{ false, false, true }, .{ true, true, true } }, // 3
    .{ .{ true, false, true }, .{ true, false, true }, .{ true, true, true }, .{ false, false, true }, .{ false, false, true } }, // 4
    .{ .{ true, true, true }, .{ true, false, false }, .{ true, true, true }, .{ false, false, true }, .{ true, true, true } }, // 5
    .{ .{ true, true, true }, .{ true, false, false }, .{ true, true, true }, .{ true, false, true }, .{ true, true, true } }, // 6
    .{ .{ true, true, true }, .{ false, false, true }, .{ false, false, true }, .{ false, false, true }, .{ false, false, true } }, // 7
    .{ .{ true, true, true }, .{ true, false, true }, .{ true, true, true }, .{ true, false, true }, .{ true, true, true } }, // 8
    .{ .{ true, true, true }, .{ true, false, true }, .{ true, true, true }, .{ false, false, true }, .{ true, true, true } }, // 9
};

pub fn pattern(digit: u8) Pattern {
    return patterns[digit % 10];
}

/// 屏幕坐标上的一个格子是否为点亮点：col ∈ [0,6)，row ∈ [0,5)。
pub fn cellOn(digit: u8, row: usize, col: usize) bool {
    if (row >= cell_rows or col >= cell_cols) return false;
    return patterns[digit % 10][row][col / 2];
}

/// 把数字画成 cell_rows 行、每行 cell_cols 个字符的文本（测试与纯文本降级用）。
pub fn renderAscii(digit: u8, on: u8, off: u8) [cell_rows][cell_cols]u8 {
    var out: [cell_rows][cell_cols]u8 = undefined;
    for (0..cell_rows) |r| {
        for (0..cell_cols) |c| {
            out[r][c] = if (cellOn(digit, r, c)) on else off;
        }
    }
    return out;
}

test "every digit renders exactly 5 rows of 6 columns" {
    for (0..10) |d| {
        const art = renderAscii(@intCast(d), '#', '.');
        try std.testing.expectEqual(cell_rows, art.len);
        try std.testing.expectEqual(cell_rows, 5);
        for (art) |row| {
            try std.testing.expectEqual(cell_cols, row.len);
            try std.testing.expectEqual(cell_cols, 6);
        }
    }
}

test "digit shapes match tty-clock's matrix" {
    // 0：实心边框 + 空心中间
    try std.testing.expect(cellOn(0, 0, 0) and cellOn(0, 0, 5));
    try std.testing.expect(!cellOn(0, 2, 2) and !cellOn(0, 2, 3));
    try std.testing.expect(cellOn(0, 4, 2));
    // 1：只有右列亮
    try std.testing.expect(!cellOn(1, 0, 0) and cellOn(1, 0, 4));
    try std.testing.expect(!cellOn(1, 4, 0) and cellOn(1, 4, 5));
    // 7：首行全亮，其余只有右列
    try std.testing.expect(cellOn(7, 0, 0) and cellOn(7, 0, 5));
    try std.testing.expect(!cellOn(7, 1, 0) and !cellOn(7, 4, 2));
    // 每个点横向复制两列：col 与 col^1 的奇偶对必然相同
    for (0..10) |d| {
        for (0..cell_rows) |r| {
            for (0..raw_cols) |pair| {
                try std.testing.expectEqual(
                    cellOn(@intCast(d), r, pair * 2),
                    cellOn(@intCast(d), r, pair * 2 + 1),
                );
            }
        }
    }
}

test "out of range lookups are safe" {
    try std.testing.expect(!cellOn(0, 5, 0));
    try std.testing.expect(!cellOn(0, 0, 6));
    _ = pattern(12); // 取模，不 panic
}
