//! Horizontal layout: the six smushing rules of FIGfont 2, line building and
//! figlet's word-wrapping state machine.
//!
//! `smushem` and `smushAmount` are faithful ports of figlet 2.2.5's
//! `smushem()` / `smushamt()`, including the `previous character width < 2`
//! guard and the hardblank preference of universal overlapping. Fitting and
//! full-width modes fall out of the same amount computation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("font.zig");

pub const SM_EQUAL = font.SM_EQUAL;
pub const SM_LOWLINE = font.SM_LOWLINE;
pub const SM_HIERARCHY = font.SM_HIERARCHY;
pub const SM_PAIR = font.SM_PAIR;
pub const SM_BIGX = font.SM_BIGX;
pub const SM_HARDBLANK = font.SM_HARDBLANK;
pub const SM_KERN = font.SM_KERN;
pub const SM_SMUSH = font.SM_SMUSH;

pub const Direction = font.Direction;
pub const Glyph = font.Glyph;

fn indexOfChar(s: []const u8, c: u21) ?usize {
    if (c > 0x7f) return null;
    const b: u8 = @intCast(c);
    return std.mem.indexOfScalar(u8, s, b);
}

fn inSet(s: []const u8, c: u21) bool {
    return indexOfChar(s, c) != null;
}

/// Try to smush two sub-characters. Returns null when no smushing is possible.
///
/// `mode` uses figlet's smushmode bits. `prev_width` and `cur_width` are the
/// widths of the two FIGcharacters being joined; figlet refuses overlap when
/// either is narrower than two columns.
pub fn smushem(
    mode: u32,
    hardblank: u21,
    dir: Direction,
    prev_width: usize,
    cur_width: usize,
    lch_in: u21,
    rch_in: u21,
) ?u21 {
    const lch = lch_in;
    const rch = rch_in;

    if (lch == ' ') return rch;
    if (rch == ' ') return lch;
    if (prev_width < 2 or cur_width < 2) return null;
    if ((mode & SM_SMUSH) == 0) return null;

    if ((mode & 63) == 0) {
        // Universal overlapping: the later character wins, but visible
        // characters win over hardblanks, and for right-to-left text the
        // dominant character is the earlier one in logical (not visual) order.
        if (lch == hardblank) return rch;
        if (rch == hardblank) return lch;
        if (dir == .rtl) return lch;
        return rch;
    }

    if ((mode & SM_HARDBLANK) != 0 and lch == hardblank and rch == hardblank) {
        return lch;
    }
    if (lch == hardblank or rch == hardblank) return null;

    if ((mode & SM_EQUAL) != 0 and lch == rch) return lch;

    if ((mode & SM_LOWLINE) != 0) {
        if (lch == '_' and inSet("|/\\[]{}()<>", rch)) return rch;
        if (rch == '_' and inSet("|/\\[]{}()<>", lch)) return lch;
    }

    if ((mode & SM_HIERARCHY) != 0) {
        const lclass = hierarchyClass(lch);
        const rclass = hierarchyClass(rch);
        if (lclass != null and rclass != null and lclass.? != rclass.?) {
            return if (lclass.? < rclass.?) rch else lch;
        }
    }

    if ((mode & SM_PAIR) != 0) {
        if ((lch == '[' and rch == ']') or (lch == ']' and rch == '[')) return '|';
        if ((lch == '{' and rch == '}') or (lch == '}' and rch == '{')) return '|';
        if ((lch == '(' and rch == ')') or (lch == ')' and rch == '(')) return '|';
    }

    if ((mode & SM_BIGX) != 0) {
        if (lch == '/' and rch == '\\') return '|';
        if (lch == '\\' and rch == '/') return 'Y';
        if (lch == '>' and rch == '<') return 'X';
    }

    return null;
}

