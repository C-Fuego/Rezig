//! Word-wrapping and the framed message box cbonsai shows next to the tree.
//!
//! cbonsai wraps with `wcwidth()` before creating its ncurses windows; we do
//! the same thing with `canvas.charWidth` so that the layout and the drawing
//! agree, and then draw the box directly into the cell grid.
const std = @import("std");
const canvas = @import("canvas.zig");
const base = @import("base.zig");

pub const Allocator = std.mem.Allocator;

pub const Layout = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,
    /// Widest line, in terminal columns.
    max_width: usize = 0,
    /// Width the text was wrapped to.
    wrap_width: usize = 0,

    pub const Line = struct {
        start: usize,
        len: usize,
        width: usize,
    };

    pub fn deinit(self: *Layout) void {
        self.bytes.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn line(self: *const Layout, i: usize) []const u8 {
        const l = self.lines.items[i];
        return self.bytes.items[l.start..][0..l.len];
    }

    pub fn count(self: *const Layout) usize {
        return self.lines.items.len;
    }
};

fn sanitize(cp: u21, max_width: usize) u21 {
    if (cp < 0x20 or cp == 0x7F) return '?';
    if (canvas.charWidth(cp) > max_width) return '?';
    return cp;
}

const Builder = struct {
    gpa: Allocator,
    layout: *Layout,
    max_width: usize,
    line_start: usize = 0,
    line_width: usize = 0,
    pending_space: bool = false,
    word: std.ArrayList(u8) = .empty,
    word_width: usize = 0,
    err: ?Allocator.Error = null,

    fn pushLine(self: *Builder) void {
        if (self.err != null) return;
        const len = self.layout.bytes.items.len - self.line_start;
        self.layout.lines.append(self.gpa, .{
            .start = self.line_start,
            .len = len,
            .width = self.line_width,
        }) catch |e| {
            self.err = e;
            return;
        };
        if (self.line_width > self.layout.max_width) self.layout.max_width = self.line_width;
        self.line_start = self.layout.bytes.items.len;
        self.line_width = 0;
    }

    fn appendChar(self: *Builder, cp: u21) void {
        if (self.err != null) return;
        const width = canvas.charWidth(cp);
        if (width > 0 and self.line_width > 0 and self.line_width + width > self.max_width) {
            self.pushLine();
        }
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        self.layout.bytes.appendSlice(self.gpa, buf[0..n]) catch |e| {
            self.err = e;
            return;
        };
        self.line_width += width;
    }

    fn flushWord(self: *Builder) void {
        if (self.err != null) return;
        if (self.word.items.len == 0) return;
        if (self.pending_space and self.line_width > 0) {
            if (self.line_width + 1 + self.word_width > self.max_width) {
                self.pushLine();
            } else {
                self.appendChar(' ');
            }
        }
        self.pending_space = false;
        var i: usize = 0;
        const items = self.word.items;
        while (i < items.len) {
            const n = std.unicode.utf8ByteSequenceLength(items[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > items.len) break;
            const cp = std.unicode.utf8Decode(items[i..][0..n]) catch {
                i += n;
                continue;
            };
            self.appendChar(sanitize(cp, self.max_width));
            i += n;
        }
        self.word.clearRetainingCapacity();
        self.word_width = 0;
    }
};

/// Wrap `text` into `max_width` display columns. Explicit newlines are kept,
/// runs of whitespace collapse into a single space, and words longer than one
/// line are hard-broken.
pub fn layout(gpa: Allocator, text: []const u8, wrap_width: usize) Allocator.Error!Layout {
    var layout_: Layout = .{ .gpa = gpa, .wrap_width = @max(wrap_width, 1) };
    errdefer layout_.deinit();

    var b = Builder{ .gpa = gpa, .layout = &layout_, .max_width = layout_.wrap_width };
    defer b.word.deinit(gpa);

    var prev_cr = false;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            i += n;
            continue;
        };
        i += n;

        if (cp == '\n' or cp == '\r') {
            if (cp == '\n' and prev_cr) {
                prev_cr = false;
                continue;
            }
            b.flushWord();
            b.pushLine();
            b.pending_space = false;
            prev_cr = cp == '\r';
            continue;
        }
        prev_cr = false;

        if (cp == ' ' or cp == '\t' or cp == 0x0B or cp == 0x0C) {
            b.flushWord();
            b.pending_space = b.line_width > 0;
            continue;
        }

        const safe = sanitize(cp, b.max_width);
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        const len = std.unicode.utf8Encode(safe, &buf) catch 0;
        if (len == 0) continue;
        try b.word.appendSlice(gpa, buf[0..len]);
        b.word_width += canvas.charWidth(safe);
        if (b.err) |e| return e;
    }
    b.flushWord();
    if (b.err) |e| return e;

    // A line with content, or an empty message, still needs one line.
    if (layout_.bytes.items.len != b.line_start or layout_.lines.items.len == 0) b.pushLine();
    if (b.err) |e| return e;
    return layout_;
}

/// Content width cbonsai uses for the message box: a quarter of the terminal,
/// leaving the rest for the tree.
pub fn contentMaxWidth(cols: usize) usize {
    if (cols < 5) return 1;
    return @max((cols - 4) / 4, 1);
}

pub const Box = struct {
    y: i32,
    x: i32,
    width: usize,
    height: usize,
    content_width: usize,
    content_height: usize,
    truncated: bool,
};

