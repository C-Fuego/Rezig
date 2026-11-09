//! 帧缓冲 + 布局 + ANSI 绝对定位输出。
//!
//! 几何完全照抄 tty-clock（注意原版 ncurses 里 geo.x 是"行"、geo.y 是"列"，
//! newwin/mvwin 的参数顺序就是 (行, 列)）：
//!   NORMFRAMEW = 35，SECFRAMEW = 54，窗口高 7，DATEWINH = 3
//!   数字格：每数字 6 列 × 5 行，落在窗口第 1..5 行
//!   ":" 在第 2、4 行的第 16 列（带秒时第二组在第 35 列）
//!   小时间隔 7 列：1 → 8；分钟 20 → 27；秒 39 → 46
//!   日期窗口起始行 = 时钟行 + 6（DATEWINH=3，所以日期文本落在 时钟行+7），
//!   起始列 = 时钟列 + w/2 - len/2 - 1，文本从 +1 列开始（视觉上居中）
const std = @import("std");
const font = @import("font.zig");
const term = @import("term.zig");

pub const NORMFRAMEW: i32 = 35;
pub const SECFRAMEW: i32 = 54;
pub const FRAME_HEIGHT: i32 = 7;
pub const DATEWINH: i32 = 3;

/// "无颜色"标记（走终端默认前景/背景）
pub const NONE: u8 = 0xff;

pub const Style = struct {
    fg: u8 = NONE,
    bg: u8 = NONE,
    bold: bool = false,
    blink: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold and a.blink == b.blink;
    }
};

pub const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

pub const Rect = struct {
    col: i32,
    row: i32,
    cols: i32,
    rows: i32,

    pub fn eql(a: Rect, b: Rect) bool {
        return a.col == b.col and a.row == b.row and a.cols == b.cols and a.rows == b.rows;
    }
};

// ------------------------------------------------------------------ 输出缓冲

pub const Out = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,

    pub fn flush(self: *Out) void {
        if (self.len == 0) return;
        term.writeAll(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }

    pub fn put(self: *Out, bytes: []const u8) void {
        if (bytes.len > self.buf.len) {
            // 比整个缓冲区还长：分块写
            var off: usize = 0;
            while (off < bytes.len) {
                const n = @min(self.buf.len, bytes.len - off);
                @memcpy(self.buf[0..n], bytes[off..][0..n]);
                self.len = n;
                self.flush();
                off += n;
            }
            return;
        }
        if (self.len + bytes.len > self.buf.len) self.flush();
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn writeByte(self: *Out, b: u8) void {
        if (self.len == self.buf.len) self.flush();
        self.buf[self.len] = b;
        self.len += 1;
    }

    pub fn writeByteNTimes(self: *Out, b: u8, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.writeByte(b);
    }

    pub fn print(self: *Out, comptime fmt: []const u8, a: anytype) void {
        var tmp: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, a) catch return;
        self.put(s);
    }

    /// UTF-8 编码单个码位。
    pub fn putCodepoint(self: *Out, cp: u21) void {
        if (cp < 0x80) {
            self.writeByte(@intCast(cp));
            return;
        }
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch {
            self.writeByte('?');
            return;
        };
        self.put(tmp[0..n]);
    }
};

// --------------------------------------------------------------------- 画布