/// Hierarchy classes: "|", "/\", "[]", "{}", "()", "<>".
fn hierarchyClass(c: u21) ?u8 {
    return switch (c) {
        '|' => 0,
        '/', '\\' => 1,
        '[', ']' => 2,
        '{', '}' => 3,
        '(', ')' => 4,
        '<', '>' => 5,
        else => null,
    };
}

/// figlet's -m semantics:
///   -m -1 -> full width
///   -m 0  -> kerning
///   -m 1..63 -> controlled smushing with those rules
///   -m < -1 (including the documented -m-2) -> no override (font default)
/// Returns null for "no override".
pub fn layoutModeToSmush(mode: i32) ?u32 {
    if (mode < -1) return null;
    if (mode == 0) return SM_KERN;
    if (mode == -1) return 0;
    return (@as(u32, @intCast(mode)) & 63) | SM_SMUSH;
}

/// Apply one layout-affecting command-line operation to a smush mode.
pub const LayoutOp = union(enum) {
    /// -s / --smush: use the font's own layout
    font_default,
    /// -k / --kerning
    kern,
    /// -W / --full-width
    full_width,
    /// -S: force smushing, keeping the font's rules
    force_smush,
    /// -o / --overflow: universal overlapping
    overlap,
    /// -m N
    mode: i32,
};

pub fn applyLayoutOp(current: u32, font_default: u32, op: LayoutOp) u32 {
    return switch (op) {
        .font_default => font_default,
        .kern => SM_KERN,
        .full_width => 0,
        .force_smush => current | SM_SMUSH,
        .overlap => SM_SMUSH,
        .mode => |m| layoutModeToSmush(m) orelse font_default,
    };
}

pub const Error = error{
    OutOfMemory,
    RenderStuck,
    /// The sink declined the line (I/O error).
    SinkFailed,
};

pub const RenderedLine = struct {
    /// `height` rows, each padded to `width` codepoints. Hardblanks are still
    /// present; the consumer maps them to spaces.
    rows: []const []const u21,
    width: usize,
    height: usize,
};

pub const Sink = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, line: *const RenderedLine) anyerror!void,

    pub fn emit(self: Sink, line: *const RenderedLine) !void {
        return self.call(self.ptr, line);
    }
};

/// One line being built. Rows are fixed-width, which is how FIGfont data is
/// specified (all rows of a glyph have the same width).
const Line = struct {
    a: Allocator,
    height: usize,
    rows: [][]u21,
    width: usize = 0,
    chars: std.ArrayList(u21) = .empty,

    fn init(a: Allocator, height: usize) !Line {
        const rows = try a.alloc([]u21, height);
        for (rows) |*r| r.* = &.{};
        return .{ .a = a, .height = height, .rows = rows };
    }

    fn deinit(self: *Line) void {
        for (self.rows) |r| if (r.len > 0) self.a.free(r);
        self.a.free(self.rows);
        self.chars.deinit(self.a);
    }

    fn clear(self: *Line) void {
        for (self.rows) |*r| {
            if (r.len > 0) self.a.free(r.*);
            r.* = &.{};
        }
        self.width = 0;
        self.chars.clearRetainingCapacity();
    }
};

