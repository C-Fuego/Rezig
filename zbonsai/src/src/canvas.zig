//! A tiny cell grid that replaces the ncurses windows cbonsai draws into.
//!
//! Every drawn character lands in a `Cell` that remembers the byte sequence,
//! the 256-colour index and whether it is bold. A `Renderer` diffs the grid
//! against the previously emitted frame and only sends the changed runs, which
//! is what ncurses' `doupdate()` did for the original.
const std = @import("std");
const term = @import("term.zig");

pub const Allocator = std.mem.Allocator;

/// Marker stored in `Cell.len` for the second half of a double-width glyph.
pub const continuation: u8 = 0xFF;

pub const Cell = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    color: u8 = 0,
    bold: bool = false,
    /// True for the left half of a double-width glyph.
    wide: bool = false,

    pub fn eql(a: Cell, b: Cell) bool {
        return a.len == b.len and
            a.color == b.color and
            a.bold == b.bold and
            a.wide == b.wide and
            std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn isBlank(c: Cell) bool {
        return c.len == 0;
    }

    /// Returns the glyph bytes. Takes a pointer on purpose: a by-value `Cell`
    /// would hand out a slice into a temporary copy.
    pub fn text(c: *const Cell) []const u8 {
        if (c.len == 0 or c.len == continuation) return " ";
        return c.bytes[0..c.len];
    }
};

pub const blank: Cell = .{};

/// Display width of a codepoint, in terminal columns.
///
/// Zig's std has no `wcwidth`, so this is a compact approximation covering the
/// ranges that matter for cbonsai's leaf glyphs (CJK, emoji) plus zero-width
/// combining marks. Unknown codepoints count as one column.
pub fn charWidth(cp: u21) u2 {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0; // control chars
    // Zero width: combining marks, zero-width space/joiners, variation selectors.
    if ((cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0x20D0 and cp <= 0x20F0) or
        (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xFE20 and cp <= 0xFE2F)) return 0;
    // Wide / fullwidth ranges.
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x1F900 and cp <= 0x1F9FF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;
    return 1;
}

/// Display width of a UTF-8 string.
pub fn textWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            width += 1;
            continue;
        };
        if (i + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            i += n;
            width += 1;
            continue;
        };
        width += charWidth(cp);
        i += n;
    }
    return width;
}

pub const Canvas = struct {
    gpa: Allocator,
    rows: usize = 0,
    cols: usize = 0,
    cells: []Cell = &.{},

    pub fn init(gpa: Allocator, rows: usize, cols: usize) !Canvas {
        var self: Canvas = .{ .gpa = gpa };
        try self.resize(rows, cols);
        return self;
    }

    pub fn deinit(self: *Canvas) void {
        if (self.cells.len != 0) self.gpa.free(self.cells);
        self.cells = &.{};
        self.rows = 0;
        self.cols = 0;
    }

    pub fn resize(self: *Canvas, rows: usize, cols: usize) !void {
        const n = rows * cols;
        if (n != self.cells.len) {
            self.gpa.free(self.cells);
            self.cells = try self.gpa.alloc(Cell, n);
        }
        self.rows = rows;
        self.cols = cols;
        self.clear();
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.cells, blank);
    }

    fn index(self: *const Canvas, y: i32, x: i32) ?usize {
        if (x < 0 or y < 0) return null;
        const uy: usize = @intCast(y);
        const ux: usize = @intCast(x);
        if (uy >= self.rows or ux >= self.cols) return null;
        return uy * self.cols + ux;
    }

    pub fn at(self: *const Canvas, y: i32, x: i32) ?*const Cell {
        const i = self.index(y, x) orelse return null;
        return &self.cells[i];
    }

    /// Place a single codepoint; the caller advances the cursor itself.
    pub fn putCodepoint(self: *Canvas, y: i32, x: i32, cp: u21, color: u8, bold: bool) void {
        const width = charWidth(cp);
        if (width == 0) return;
        const i = self.index(y, x) orelse return;
        const ux: usize = @intCast(x);
        // Overwriting either half of a double-width glyph erases the whole
        // glyph, which is what ncurses does too.
        if (self.cells[i].len == continuation and ux > 0) self.cells[i - 1] = blank;
        if (self.cells[i].wide and ux + 1 < self.cols) self.cells[i + 1] = blank;

        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.cells[i] = .{ .bytes = buf, .len = n, .color = color, .bold = bold, .wide = width == 2 };
        if (width == 2 and ux + 1 < self.cols) {
            // Drop a glyph that used to start in the second half.
            if (self.cells[i + 1].wide and ux + 2 < self.cols) self.cells[i + 2] = blank;
            self.cells[i + 1] = .{ .len = continuation };
        }
    }

    /// Draw a UTF-8 string at (y, x), returning the column after the last glyph.
    /// Anything outside the grid is clipped silently, just like ncurses does.
    pub fn putText(self: *Canvas, y: i32, x: i32, text: []const u8, color: u8, bold: bool) i32 {
        var cx = x;
        var i: usize = 0;
        while (i < text.len) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch blk: {
                self.putCodepoint(y, cx, '?', color, bold);
                cx += 1;
                i += 1;
                break :blk 1;
            };
            if (i + n > text.len) break;
            const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
                i += n;
                continue;
            };
            const width = charWidth(cp);
            self.putCodepoint(y, cx, cp, color, bold);
            cx += @max(width, 1);
            i += n;
        }
        return cx;
    }

    /// ASCII-only fast path used for box drawing and debug output.
    pub fn putAscii(self: *Canvas, y: i32, x: i32, text: []const u8, color: u8, bold: bool) void {
        var cx = x;
        for (text) |c| {
            self.putCodepoint(y, cx, c, color, bold);
            cx += 1;
        }
    }
};

