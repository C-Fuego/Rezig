const std = @import("std");
const palette = @import("palette.zig");

pub const Cell = struct {
    glyph: [4]u8 = .{ 0, 0, 0, 0 },
    glyph_len: u8 = 0,
    color: palette.Color = .{},
};

/// 占用网格。glyph_len > 0 即表示该格已被管道占用，也用于防止管道互相覆盖。
pub const Grid = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    cells: []Cell,
    dirty: []bool,
    occupied_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Grid {
        const n = cols * rows;
        const cells = try allocator.alloc(Cell, n);
        errdefer allocator.free(cells);
        @memset(cells, Cell{});

        const dirty = try allocator.alloc(bool, n);
        @memset(dirty, false);

        return .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .dirty = dirty,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.dirty);
        self.cells = &.{};
        self.dirty = &.{};
        self.cols = 0;
        self.rows = 0;
    }

    fn index(self: *const Grid, x: usize, y: usize) usize {
        return y * self.cols + x;
    }

    pub fn isFree(self: *const Grid, x: i32, y: i32) bool {
        if (x < 0 or y < 0) return false;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.cols or uy >= self.rows) return false;
        return self.cells[self.index(ux, uy)].glyph_len == 0;
    }

    pub fn setGlyph(self: *Grid, x: usize, y: usize, glyph: []const u8, color: palette.Color) void {
        if (x >= self.cols or y >= self.rows) return;
        if (glyph.len == 0 or glyph.len > 4) return;

        const i = self.index(x, y);
        const cell = &self.cells[i];
        const was_empty = cell.glyph_len == 0;
        const unchanged = !was_empty and
            cell.glyph_len == glyph.len and
            std.mem.eql(u8, cell.glyph[0..cell.glyph_len], glyph) and
            palette.same(cell.color, color);
        if (was_empty) self.occupied_count += 1;

        @memcpy(cell.glyph[0..glyph.len], glyph);
        cell.glyph_len = @intCast(glyph.len);
        cell.color = color;
        if (!unchanged) self.dirty[i] = true;
    }

    pub fn clearAll(self: *Grid) void {
        @memset(self.cells, Cell{});
        @memset(self.dirty, false);
        self.occupied_count = 0;
    }

    pub fn occupancy(self: *const Grid) f32 {
        const total = self.cols * self.rows;
        if (total == 0) return 1.0;
        return @as(f32, @floatFromInt(self.occupied_count)) / @as(f32, @floatFromInt(total));
    }

    /// 终端尺寸变化时保留左上角重叠区域，其余格子重新开始。
    pub fn resize(self: *Grid, new_cols: usize, new_rows: usize) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;

        const n = new_cols * new_rows;
        const new_cells = try self.allocator.alloc(Cell, n);
        errdefer self.allocator.free(new_cells);
        @memset(new_cells, Cell{});

        const new_dirty = try self.allocator.alloc(bool, n);
        @memset(new_dirty, false);

        const copy_cols = @min(self.cols, new_cols);
        const copy_rows = @min(self.rows, new_rows);
        var count: usize = 0;
        var y: usize = 0;
        while (y < copy_rows) : (y += 1) {
            const src = self.cells[y * self.cols ..][0..copy_cols];
            const dst = new_cells[y * new_cols ..][0..copy_cols];
            @memcpy(dst, src);
            for (src) |cell| {
                if (cell.glyph_len > 0) count += 1;
            }
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.dirty);
        self.cells = new_cells;
        self.dirty = new_dirty;
        self.cols = new_cols;
        self.rows = new_rows;
        self.occupied_count = count;
    }

    fn appendCursor(out: *std.ArrayList(u8), allocator: std.mem.Allocator, x: usize, y: usize) !void {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 });
        try out.appendSlice(allocator, s);
    }

    /// 整屏重绘。关闭了终端自动换行，所以每行显式定位。
    pub fn renderAll(self: *Grid, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var last: palette.Color = .{};
        var have_sgr = false;

        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            try appendCursor(out, allocator, 0, y);
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const cell = self.cells[self.index(x, y)];
                if (cell.glyph_len == 0) {
                    try out.append(allocator, ' ');
                    continue;
                }
                if (!palette.same(last, cell.color)) {
                    if (palette.hasSgr(cell.color)) {
                        try palette.appendSgr(out, allocator, cell.color);
                        have_sgr = true;
                    }
                    last = cell.color;
                }
                try out.appendSlice(allocator, cell.glyph[0..cell.glyph_len]);
            }
        }

        if (have_sgr) try out.appendSlice(allocator, "\x1b[0m");
        @memset(self.dirty, false);
    }

    /// 只绘制本帧发生变化的格子。
    pub fn renderDirty(self: *Grid, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const i = self.index(x, y);
                if (!self.dirty[i]) continue;
                self.dirty[i] = false;

                const cell = self.cells[i];
                try appendCursor(out, allocator, x, y);
                if (cell.glyph_len == 0) {
                    try out.append(allocator, ' ');
                } else {
                    if (palette.hasSgr(cell.color)) {
                        try palette.appendSgr(out, allocator, cell.color);
                    }
                    try out.appendSlice(allocator, cell.glyph[0..cell.glyph_len]);
                }
            }
        }
    }
};

test "setGlyph 只在内容变化时标脏" {
    const allocator = std.testing.allocator;
    var g = try Grid.init(allocator, 4, 4);
    defer g.deinit();

    const color: palette.Color = .{ .kind = .ansi, .index = 2 };
    g.setGlyph(1, 1, "┃", color);
    try std.testing.expect(g.dirty[1 * 4 + 1]);
    try std.testing.expectEqual(@as(usize, 1), g.occupied_count);

    g.dirty[1 * 4 + 1] = false;
    g.setGlyph(1, 1, "┃", color);
    try std.testing.expect(!g.dirty[1 * 4 + 1]);

    g.setGlyph(1, 1, "┏", color);
    try std.testing.expect(g.dirty[1 * 4 + 1]);
}

test "resize 保留重叠区域并重新计算占用" {
    const allocator = std.testing.allocator;
    var g = try Grid.init(allocator, 10, 5);
    defer g.deinit();

    g.setGlyph(1, 1, "┃", .{ .index = 2 });
    g.setGlyph(9, 4, "━", .{ .index = 4 });
    try std.testing.expectEqual(@as(usize, 2), g.occupied_count);

    // 缩小到 4x3：(1,1) 保留，(9,4) 被裁掉。
    try g.resize(4, 3);
    try std.testing.expectEqual(@as(usize, 4), g.cols);
    try std.testing.expectEqual(@as(usize, 3), g.rows);
    try std.testing.expectEqual(@as(usize, 1), g.occupied_count);
    try std.testing.expect(!g.isFree(1, 1));
    try std.testing.expect(g.isFree(3, 2));

    // 再放大，旧内容仍在，新区域为空。
    try g.resize(8, 6);
    try std.testing.expect(!g.isFree(1, 1));
    try std.testing.expect(g.isFree(7, 5));
    try std.testing.expectEqual(@as(usize, 1), g.occupied_count);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 48.0), g.occupancy(), 0.0001);
}