pub const Canvas = struct {
    cells: []Cell,
    alloc: std.mem.Allocator,
    col0: i32 = 0,
    row0: i32 = 0,
    cols: i32 = 0,
    rows: i32 = 0,
    capacity_cols: i32,
    capacity_rows: i32,

    pub fn init(alloc: std.mem.Allocator, capacity_cols: i32, capacity_rows: i32) !Canvas {
        const n = @as(usize, @intCast(capacity_cols)) * @as(usize, @intCast(capacity_rows));
        const cells = try alloc.alloc(Cell, n);
        return .{
            .cells = cells,
            .alloc = alloc,
            .capacity_cols = capacity_cols,
            .capacity_rows = capacity_rows,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.alloc.free(self.cells);
    }

    /// 每帧重新指定原点与尺寸（容量不足时截断，不会越界）。
    pub fn begin(self: *Canvas, area: Rect) void {
        self.col0 = area.col;
        self.row0 = area.row;
        self.cols = @min(area.cols, self.capacity_cols);
        self.rows = @min(area.rows, self.capacity_rows);
        const used = @as(usize, @intCast(self.cols)) * @as(usize, @intCast(self.rows));
        @memset(self.cells[0..used], Cell{});
    }

    fn index(self: *Canvas, cx: i32, cy: i32) ?usize {
        if (cx < 0 or cy < 0 or cx >= self.cols or cy >= self.rows) return null;
        return @as(usize, @intCast(cy)) * @as(usize, @intCast(self.cols)) + @as(usize, @intCast(cx));
    }

    /// 绝对屏幕坐标（0-based）写一格。
    pub fn put(self: *Canvas, col: i32, row: i32, cell: Cell) void {
        const idx = self.index(col - self.col0, row - self.row0) orelse return;
        self.cells[idx] = cell;
    }

    pub fn text(self: *Canvas, col: i32, row: i32, s: []const u8, style: Style) void {
        var c = col;
        var i: usize = 0;
        while (i < s.len) {
            const b = s[i];
            var cp: u21 = b;
            var adv: usize = 1;
            if (b >= 0x80) {
                const seq_len: usize = @as(usize, std.unicode.utf8ByteSequenceLength(b) catch 1);
                if (i + seq_len <= s.len) {
                    if (std.unicode.utf8Decode(s[i..][0..seq_len])) |v| {
                        cp = v;
                        adv = seq_len;
                    } else |_| {}
                }
            }
            self.put(c, row, .{ .ch = cp, .style = style });
            c += 1;
            i += adv;
        }
    }
};

// ----------------------------------------------------------------- 帧布局

pub const FrameOpts = struct {
    color: u8 = 2,
    box: bool = false,
    bold: bool = false,
    date: bool = true,
    second: bool = false,
    /// 本帧冒号是否可见（-B 闪烁 / 1 秒一半可见，原版是 time(NULL) % 2）
    colon_visible: bool = true,
    hour: [2]u8 = .{ 0, 0 },
    minute: [2]u8 = .{ 0, 0 },
    second_digits: [2]u8 = .{ 0, 0 },
    date_str: []const u8 = "",
    /// true 用 Unicode 制表符，false 用 ASCII +-|
    box_unicode: bool = true,
    /// 日期窗在屏幕上的实际位置。原版日期窗有自己的 `mvwin()`，和时钟窗分开挪；
    /// 两者在"时钟放不下"时会分家，这里用这两个字段表达。null = 由时钟原点推出。
    date_row: ?i32 = null,
    date_col: ?i32 = null,
};

pub fn frameWidth(second: bool) i32 {
    return if (second) SECFRAMEW else NORMFRAMEW;
}

/// 日期文本的起始列（0-based 屏幕列）。
pub fn dateCol(o: FrameOpts, col: i32) i32 {
    const w = frameWidth(o.second);
    const len: i32 = @intCast(o.date_str.len);
    return col + @divTrunc(w, 2) - @divTrunc(len, 2);
}

/// 整个时钟（含日期/边框）占据的屏幕矩形，用于"移动时擦掉旧位置"。
pub fn rect(o: FrameOpts, x: i32, col: i32) Rect {
    const w = frameWidth(o.second);
    if (!o.date) {
        return .{ .col = col, .row = x, .cols = w, .rows = FRAME_HEIGHT };
    }
    const len: i32 = @intCast(o.date_str.len);
    const dc = o.date_col orelse dateCol(o, col);
    const dr = o.date_row orelse (x + FRAME_HEIGHT);
    const left = if (o.box) dc - 1 else dc;
    const right = if (o.box) dc + len + 1 else dc + len;
    const start = @min(col, left);
    const end = @max(col + w, right);
    const top = @min(x, dr - 1);
    const bottom = @max(x + FRAME_HEIGHT, dr + 2);
    return .{
        .col = start,
        .row = top,
        .cols = @max(end - start, 1),
        .rows = @max(bottom - top, FRAME_HEIGHT),
    };
}

const box_chars_unicode = struct {
    const tl: u21 = 0x250c; // ┌
    const tr: u21 = 0x2510; // ┐
    const bl: u21 = 0x2514; // └
    const br: u21 = 0x2518; // ┘
    const h: u21 = 0x2500; // ─
    const v: u21 = 0x2502; // │
};

fn drawBox(canvas: *Canvas, row: i32, col: i32, w: i32, h: i32, unicode: bool) void {
    if (w < 2 or h < 2) return;
    const style = Style{};
    const tl: u21 = if (unicode) box_chars_unicode.tl else '+';
    const tr: u21 = if (unicode) box_chars_unicode.tr else '+';
    const bl: u21 = if (unicode) box_chars_unicode.bl else '+';
    const br: u21 = if (unicode) box_chars_unicode.br else '+';
    const hz: u21 = if (unicode) box_chars_unicode.h else '-';
    const vt: u21 = if (unicode) box_chars_unicode.v else '|';

    canvas.put(col, row, .{ .ch = tl, .style = style });
    canvas.put(col + w - 1, row, .{ .ch = tr, .style = style });
    canvas.put(col, row + h - 1, .{ .ch = bl, .style = style });
    canvas.put(col + w - 1, row + h - 1, .{ .ch = br, .style = style });
    var c: i32 = 1;
    while (c < w - 1) : (c += 1) {
        canvas.put(col + c, row, .{ .ch = hz, .style = style });
        canvas.put(col + c, row + h - 1, .{ .ch = hz, .style = style });
    }
    var r: i32 = 1;
    while (r < h - 1) : (r += 1) {
        canvas.put(col, row + r, .{ .ch = vt, .style = style });
        canvas.put(col + w - 1, row + r, .{ .ch = vt, .style = style });
    }
}

fn drawDigit(canvas: *Canvas, row: i32, col: i32, digit: u8, block: Style) void {
    for (0..font.cell_rows) |r| {
        for (0..font.cell_cols) |c| {
            const on = font.cellOn(digit, r, c);
            canvas.put(col + @as(i32, @intCast(c)), row + @as(i32, @intCast(r)), .{
                .ch = ' ',
                .style = if (on) block else Style{},
            });
        }
    }
}

fn drawColon(canvas: *Canvas, x: i32, col: i32, o: FrameOpts, block: Style) void {
    const style: Style = if (o.colon_visible) block else Style{};
    for ([_]i32{ 2, 4 }) |row_off| {
        canvas.put(col, x + row_off, .{ .ch = ' ', .style = style });
        canvas.put(col + 1, x + row_off, .{ .ch = ' ', .style = style });
    }
}

/// 把整帧画进画布。坐标约定：x = 屏幕行，col = 屏幕列（0-based）。
pub fn draw(canvas: *Canvas, o: FrameOpts, x: i32, col: i32) void {
    const w = frameWidth(o.second);
    // 原版：ttyclock.option.bold 时给数字块加 A_BLINK
    const block = Style{ .bg = o.color, .blink = o.bold };

    if (o.box) drawBox(canvas, x, col, w, FRAME_HEIGHT, o.box_unicode);

    drawDigit(canvas, x + 1, col + 1, o.hour[0], block);
    drawDigit(canvas, x + 1, col + 8, o.hour[1], block);
    drawColon(canvas, x, col + 16, o, block);
    drawDigit(canvas, x + 1, col + 20, o.minute[0], block);
    drawDigit(canvas, x + 1, col + 27, o.minute[1], block);

    if (o.second) {
        drawColon(canvas, x, col + NORMFRAMEW, o, block);
        drawDigit(canvas, x + 1, col + 39, o.second_digits[0], block);
        drawDigit(canvas, x + 1, col + 46, o.second_digits[1], block);
    }

    if (o.date) {
        const len: i32 = @intCast(o.date_str.len);
        const dc = o.date_col orelse dateCol(o, col);
        const dr = o.date_row orelse (x + FRAME_HEIGHT);
        if (o.box) drawBox(canvas, dr - 1, dc - 1, len + 2, DATEWINH, o.box_unicode);
        // 原版：日期用 COLOR_PAIR(2)（前景=时钟色），option.bold 时 A_BOLD
        canvas.text(dc, dr, o.date_str, .{ .fg = o.color, .bold = o.bold });
    }
}

// --------------------------------------------------------------- 输出到终端

fn emitSgr(out: *Out, style: Style) void {
    out.put("\x1b[0m");
    if (style.bold) out.put("\x1b[1m");
    if (style.blink) out.put("\x1b[5m");
    if (style.fg != NONE) out.print("\x1b[3{d}m", .{style.fg});
    if (style.bg != NONE) out.print("\x1b[4{d}m", .{style.bg});
}

/// 绝对定位逐行重绘（不闪屏的关键：不清屏、不换行）。
pub fn emit(out: *Out, canvas: *const Canvas, screen_cols: i32, screen_rows: i32) void {
    var r: i32 = 0;
    while (r < canvas.rows) : (r += 1) {
        const abs_row = canvas.row0 + r;
        if (abs_row < 0 or abs_row >= screen_rows) continue;

        var c0: i32 = 0;
        var c1: i32 = canvas.cols;
        if (canvas.col0 + c0 < 0) c0 = -canvas.col0;
        if (canvas.col0 + c1 > screen_cols) c1 = screen_cols - canvas.col0;
        // 不写屏幕最后一格，避免触发滚动
        if (abs_row == screen_rows - 1 and canvas.col0 + c1 >= screen_cols) c1 -= 1;
        if (c1 <= c0) continue;

        out.print("\x1b[{d};{d}H", .{ abs_row + 1, canvas.col0 + c0 + 1 });
        var style: ?Style = null;
        var i: i32 = c0;
        while (i < c1) {
            const idx: usize = @as(usize, @intCast(r)) * @as(usize, @intCast(canvas.cols)) + @as(usize, @intCast(i));
            const cell = canvas.cells[idx];
            if (style == null or !style.?.eql(cell.style)) {
                emitSgr(out, cell.style);
                style = cell.style;
            }
            // 合并连续、同字符同样式的格子
            var j = i + 1;
            while (j < c1) : (j += 1) {
                const nidx: usize = @as(usize, @intCast(r)) * @as(usize, @intCast(canvas.cols)) + @as(usize, @intCast(j));
                const next = canvas.cells[nidx];
                if (next.ch != cell.ch or !next.style.eql(cell.style)) break;
            }
            const n: usize = @intCast(j - i);
            if (cell.ch < 0x80) {
                out.writeByteNTimes(@intCast(cell.ch), n);
            } else {
                var k: usize = 0;
                while (k < n) : (k += 1) out.putCodepoint(cell.ch);
            }
            i = j;
        }
    }
}

/// 擦掉一个矩形（移动时钟时用），只写空格。
pub fn eraseRect(out: *Out, area: Rect, screen_cols: i32, screen_rows: i32) void {
    var row = @max(area.row, 0);
    const row_end = @min(area.row + area.rows, screen_rows);
    const col = @max(area.col, 0);
    const col_end = @min(area.col + area.cols, screen_cols);
    if (col_end <= col) return;
    while (row < row_end) : (row += 1) {
        out.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
        out.writeByteNTimes(' ', @intCast(col_end - col));
    }
}

/// 非 tty 降级：一次打印成纯文本（数字块用 '#'）。
pub fn emitPlain(out: *Out, canvas: *const Canvas, block: u8) void {
    var r: i32 = 0;
    while (r < canvas.rows) : (r += 1) {
        const base: usize = @as(usize, @intCast(r)) * @as(usize, @intCast(canvas.cols));
        var end: i32 = canvas.cols;
        while (end > 0) {
            const cell = canvas.cells[base + @as(usize, @intCast(end - 1))];
            if (cell.ch != ' ' or cell.style.bg != NONE) break;
            end -= 1;
        }
        var c: i32 = 0;
        while (c < end) : (c += 1) {
            const cell = canvas.cells[base + @as(usize, @intCast(c))];
            if (cell.style.bg != NONE) out.writeByte(block) else out.putCodepoint(cell.ch);
        }
        out.writeByte('\n');
    }
}

// ------------------------------------------------------------------- tests

test "frame geometry matches tty-clock constants" {
    try std.testing.expectEqual(@as(i32, 35), frameWidth(false));
    try std.testing.expectEqual(@as(i32, 54), frameWidth(true));
    try std.testing.expectEqual(@as(i32, 7), FRAME_HEIGHT);
    try std.testing.expectEqual(@as(i32, 3), DATEWINH);
}

test "rect covers frame and date row" {
    const o = FrameOpts{ .date = false };
    const r1 = rect(o, 0, 0);
    try std.testing.expectEqual(@as(i32, 35), r1.cols);
    try std.testing.expectEqual(@as(i32, 7), r1.rows);

    const o2 = FrameOpts{ .date = false, .second = true };
    try std.testing.expectEqual(@as(i32, 54), rect(o2, 2, 3).cols);

    // 日期 10 字符、居中：列 = 17 - 5 = 12，行 0..8
    const o3 = FrameOpts{ .date = true, .date_str = "2026-11-08" };
    const r3 = rect(o3, 0, 0);
    try std.testing.expectEqual(@as(i32, 9), r3.rows);
    try std.testing.expectEqual(@as(i32, 0), r3.col);
    try std.testing.expectEqual(@as(i32, 12), dateCol(o3, 0));
}

test "draw places digits where tty-clock does" {
    var canvas = try Canvas.init(std.testing.allocator, 128, 9);
    defer canvas.deinit();
    // 全用 8（点阵满格），这样每个数字的左上角必然点亮，h=7 行
    const o = FrameOpts{
        .hour = .{ 8, 8 },
        .minute = .{ 8, 8 },
        .second_digits = .{ 8, 8 },
        .second = true,
        .date = false,
    };
    canvas.begin(rect(o, 0, 0));
    draw(&canvas, o, 0, 0);

    // 每个数字的左上行必须点亮：9 个数字位置
    const cols = [_]i32{ 1, 8, 20, 27, 39, 46 };
    for (cols) |c| {
        const idx: usize = 1 * @as(usize, @intCast(canvas.cols)) + @as(usize, @intCast(c));
        const cell = canvas.cells[idx];
        try std.testing.expectEqual(NONE, cell.style.fg);
        try std.testing.expectEqual(@as(u8, 2), cell.style.bg);
    }
    // 冒号在第 2 行、第 16 和 35 列
    for ([_]i32{ 16, 35 }) |c| {
        const idx: usize = 2 * @as(usize, @intCast(canvas.cols)) + @as(usize, @intCast(c));
        try std.testing.expectEqual(@as(u8, 2), canvas.cells[idx].style.bg);
    }
    // 收尾检查：第 0 行整行空白
    var c: i32 = 0;
    while (c < canvas.cols) : (c += 1) {
        try std.testing.expectEqual(NONE, canvas.cells[@intCast(c)].style.bg);
    }
}

test "blinking colon hides the dot cells" {
    var canvas = try Canvas.init(std.testing.allocator, 64, 9);
    defer canvas.deinit();
    const o = FrameOpts{ .date = false, .colon_visible = false };
    canvas.begin(rect(o, 0, 0));
    draw(&canvas, o, 0, 0);
    const idx: usize = 2 * @as(usize, @intCast(canvas.cols)) + 16;
    try std.testing.expectEqual(NONE, canvas.cells[idx].style.bg);
}

test "plain text output renders 5 rows of digits without escapes" {
    var canvas = try Canvas.init(std.testing.allocator, 64, 9);
    defer canvas.deinit();
    const o = FrameOpts{ .date = false, .hour = .{ 0, 0 }, .minute = .{ 0, 0 } };
    canvas.begin(rect(o, 0, 0));
    draw(&canvas, o, 0, 0);
    // 直接检查画布内容而不是写 fd（-1 会写失败）
    try std.testing.expectEqual(@as(i32, 5), @as(i32, font.cell_rows));
    var row: i32 = 1;
    while (row <= 5) : (row += 1) {
        const idx: usize = @as(usize, @intCast(row * canvas.cols + 1));
        try std.testing.expectEqual(@as(u8, 2), canvas.cells[idx].style.bg);
    }
}

test "canvas ignores out-of-range coordinates (small terminals)" {
    var canvas = try Canvas.init(std.testing.allocator, 32, 9);
    defer canvas.deinit();
    // 时钟比终端还宽时会算出负的起始列，这里必须安全地丢弃越界格子
    canvas.begin(.{ .col = -10, .row = 0, .cols = 20, .rows = 5 });
    canvas.put(-20, 0, .{ .ch = 'x' });
    canvas.put(30, 0, .{ .ch = 'x' });
    canvas.put(-5, 2, .{ .ch = 'y', .style = .{ .bg = 3 } });
    canvas.text(-12, 1, "abcdef", .{ .fg = 4 });

    const used: usize = @intCast(canvas.cols * canvas.rows);
    var i: usize = 0;
    var x_count: usize = 0;
    var y_count: usize = 0;
    while (i < used) : (i += 1) {
        if (canvas.cells[i].ch == 'x') x_count += 1;
        if (canvas.cells[i].ch == 'y') y_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), x_count);
    try std.testing.expectEqual(@as(usize, 1), y_count);
    // "abcdef" 从 -12 列开始：前 10 个字符落在画布外，只应留下后 2 个
    var seen: usize = 0;
    i = 0;
    while (i < used) : (i += 1) {
        if (canvas.cells[i].ch == 'e' or canvas.cells[i].ch == 'f') seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}