/// Emits frames to the terminal, sending only cells that changed since the last
/// frame. `invalidate()` forces a full repaint (after a resize or a clear).
pub const Renderer = struct {
    gpa: Allocator,
    prev: []Cell = &.{},
    rows: usize = 0,
    cols: usize = 0,
    force_full: bool = true,
    /// Last SGR state written: 0 means "default colours".
    last_color: u16 = 0,
    last_bold: bool = false,

    pub fn init(gpa: Allocator) Renderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.prev.len != 0) self.gpa.free(self.prev);
        self.prev = &.{};
    }

    pub fn invalidate(self: *Renderer) void {
        self.force_full = true;
    }

    fn syncSize(self: *Renderer, rows: usize, cols: usize) !void {
        const n = rows * cols;
        if (n != self.prev.len) {
            self.gpa.free(self.prev);
            self.prev = try self.gpa.alloc(Cell, n);
        }
        self.rows = rows;
        self.cols = cols;
        @memset(self.prev, blank);
        self.force_full = true;
    }

    fn setStyle(self: *Renderer, out: *term.Out, color: u8, bold: bool) void {
        const key: u16 = if (color == 0) 0 else @as(u16, color) + 1;
        if (self.last_color == key and self.last_bold == bold) return;
        out.write("\x1b[0m");
        if (color != 0) {
            if (bold) out.write("\x1b[1m");
            out.print("\x1b[38;5;{d}m", .{color});
        }
        self.last_color = key;
        self.last_bold = bold;
    }

    pub fn draw(self: *Renderer, c: *const Canvas, out: *term.Out) !void {
        if (self.rows != c.rows or self.cols != c.cols) try self.syncSize(c.rows, c.cols);
        if (self.force_full) {
            term.clearScreen(out);
            @memset(self.prev, blank);
            self.force_full = false;
            self.last_color = 0;
            self.last_bold = false;
        }

        var y: usize = 0;
        while (y < c.rows) : (y += 1) {
            var x: usize = 0;
            while (x < c.cols) {
                const cur = &c.cells[y * c.cols + x];
                if (Cell.eql(cur.*, self.prev[y * c.cols + x])) {
                    x += 1;
                    continue;
                }
                out.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                while (x < c.cols) {
                    const cell = &c.cells[y * c.cols + x];
                    const slot = y * c.cols + x;
                    if (Cell.eql(cell.*, self.prev[slot])) break;
                    self.prev[slot] = cell.*;
                    x += 1;
                    if (cell.len == continuation) continue;
                    self.setStyle(out, cell.color, cell.bold);
                    out.write(cell.text());
                }
            }
        }
        out.flush();
    }
};