pub const Renderer = struct {
    a: Allocator,
    font: *font.Font,
    sink: Sink,
    smush_mode: u32,
    /// figlet's outputwidth: lines break when they would reach this column.
    output_width: usize,
    direction: Direction,
    line: Line,
    prev_width: usize = 0,
    /// figlet wordbreakmode: -1 absorb blanks, 0 no break, 1 word, 2 word +
    /// blanks, 3 had a word break.
    wb: i8 = 0,
    finished: bool = false,

    pub fn init(
        a: Allocator,
        f: *font.Font,
        sink: Sink,
        smush_mode: u32,
        output_width: usize,
        direction: Direction,
    ) !Renderer {
        return .{
            .a = a,
            .font = f,
            .sink = sink,
            .smush_mode = smush_mode,
            .output_width = if (output_width == 0) 80 else output_width,
            .direction = direction,
            .line = try Line.init(a, f.height),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.line.deinit();
    }

    fn widthLimit(self: *const Renderer) usize {
        // figlet: outlinelenlimit = outputwidth - 1, except outputwidth == 1
        // (which forces every FIGcharacter onto its own line).
        return if (self.output_width == 1) 0 else self.output_width - 1;
    }

    fn lastNonSpace(row: []const u21) ?usize {
        var i = row.len;
        while (i > 0) {
            i -= 1;
            if (row[i] != ' ') return i;
        }
        return null;
    }

    fn firstNonSpace(g: Glyph, y: usize) ?usize {
        const w = g.width;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (g.cell(y, x) != ' ') return x;
        }
        return null;
    }

    fn lastNonSpaceGlyph(g: Glyph, y: usize) ?usize {
        var x = g.width;
        while (x > 0) {
            x -= 1;
            if (g.cell(y, x) != ' ') return x;
        }
        return null;
    }

    /// Port of figlet's smushamt().
    fn smushAmount(self: *Renderer, g: Glyph) usize {
        if ((self.smush_mode & (SM_SMUSH | SM_KERN)) == 0) return 0;

        var max: usize = g.width;
        const line_w = self.line.width;
        const gw = g.width;

        for (0..self.font.height) |y| {
            const row = self.line.rows[y];
            var amt: isize = 0;

            if (self.direction == .ltr) {
                var line_blank = true;
                var linebd: usize = 0;
                if (line_w > 0) {
                    if (lastNonSpace(row)) |p| {
                        linebd = p;
                        line_blank = false;
                    }
                }
                const charbd_opt = firstNonSpace(g, y);
                const charbd = charbd_opt orelse gw;
                if (line_w == 0) {
                    amt = @as(isize, @intCast(charbd)) - 1;
                } else {
                    amt = @as(isize, @intCast(charbd)) + @as(isize, @intCast(line_w)) -
                        1 - @as(isize, @intCast(linebd));
                }
                if (line_blank) {
                    amt += 1;
                } else if (charbd < gw) {
                    const ch1: u21 = if (line_w > 0 and linebd < row.len) row[linebd] else ' ';
                    const ch2 = g.cell(y, charbd);
                    if (smushem(self.smush_mode, self.font.hardblank, self.direction, self.prev_width, gw, ch1, ch2) != null) {
                        amt += 1;
                    }
                }
            } else {
                // Right-to-left: mirror figlet's rtl branch.
                var linebd: usize = line_w;
                var line_blank = true;
                if (line_w > 0) {
                    var x: usize = 0;
                    while (x < line_w) : (x += 1) {
                        if (row[x] != ' ') {
                            linebd = x;
                            line_blank = false;
                            break;
                        }
                    }
                }
                const charbd_opt = lastNonSpaceGlyph(g, y);
                const charbd = charbd_opt orelse 0;
                const glyph_blank = charbd_opt == null;
                if (line_w == 0) {
                    amt = @as(isize, @intCast(gw)) - 1 - @as(isize, @intCast(charbd));
                } else {
                    amt = @as(isize, @intCast(linebd)) + @as(isize, @intCast(gw)) -
                        1 - @as(isize, @intCast(charbd));
                }
                if (glyph_blank) {
                    amt += 1;
                } else if (!line_blank) {
                    const ch1 = g.cell(y, charbd);
                    const ch2 = if (linebd < row.len) row[linebd] else ' ';
                    if (smushem(self.smush_mode, self.font.hardblank, self.direction, self.prev_width, gw, ch1, ch2) != null) {
                        amt += 1;
                    }
                }
            }

            if (amt < 0) amt = 0;
            max = @min(max, @as(usize, @intCast(amt)));
        }
        return max;
    }

    fn merge(self: *Renderer, g: Glyph, smush: usize) !void {
        const a = self.a;
        const old_w = self.line.width;
        const gw = g.width;
        const new_w = old_w + gw - smush;
        const new_rows = try a.alloc([]u21, self.font.height);
        errdefer a.free(new_rows);

        for (0..self.font.height) |y| {
            const row = try a.alloc(u21, new_w);
            @memset(row, ' ');
            const old_row = self.line.rows[y];

            if (self.direction == .ltr) {
                @memcpy(row[0..old_w], old_row[0..old_w]);
                for (0..gw) |x| {
                    const pos_i = @as(isize, @intCast(old_w)) - @as(isize, @intCast(smush)) +
                        @as(isize, @intCast(x));
                    if (pos_i < 0) continue;
                    const pos: usize = @intCast(pos_i);
                    if (pos >= new_w) continue;
                    const ch = g.cell(y, x);
                    if (x < smush and pos < old_w) {
                        if (smushem(self.smush_mode, self.font.hardblank, self.direction, self.prev_width, gw, row[pos], ch)) |c| {
                            row[pos] = c;
                        }
                    } else {
                        row[pos] = ch;
                    }
                }
            } else {
                // Glyph goes on the left, the old line on the right.
                for (0..gw) |x| row[x] = g.cell(y, x);
                for (0..old_w) |x| {
                    if (x < smush) {
                        const pos = gw - smush + x;
                        const ch = old_row[x];
                        if (smushem(self.smush_mode, self.font.hardblank, self.direction, self.prev_width, gw, row[pos], ch)) |c| {
                            row[pos] = c;
                        }
                    } else {
                        row[gw + x - smush] = old_row[x];
                    }
                }
            }

            if (old_row.len > 0) a.free(old_row);
            new_rows[y] = row;
        }

        a.free(self.line.rows);
        self.line.rows = new_rows;
        self.line.width = new_w;
    }

    fn addChar(self: *Renderer, c: u21) !bool {
        const g = self.font.glyph(c);
        const smush = self.smushAmount(g);
        const limit = self.widthLimit();
        if (g.width > 0 and self.line.width + g.width - smush > limit) return false;
        try self.merge(g, smush);
        try self.line.chars.append(self.a, c);
        self.prev_width = g.width;
        return true;
    }

    fn emitCurrent(self: *Renderer) !void {
        var rows = try self.a.alloc([]const u21, self.font.height);
        defer self.a.free(rows);
        for (0..self.font.height) |y| {
            rows[y] = self.line.rows[y][0..self.line.width];
        }
        var rl = RenderedLine{
            .rows = rows,
            .width = self.line.width,
            .height = self.font.height,
        };
        self.sink.emit(&rl) catch return error.SinkFailed;
    }

    fn printLine(self: *Renderer) !void {
        try self.emitCurrent();
        self.line.clear();
        self.prev_width = 0;
    }

    fn printGlyphAlone(self: *Renderer, c: u21) !void {
        const g = self.font.glyph(c);
        const rows = try self.a.alloc([]const u21, self.font.height);
        defer self.a.free(rows);
        for (0..self.font.height) |y| {
            const row = try self.a.alloc(u21, g.width);
            for (0..g.width) |x| row[x] = g.cell(y, x);
            rows[y] = row;
        }
        defer for (rows) |r| self.a.free(r);
        var rl = RenderedLine{ .rows = rows, .width = g.width, .height = self.font.height };
        self.sink.emit(&rl) catch return error.SinkFailed;
        self.prev_width = g.width;
    }

    fn splitLine(self: *Renderer) !void {
        const chars = self.line.chars.items;
        const n = chars.len;
        if (n == 0) return;

        var gotspace = false;
        var lastspace: usize = n - 1;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            if (!gotspace and chars[i] == ' ') {
                gotspace = true;
                lastspace = i;
            }
            if (gotspace and chars[i] != ' ') break;
        }
        if (!gotspace) return;
        const len1: usize = i + 1;
        const len2: usize = n - lastspace - 1;

        const part1 = try self.a.dupe(u21, chars[0..len1]);
        defer self.a.free(part1);
        const part2 = try self.a.dupe(u21, chars[lastspace + 1 .. lastspace + 1 + len2]);
        defer self.a.free(part2);

        self.line.clear();
        self.prev_width = 0;
        for (part1) |ch| _ = try self.addChar(ch);
        try self.printLine();
        for (part2) |ch| _ = try self.addChar(ch);
    }

    /// figlet's main loop, transcribed. Newlines may be absorbed after a
    /// forced break (wordbreakmode -1) exactly as in the original.
    pub fn feed(self: *Renderer, c: u21) !void {
        var guard: usize = 0;
        while (true) {
            guard += 1;
            if (guard > 8) return error.RenderStuck;
            var retry = false;

            if (self.wb == -1) {
                if (c == ' ') return;
                if (c == '\n') {
                    self.wb = 0;
                    return;
                }
                self.wb = 0;
            }

            if (c == '\n') {
                try self.printLine();
                self.wb = 0;
            } else if (try self.addChar(c)) {
                if (c != ' ') {
                    self.wb = if (self.wb >= 2) 3 else 1;
                } else {
                    self.wb = if (self.wb > 0) 2 else 0;
                }
            } else if (self.line.chars.items.len == 0) {
                try self.printGlyphAlone(c);
                self.wb = -1;
            } else if (c == ' ') {
                if (self.wb == 2) try self.splitLine() else try self.printLine();
                self.wb = -1;
            } else {
                if (self.wb >= 2) try self.splitLine() else try self.printLine();
                self.wb = if (self.wb == 3) 1 else 0;
                retry = true;
            }

            if (!retry) return;
        }
    }

    /// Flush a partial line at end of input. figlet only flushes when the line
    /// has non-zero rendered width.
    pub fn finish(self: *Renderer) !void {
        if (self.finished) return;
        self.finished = true;
        if (self.line.width != 0) try self.printLine();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "gzip-compressed real font renders byte-identically to the plain font" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // mini.flf comes from refs/figlet/fonts (New BSD), compressed with
    // `gzip -9 -n` so the fixture is deterministic.
    try tmp.dir.writeFile(io, .{ .sub_path = "mini.flf.gz", .data = @embedFile("testdata/mini.flf.gz") });
    const dir = try tmpFontDir(a, &tmp);
    defer a.free(dir);

    var diag: font.Diag = .{};
    var plain = try font.Font.parse(a, @embedFile("testdata/mini.flf"), "mini", &diag);
    defer plain.deinit();
    var gz_font = try font.load(io, a, &.{dir}, "mini", &diag);
    defer gz_font.deinit();

    const want = try renderToString(a, &plain, "Hello 42");
    defer a.free(want);
    const got = try renderToString(a, &gz_font, "Hello 42");
    defer a.free(got);
    try testing.expectEqualStrings(want, got);
}

