//! A small character canvas: one codepoint plus an optional foreground colour
//! per cell. This is the TOIlet side's equivalent of a libcaca canvas, kept
//! deliberately simple (no attributes, no backgrounds).

const std = @import("std");
const Allocator = std.mem.Allocator;
const color = @import("color.zig");
const Rgb = color.Rgb;
const render = @import("textfig").render;

pub const Cell = struct {
    ch: u21 = ' ',
    fg: ?Rgb = null,
};

pub const Canvas = struct {
    a: Allocator,
    width: usize,
    height: usize,
    cells: []Cell,

    pub fn init(a: Allocator, width: usize, height: usize) !Canvas {
        const n = std.math.mul(usize, width, height) catch return error.OutOfMemory;
        const cells = try a.alloc(Cell, n);
        for (cells) |*c| c.* = .{};
        return .{ .a = a, .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Canvas) void {
        self.a.free(self.cells);
        self.* = undefined;
    }

    pub fn at(self: *const Canvas, x: usize, y: usize) Cell {
        if (x >= self.width or y >= self.height) return .{};
        return self.cells[y * self.width + x];
    }

    pub fn set(self: *Canvas, x: usize, y: usize, cell: Cell) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = cell;
    }

    /// Build a canvas from a rendered FIGlet line. Hardblanks become spaces.
    pub fn fromLine(a: Allocator, line: *const render.RenderedLine, hardblank: u21) !Canvas {
        var cv = try Canvas.init(a, line.width, line.height);
        for (0..line.height) |y| {
            for (0..line.width) |x| {
                var ch = line.rows[y][x];
                if (ch == hardblank) ch = ' ';
                cv.cells[y * line.width + x] = .{ .ch = ch };
            }
        }
        return cv;
    }

    /// Replace the canvas contents, taking ownership of `cells`.
    fn replace(self: *Canvas, width: usize, height: usize, cells: []Cell) void {
        self.a.free(self.cells);
        self.width = width;
        self.height = height;
        self.cells = cells;
    }

    /// Fill every non-blank cell with a solid colour.
    pub fn fillColor(self: *Canvas, c: Rgb) void {
        for (self.cells) |*cell| {
            if (cell.ch != ' ') cell.fg = c;
        }
    }

    /// Remove blank borders (TOIlet's crop filter).
    pub fn crop(self: *Canvas) !void {
        if (self.width == 0 or self.height == 0) return;
        var xmin = self.width;
        var xmax: usize = 0;
        var ymin = self.height;
        var ymax: usize = 0;
        var found = false;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                if (self.at(x, y).ch != ' ') {
                    found = true;
                    xmin = @min(xmin, x);
                    xmax = @max(xmax, x);
                    ymin = @min(ymin, y);
                    ymax = @max(ymax, y);
                }
            }
        }
        if (!found) return;
        const w = xmax - xmin + 1;
        const h = ymax - ymin + 1;
        if (w == self.width and h == self.height and xmin == 0 and ymin == 0) return;
        const cells = try self.a.alloc(Cell, w * h);
        for (0..h) |y| {
            for (0..w) |x| cells[y * w + x] = self.at(xmin + x, ymin + y);
        }
        self.replace(w, h, cells);
    }

    /// mirror-cmapping used by TOIlet's flip filter for common ASCII pairs.
    fn flipChar(c: u21) u21 {
        return switch (c) {
            '(' => ')',
            ')' => '(',
            '/' => '\\',
            '\\' => '/',
            '<' => '>',
            '>' => '<',
            '[' => ']',
            ']' => '[',
            '{' => '}',
            '}' => '{',
            'b' => 'd',
            'd' => 'b',
            'p' => 'q',
            'q' => 'p',
            else => c,
        };
    }

    fn flopChar(c: u21) u21 {
        return switch (c) {
            '/' => '\\',
            '\\' => '/',
            'M' => 'W',
            'W' => 'M',
            'b' => 'p',
            'p' => 'b',
            'd' => 'q',
            'q' => 'd',
            'f' => 't',
            't' => 'f',
            '.' => '\'',
            '\'' => '.',
            else => c,
        };
    }

    fn rot180Char(c: u21) u21 {
        return switch (c) {
            'b' => 'q',
            'q' => 'b',
            'd' => 'p',
            'p' => 'd',
            'M' => 'W',
            'W' => 'M',
            '/' => '\\',
            '\\' => '/',
            '<' => '>',
            '>' => '<',
            '(' => ')',
            ')' => '(',
            '[' => ']',
            ']' => '[',
            '{' => '}',
            '}' => '{',
            else => c,
        };
    }

    /// Horizontal mirror (TOIlet's `flip`).
    pub fn flip(self: *Canvas) void {
        for (0..self.height) |y| {
            for (0..self.width / 2) |x| {
                const left = self.at(x, y);
                const right = self.at(self.width - 1 - x, y);
                self.set(x, y, .{ .ch = flipChar(right.ch), .fg = right.fg });
                self.set(self.width - 1 - x, y, .{ .ch = flipChar(left.ch), .fg = left.fg });
            }
            if (self.width % 2 == 1) {
                const mid = self.width / 2;
                const c = self.at(mid, y);
                self.set(mid, y, .{ .ch = flipChar(c.ch), .fg = c.fg });
            }
        }
    }

    /// Vertical mirror (TOIlet's `flop`).
    pub fn flop(self: *Canvas) void {
        for (0..self.height / 2) |y| {
            for (0..self.width) |x| {
                const top = self.at(x, y);
                const bottom = self.at(x, self.height - 1 - y);
                self.set(x, y, .{ .ch = flopChar(bottom.ch), .fg = bottom.fg });
                self.set(x, self.height - 1 - y, .{ .ch = flopChar(top.ch), .fg = top.fg });
            }
        }
        if (self.height % 2 == 1) {
            const mid = self.height / 2;
            for (0..self.width) |x| {
                const c = self.at(x, mid);
                self.set(x, mid, .{ .ch = flopChar(c.ch), .fg = c.fg });
            }
        }
    }

    /// Rotate 180 degrees.
    pub fn rotate180(self: *Canvas) !void {
        const cells = try tryCells(self.a, self.width * self.height);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const c = self.at(self.width - 1 - x, self.height - 1 - y);
                cells[y * self.width + x] = .{ .ch = rot180Char(c.ch), .fg = c.fg };
            }
        }
        self.replace(self.width, self.height, cells);
    }

    /// Rotate 90 degrees counter-clockwise (TOIlet's `left`).
    pub fn rotateLeft(self: *Canvas) !void {
        const nw = self.height;
        const nh = self.width;
        const cells = try tryCells(self.a, nw * nh);
        for (0..nh) |y| {
            for (0..nw) |x| {
                const c = self.at(self.width - 1 - y, x);
                cells[y * nw + x] = .{ .ch = c.ch, .fg = c.fg };
            }
        }
        self.replace(nw, nh, cells);
    }

    /// Rotate 90 degrees clockwise (TOIlet's `right`).
    pub fn rotateRight(self: *Canvas) !void {
        const nw = self.height;
        const nh = self.width;
        const cells = try tryCells(self.a, nw * nh);
        for (0..nh) |y| {
            for (0..nw) |x| {
                const c = self.at(y, self.height - 1 - x);
                cells[y * nw + x] = .{ .ch = c.ch, .fg = c.fg };
            }
        }
        self.replace(nw, nh, cells);
    }

    /// Surround the canvas with a box (TOIlet's `border`).
    pub fn border(self: *Canvas) !void {
        const nw = self.width + 2;
        const nh = self.height + 2;
        const cells = try tryCells(self.a, nw * nh);
        for (0..nh) |y| {
            for (0..nw) |x| {
                const ch: u21 = if (y == 0)
                    (if (x == 0) 0x250c else if (x == nw - 1) 0x2510 else 0x2500)
                else if (y == nh - 1)
                    (if (x == 0) 0x2514 else if (x == nw - 1) 0x2518 else 0x2500)
                else if (x == 0 or x == nw - 1)
                    0x2502
                else
                    ' ';
                cells[y * nw + x] = .{ .ch = ch };
            }
        }
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                cells[(y + 1) * nw + x + 1] = self.at(x, y);
            }
        }
        self.replace(nw, nh, cells);
    }

    fn tryCells(a: Allocator, n: usize) ![]Cell {
        const cells = try a.alloc(Cell, n);
        for (cells) |*c| c.* = .{};
        return cells;
    }
};