/// Render the finished grid as plain text (the `--print` mode).
/// With `use_color == false` (piped stdout) the output is plain ASCII/UTF-8.
pub fn printPlain(c: *const Canvas, out: *term.Out, use_color: bool) void {
    var last_color: u16 = 0;
    var last_bold: bool = false;
    var y: usize = 0;
    while (y < c.rows) : (y += 1) {
        // Trim trailing blanks so the printed tree keeps its silhouette.
        var end: usize = c.cols;
        while (end > 0) : (end -= 1) {
            const cell = c.cells[y * c.cols + end - 1];
            if (cell.len == 0) continue;
            if (cell.len == 1 and cell.bytes[0] == ' ') continue;
            break;
        }
        var x: usize = 0;
        while (x < end) : (x += 1) {
            const cell = &c.cells[y * c.cols + x];
            if (cell.len == continuation) continue;
            if (use_color) {
                const key: u16 = if (cell.color == 0) 0 else @as(u16, cell.color) + 1;
                if (key != last_color or cell.bold != last_bold) {
                    out.write("\x1b[0m");
                    if (cell.color != 0) {
                        if (cell.bold) out.write("\x1b[1m");
                        out.print("\x1b[38;5;{d}m", .{cell.color});
                    }
                    last_color = key;
                    last_bold = cell.bold;
                }
            }
            out.write(cell.text());
        }
        if (use_color) out.write("\x1b[0m");
        out.writeByte('\n');
        last_color = 0;
        last_bold = false;
    }
    out.flush();
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "charWidth covers ascii, cjk and combining marks" {
    try std.testing.expectEqual(@as(u2, 1), charWidth('a'));
    try std.testing.expectEqual(@as(u2, 1), charWidth('&'));
    try std.testing.expectEqual(@as(u2, 2), charWidth(0x82B1)); // 花
    try std.testing.expectEqual(@as(u2, 0), charWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(usize, 5), textWidth("花&&&"));
}

test "canvas clips writing outside the grid" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 6);
    defer c.deinit();

    _ = c.putText(0, -3, "abcdef", 1, false); // partly left of the grid
    _ = c.putText(3, 4, "xyz", 1, false); // runs off the right edge
    _ = c.putText(4, 0, "boom", 1, false); // whole row below the grid
    c.putCodepoint(1, 5, 0x82B1, 1, false); // wide glyph in the last column

    // "abcdef" at x=-3 leaves "def" in columns 0..2
    try std.testing.expectEqualSlices(u8, "d", c.at(0, 0).?.text());
    try std.testing.expectEqualSlices(u8, "f", c.at(0, 2).?.text());
    try std.testing.expect(c.at(0, 3).?.isBlank());
    // "xyz" at column 4 only fits "xy"
    try std.testing.expectEqualSlices(u8, "x", c.at(3, 4).?.text());
    try std.testing.expectEqualSlices(u8, "y", c.at(3, 5).?.text());
    // the wide glyph is stored in the last column without a continuation cell
    try std.testing.expectEqualSlices(u8, "花", c.at(1, 5).?.text());
}

fn drainPipe(fd: term.fd_t) []u8 {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        // The write end stays open, so only read what is actually buffered.
        if (!term.pollInput(fd, 0)) break;
        const r = std.os.linux.read(fd, &buf, buf.len);
        if (std.os.linux.errno(r) != .SUCCESS or r == 0) break;
        out.appendSlice(gpa, buf[0..r]) catch break;
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

test "renderer emits the frame and then only the diff" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 3, 12);
    defer c.deinit();

    var fds: [2]term.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
        return error.SkipZigTest;
    }
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    var out = term.Out.init(fds[1]);
    var r = Renderer.init(gpa);
    defer r.deinit();

    c.putAscii(1, 2, "/~", 3, true);
    try r.draw(&c, &out);
    const first = drainPipe(fds[0]);
    defer gpa.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "/~") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[38;5;3m") != null);

    // Nothing changed: the second frame must be empty.
    try r.draw(&c, &out);
    const second = drainPipe(fds[0]);
    defer gpa.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);

    // A single new glyph produces exactly one positioned run.
    c.putAscii(1, 5, "&", 2, false);
    try r.draw(&c, &out);
    const third = drainPipe(fds[0]);
    defer gpa.free(third);
    try std.testing.expect(std.mem.indexOf(u8, third, "\x1b[2;6H") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "&") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "/~") == null);
}

test "overwriting half of a double-width glyph clears it" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 2, 8);
    defer c.deinit();

    c.putCodepoint(0, 2, 0x82B1, 1, false); // 花 occupies columns 2 and 3
    try std.testing.expect(c.at(0, 2).?.wide);
    try std.testing.expectEqual(continuation, c.at(0, 3).?.len);

    // Writing into the trailing half must not leave half a glyph behind.
    c.putCodepoint(0, 3, 'x', 1, false);
    try std.testing.expect(c.at(0, 2).?.isBlank());
    try std.testing.expectEqualSlices(u8, "x", c.at(0, 3).?.text());

    // Same the other way round: a wide glyph replaces the cell after it.
    c.putCodepoint(0, 2, 0x82B1, 1, false);
    c.putCodepoint(0, 3, 'y', 1, false);
    c.putCodepoint(0, 3, 0x82B1, 1, false);
    try std.testing.expect(c.at(0, 4).?.len == continuation);
}