test "zip real font (deflate and stored entries) renders byte-identically" {
    const a = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // mini.flf.zip is method 8 (deflate); mini_stored.flf.zip is method 0.
    try tmp.dir.writeFile(io, .{
        .sub_path = "mini.flf.zip",
        .data = @embedFile("testdata/mini.flf.zip"),
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "ministored.flf.zip",
        .data = @embedFile("testdata/mini_stored.flf.zip"),
    });
    const dir = try tmpFontDir(a, &tmp);
    defer a.free(dir);

    var diag: font.Diag = .{};
    var plain = try font.Font.parse(a, @embedFile("testdata/mini.flf"), "mini", &diag);
    defer plain.deinit();
    const want = try renderToString(a, &plain, "Hello 42");
    defer a.free(want);

    var deflated = try font.load(io, a, &.{dir}, "mini", &diag);
    defer deflated.deinit();
    const got_deflate = try renderToString(a, &deflated, "Hello 42");
    defer a.free(got_deflate);
    try testing.expectEqualStrings(want, got_deflate);

    var stored = try font.load(io, a, &.{dir}, "ministored", &diag);
    defer stored.deinit();
    const got_stored = try renderToString(a, &stored, "Hello 42");
    defer a.free(got_stored);
    try testing.expectEqualStrings(want, got_stored);
}