/// Draw the box (border + wrapped text) into `c`. Returns null when the
/// terminal is too small for even a minimal box.
pub fn drawBox(c: *canvas.Canvas, l: *const Layout) ?Box {
    const rows = c.rows;
    const cols = c.cols;
    if (rows < 3 or cols < 5) return null;

    const content_width = @max(l.max_width, 1);
    const content_height = @min(l.count(), rows - 2);
    const border_width = content_width + 4;
    const border_height = content_height + 2;

    var border_y: i32 = @as(i32, @intCast(rows * 7 / 10)) - 1;
    var border_x: i32 = @as(i32, @intCast(cols * 7 / 10)) - 2;
    if (border_y < 0) border_y = 0;
    if (border_x < 0) border_x = 0;
    const max_y: i32 = @as(i32, @intCast(rows)) - @as(i32, @intCast(border_height));
    const max_x: i32 = @as(i32, @intCast(cols)) - @as(i32, @intCast(border_width));
    if (border_y > max_y) border_y = @max(max_y, 0);
    if (border_x > max_x) border_x = @max(max_x, 0);

    const by: i32 = border_y;
    const bx: i32 = border_x;

    // ncurses windows are opaque: the whole box erases whatever is underneath,
    // so start with a rectangle of default-coloured spaces.
    var fill_row: i32 = 0;
    while (fill_row < @as(i32, @intCast(border_height))) : (fill_row += 1) {
        var fill_col: i32 = 0;
        while (fill_col < @as(i32, @intCast(border_width))) : (fill_col += 1) {
            c.putCodepoint(by + fill_row, bx + fill_col, ' ', 0, false);
        }
    }

    // Border: "+" in the corners, "-" along the top/bottom, "|" on the sides.
    var row: i32 = 0;
    while (row < @as(i32, @intCast(border_height))) : (row += 1) {
        var col: i32 = 0;
        while (col < @as(i32, @intCast(border_width))) : (col += 1) {
            const is_top = row == 0 or row == @as(i32, @intCast(border_height)) - 1;
            const is_left = col == 0 or col == @as(i32, @intCast(border_width)) - 1;
            const ch: u8 = if (is_top and is_left)
                '+'
            else if (is_top)
                '-'
            else if (is_left)
                '|'
            else
                continue;
            c.putCodepoint(by + row, bx + col, ch, base.text_color, true);
        }
    }

    const truncated = l.count() > content_height;
    var i: usize = 0;
    while (i < content_height) : (i += 1) {
        const text = l.line(i);
        if (text.len != 0) _ = c.putText(by + 1 + @as(i32, @intCast(i)), bx + 2, text, base.text_color, false);
    }
    if (truncated and content_height > 0) {
        const marker: []const u8 = if (content_width >= 3) "..." else ".";
        const marker_x = bx + 2 + @as(i32, @intCast(content_width - marker.len));
        c.putAscii(
            by + 1 + @as(i32, @intCast(content_height - 1)),
            marker_x,
            marker,
            base.text_color,
            false,
        );
    }

    return .{
        .y = by,
        .x = bx,
        .width = border_width,
        .height = border_height,
        .content_width = content_width,
        .content_height = content_height,
        .truncated = truncated,
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "message wrapping respects the requested width" {
    const gpa = std.testing.allocator;
    const text = "the quick brown fox jumps over the lazy dog";
    var l = try layout(gpa, text, 20);
    defer l.deinit();

    try std.testing.expect(l.count() >= 2);
    for (0..l.count()) |i| {
        try std.testing.expect(l.lines.items[i].width <= 20);
        try std.testing.expect(l.line(i).len > 0);
    }
    // Words are never split: rejoining the lines reproduces the sentence.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (0..l.count()) |i| {
        if (i != 0) try joined.append(gpa, ' ');
        try joined.appendSlice(gpa, l.line(i));
    }
    try std.testing.expectEqualStrings(text, joined.items);
}

test "explicit newlines and long words are handled" {
    const gpa = std.testing.allocator;
    var l = try layout(gpa, "one\n\ntwo supercalifragilistic", 10);
    defer l.deinit();

    try std.testing.expectEqualStrings("one", l.line(0));
    try std.testing.expectEqualStrings("", l.line(1));
    // A word that does not fit next to the pending space starts a new line and
    // is then hard-broken, which is what cbonsai's layoutMessage() does.
    try std.testing.expectEqualStrings("two", l.line(2));
    try std.testing.expectEqualStrings("supercalif", l.line(3));
    try std.testing.expectEqualStrings("ragilistic", l.line(4));
    for (0..l.count()) |i| try std.testing.expect(l.lines.items[i].width <= 10);
}

test "empty message still produces one line" {
    const gpa = std.testing.allocator;
    var l = try layout(gpa, "", 10);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.count());
    try std.testing.expectEqual(@as(usize, 0), l.line(0).len);
}

test "message box stays inside a small terminal" {
    const gpa = std.testing.allocator;
    var c = try canvas.Canvas.init(gpa, 12, 34);
    defer c.deinit();
    var l = try layout(gpa, "hello there this is a long message that must wrap", contentMaxWidth(34));
    defer l.deinit();
    const box = drawBox(&c, &l) orelse return error.TestUnexpectedResult;
    try std.testing.expect(box.x >= 0 and box.y >= 0);
    try std.testing.expect(@as(usize, @intCast(box.x)) + box.width <= c.cols);
    try std.testing.expect(@as(usize, @intCast(box.y)) + box.height <= c.rows);
    // Corners are drawn.
    try std.testing.expectEqualSlices(u8, "+", c.at(box.y, box.x).?.text());
    try std.testing.expectEqualSlices(u8, "+", c.at(box.y + @as(i32, @intCast(box.height - 1)), box.x).?.text());
}