const testing = std.testing;

fn canvasFromRows(a: Allocator, rows: []const []const u8) !Canvas {
    var cv = try Canvas.init(a, rows[0].len, rows.len);
    for (rows, 0..) |row, y| {
        for (row, 0..) |b, x| cv.set(x, y, .{ .ch = b });
    }
    return cv;
}

fn rowString(a: Allocator, cv: *const Canvas, y: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [4]u8 = undefined;
    for (0..cv.width) |x| {
        const c = cv.at(x, y);
        const n = try std.unicode.utf8Encode(c.ch, &buf);
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

test "flip, flop and 180 degrees" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cv = try canvasFromRows(a, &.{ "xy", "(]" });
    cv.flip();
    try testing.expectEqualStrings("yx", try rowString(a, &cv, 0));
    try testing.expectEqualStrings("[)", try rowString(a, &cv, 1));
    cv.deinit();

    var cv2 = try canvasFromRows(a, &.{ "/\\", "ab" });
    cv2.flop();
    try testing.expectEqualStrings("ap", try rowString(a, &cv2, 0));
    try testing.expectEqualStrings("\\/", try rowString(a, &cv2, 1));
    cv2.deinit();

    var cv3 = try canvasFromRows(a, &.{ "ab", "cd" });
    try cv3.rotate180();
    // old(1,1)='d'->p, old(0,1)='c'; then old(1,0)='b'->q, old(0,0)='a'
    try testing.expectEqualStrings("pc", try rowString(a, &cv3, 0));
    try testing.expectEqualStrings("qa", try rowString(a, &cv3, 1));
    cv3.deinit();
}

test "rotation dimensions and crop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cv = try canvasFromRows(a, &.{ "ab", "cd", "ef" });
    try cv.rotateLeft();
    try testing.expectEqual(@as(usize, 3), cv.width);
    try testing.expectEqual(@as(usize, 2), cv.height);
    try testing.expectEqualStrings("bdf", try rowString(a, &cv, 0));
    try testing.expectEqualStrings("ace", try rowString(a, &cv, 1));
    cv.deinit();

    var cv2 = try canvasFromRows(a, &.{ "   ", " a ", "   " });
    try cv2.crop();
    try testing.expectEqual(@as(usize, 1), cv2.width);
    try testing.expectEqual(@as(usize, 1), cv2.height);
    cv2.deinit();
}