test "smushing rule 1: equal characters" {
    const hb: u21 = '$';
    try testing.expectEqual(@as(?u21, '_'), smushem(SM_SMUSH | SM_EQUAL, hb, .ltr, 3, 3, '_', '_'));
    // Hardblanks never smush under rule 1.
    try testing.expectEqual(@as(?u21, null), smushem(SM_SMUSH | SM_EQUAL, hb, .ltr, 3, 3, hb, hb));
    // Without rule 1 (only the lowline rule enabled) underscores do not mix.
    try testing.expectEqual(@as(?u21, null), smushem(SM_SMUSH | SM_LOWLINE, hb, .ltr, 3, 3, '_', '_'));
}

test "smushing rules 2-5 and the width guard" {
    const hb: u21 = '$';
    const r = SM_SMUSH | SM_LOWLINE | SM_HIERARCHY | SM_PAIR | SM_BIGX;
    try testing.expectEqual(@as(?u21, '/'), smushem(r, hb, .ltr, 3, 3, '_', '/'));
    try testing.expectEqual(@as(?u21, ']'), smushem(r, hb, .ltr, 3, 3, '|', ']'));
    try testing.expectEqual(@as(?u21, '|'), smushem(r, hb, .ltr, 3, 3, '[', ']'));
    try testing.expectEqual(@as(?u21, 'Y'), smushem(r, hb, .ltr, 3, 3, '\\', '/'));
    try testing.expectEqual(@as(?u21, 'X'), smushem(r, hb, .ltr, 3, 3, '>', '<'));
    // "<>" is not smushed by BIG X.
    try testing.expectEqual(@as(?u21, null), smushem(r, hb, .ltr, 3, 3, '<', '>'));
    // figlet refuses overlap for one-column FIGcharacters.
    try testing.expectEqual(@as(?u21, null), smushem(r, hb, .ltr, 1, 3, '_', '_'));
}

test "universal overlapping prefers visible characters" {
    const hb: u21 = '$';
    try testing.expectEqual(@as(?u21, 'a'), smushem(SM_SMUSH, hb, .ltr, 3, 3, hb, 'a'));
    try testing.expectEqual(@as(?u21, 'a'), smushem(SM_SMUSH, hb, .ltr, 3, 3, 'a', hb));
    try testing.expectEqual(@as(?u21, 'b'), smushem(SM_SMUSH, hb, .ltr, 3, 3, 'a', 'b'));
    try testing.expectEqual(@as(?u21, 'a'), smushem(SM_SMUSH, hb, .rtl, 3, 3, 'a', 'b'));
}

test "layout mode bits" {
    try testing.expectEqual(@as(?u32, null), layoutModeToSmush(-2));
    try testing.expectEqual(@as(?u32, null), layoutModeToSmush(-3));
    try testing.expectEqual(@as(?u32, SM_KERN), layoutModeToSmush(0).?);
    try testing.expectEqual(@as(?u32, 0), layoutModeToSmush(-1).?);
    try testing.expectEqual(@as(?u32, 143), layoutModeToSmush(15).?); // smush + rules 1,2,4,8
    try testing.expectEqual(@as(?u32, 191), layoutModeToSmush(63).?);

    const fd: u32 = 143;
    try testing.expectEqual(@as(u32, SM_KERN), applyLayoutOp(fd, fd, .kern));
    try testing.expectEqual(@as(u32, 0), applyLayoutOp(fd, fd, .full_width));
    try testing.expectEqual(@as(u32, 143), applyLayoutOp(0, fd, .font_default));
    try testing.expectEqual(@as(u32, 128), applyLayoutOp(fd, fd, .force_smush) & 128);
    try testing.expectEqual(@as(u32, SM_SMUSH), applyLayoutOp(fd, fd, .overlap));
}

const Collector = struct {
    a: Allocator,
    lines: std.ArrayList(OwnedLine) = .empty,

    const OwnedLine = struct { rows: [][]u21, width: usize };

    fn sink(self: *Collector) Sink {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, line: *const RenderedLine) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        const rows = try self.a.alloc([]u21, line.height);
        for (0..line.height) |y| {
            rows[y] = try self.a.alloc(u21, line.width);
            @memcpy(rows[y], line.rows[y]);
        }
        try self.lines.append(self.a, .{ .rows = rows, .width = line.width });
    }

    fn deinit(self: *Collector) void {
        for (self.lines.items) |l| {
            for (l.rows) |r| self.a.free(r);
            self.a.free(l.rows);
        }
        self.lines.deinit(self.a);
    }
};

test "width-based wrapping keeps words together and breaks long words" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(testing.allocator, @embedFile("testdata/tiny.flf"), "tiny", &diag);
    defer f.deinit();

    var col: Collector = .{ .a = testing.allocator };
    defer col.deinit();

    // tiny.flf: every glyph is 3 columns, full width.
    var r = try Renderer.init(testing.allocator, &f, col.sink(), 0, 10, .ltr);
    defer r.deinit();
    for ("AB CD") |ch| try r.feed(ch);
    try r.finish();

    // "AB CD" needs 15 columns; splitLine trims the trailing blank, so the
    // first line is "AB" (6 columns) and the second is "CD" (6 columns).
    try testing.expectEqual(@as(usize, 2), col.lines.items.len);
    try testing.expectEqual(@as(usize, 6), col.lines.items[0].width);
    try testing.expectEqual(@as(usize, 6), col.lines.items[1].width);

    // A word longer than the line is broken by width.
    var col2: Collector = .{ .a = testing.allocator };
    defer col2.deinit();
    var r2 = try Renderer.init(testing.allocator, &f, col2.sink(), 0, 7, .ltr);
    defer r2.deinit();
    for ("ABCDE") |ch| try r2.feed(ch);
    try r2.finish();
    try testing.expectEqual(@as(usize, 3), col2.lines.items.len);
    try testing.expectEqual(@as(usize, 6), col2.lines.items[0].width); // AB
    try testing.expectEqual(@as(usize, 6), col2.lines.items[1].width); // CD
    try testing.expectEqual(@as(usize, 3), col2.lines.items[2].width); // E
}

test "empty input lines are preserved as blank FIGlet lines" {
    var diag: font.Diag = .{};
    var f = try font.Font.parse(testing.allocator, @embedFile("testdata/tiny.flf"), "tiny", &diag);
    defer f.deinit();
    var col: Collector = .{ .a = testing.allocator };
    defer col.deinit();
    var r = try Renderer.init(testing.allocator, &f, col.sink(), 0, 80, .ltr);
    defer r.deinit();
    try r.feed('\n');
    try r.feed('\n');
    try r.finish();
    try testing.expectEqual(@as(usize, 2), col.lines.items.len);
    try testing.expectEqual(@as(usize, 0), col.lines.items[0].width);
}

fn renderToString(a: Allocator, f: *font.Font, text: []const u8) ![]u8 {
    var col: Collector = .{ .a = a };
    defer col.deinit();
    var r = try Renderer.init(a, f, col.sink(), f.font_smush, 80, .ltr);
    defer r.deinit();
    for (text) |ch| try r.feed(ch);
    try r.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4]u8 = undefined;
    for (col.lines.items) |line| {
        for (line.rows) |row| {
            for (row) |c| {
                const ch: u21 = if (c == f.hardblank) ' ' else c;
                const n = try std.unicode.utf8Encode(ch, &buf);
                try out.appendSlice(a, buf[0..n]);
            }
            try out.append(a, '\n');
        }
    }
    return out.toOwnedSlice(a);
}

fn tmpFontDir(a: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.testing.TmpDir.parent_dir_path, tmp.sub_path[0..] });
}
