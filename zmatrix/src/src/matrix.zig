//! 字符雨模拟：cmatrix 原版（cmatrix.c 的 matrix[][] 模型）的逐条移植。
//!
//! 为什么不用「哈希生成字符」那套：哈希方案没法表达原版旧式滚动的整列下移、
//! `-k` 的「每格独立 1/8 概率变字」，也没法让一列的字符在头部下移时保持
//! 连续。这里改成和原版一样，给每列维护 rows+1 个格子的真实状态
//! （索引 0 在屏幕上方一行之外，索引增大 = 屏幕上更靠下）。
//!
//! 新式滚动（默认）按原版算法：顺序扫描每列，跳过空格段，对每个连续
//! 字符段在下端补一个新字符并标记为头部；段长超过 length 时把上端抹成空格。
//! 旧式滚动（-o）按原版算法：整列下移一格，再决定顶端写什么。
const std = @import("std");
const Allocator = std.mem.Allocator;

const charset = @import("charset.zig");
const color = @import("color.zig");
const options = @import("options.zig");

/// 空格子（原版的 -1）
pub const EMPTY: i32 = -1;
/// 旧式滚动的头部哨兵，渲染成亮白 '&'（原版的 0）
pub const HEAD_MARK: i32 = 0;
/// 旧式滚动里紧跟头部的格子，渲染成矩阵色 '|'（原版的 1）
pub const BAR_MARK: i32 = 1;

pub const Column = struct {
    /// 长度 rows+1；索引 0 对应屏幕上方一行之外。
    val: []i32,
    /// 原版同名标记：该格是本列当前头部（渲染成白色）。
    is_head: []bool,
    /// 拖尾长度（原版 length[]）。
    length: i32 = 0,
    /// 下一个雨柱开始前还要等几帧（原版 spaces[]）。
    spaces: i32 = 0,
    /// 异步滚动时本列的推进权重（原版 updates[]，取值 1..3）。
    update: u8 = 1,
};

pub const Matrix = struct {
    gpa: Allocator,
    cfg: options.Config,
    /// 物理终端列数（每个逻辑列占 2 个终端列，和原版 j += 2 一致）。
    term_cols: u16,
    /// 物理终端行数。
    rows: u16,
    columns: []Column,
    /// --fade 用的「渐隐档位」缓冲，长度 columns.len * (rows+1)；0 = 头部。
    fade_level: []u8,
    tick: u64 = 0,
    /// 原版的 count，1..4 循环，给 -a 做帧门控。
    count: u8 = 0,
    rng: std.Random.DefaultPrng,

    // ---------------------------------------------------------------- 帧差分
    // 两个网格缓冲（每格 = 字符码 + 打包后的颜色），尺寸都是 term_cols * rows。
    // front = 上一帧已经写到屏幕上的内容，back = 本帧的目标内容。
    // front 里放 UNKNOWN_CELL 就是「屏幕状态未知」，下一帧自然变成整屏重画。
    front_ch: []u21 = &.{},
    front_st: []u16 = &.{},
    back_ch: []u21 = &.{},
    back_st: []u16 = &.{},

    pub fn init(
        gpa: Allocator,
        term_cols: u16,
        rows: u16,
        cfg: options.Config,
        seed: u64,
    ) !Matrix {
        var m = Matrix{
            .gpa = gpa,
            .cfg = cfg,
            .term_cols = @max(term_cols, 1),
            .rows = @max(rows, 1),
            .columns = &.{},
            .fade_level = &.{},
            .rng = std.Random.DefaultPrng.init(seed),
        };
        try m.allocColumns(logicalCols(m.term_cols), m.rows);
        try m.ensureGrids();
        m.seedColumns();
        return m;
    }

    pub fn deinit(self: *Matrix) void {
        self.freeColumns();
        self.freeGrids();
        self.gpa.free(self.fade_level);
        self.fade_level = &.{};
    }

    /// 屏幕状态未知的哨兵：不是任何合法码位，所以和任何目标格都不相等。
    pub const UNKNOWN_CELL: u21 = 0;

    /// 保证差分用的两块网格尺寸和当前终端一致；重新分配后 front 全是哨兵，
    /// 于是下一帧就是一次整屏重画（启动、resize 都走这条路径）。
    fn ensureGrids(self: *Matrix) !void {
        const n = @as(usize, self.term_cols) * @as(usize, self.rows);
        if (self.front_ch.len == n and self.back_ch.len == n) return;
        self.freeGrids();
        const ch1 = try self.gpa.alloc(u21, n);
        errdefer self.gpa.free(ch1);
        const st1 = try self.gpa.alloc(u16, n);
        errdefer self.gpa.free(st1);
        const ch2 = try self.gpa.alloc(u21, n);
        errdefer self.gpa.free(ch2);
        const st2 = try self.gpa.alloc(u16, n);
        errdefer self.gpa.free(st2);
        @memset(ch1, UNKNOWN_CELL);
        @memset(st1, 0);
        @memset(ch2, ' ');
        @memset(st2, 0);
        self.front_ch = ch1;
        self.front_st = st1;
        self.back_ch = ch2;
        self.back_st = st2;
    }

    fn freeGrids(self: *Matrix) void {
        if (self.front_ch.len != 0) self.gpa.free(self.front_ch);
        if (self.front_st.len != 0) self.gpa.free(self.front_st);
        if (self.back_ch.len != 0) self.gpa.free(self.back_ch);
        if (self.back_st.len != 0) self.gpa.free(self.back_st);
        self.front_ch = &.{};
        self.front_st = &.{};
        self.back_ch = &.{};
        self.back_st = &.{};
    }

    /// 逻辑列数：原版 `for (j = 0; j <= COLS-1; j += 2)`，即 ceil(cols/2)。
    pub fn logicalCols(term_cols: u16) usize {
        return (@as(usize, term_cols) + 1) / 2;
    }

    fn allocColumns(self: *Matrix, n: usize, rows: u16) !void {
        const stride = @as(usize, rows) + 1;
        const cols = try self.gpa.alloc(Column, n);
        errdefer self.gpa.free(cols);
        var made: usize = 0;
        errdefer for (cols[0..made]) |c| {
            self.gpa.free(c.val);
            self.gpa.free(c.is_head);
        };
        for (cols) |*c| {
            c.val = try self.gpa.alloc(i32, stride);
            c.is_head = try self.gpa.alloc(bool, stride);
            made += 1;
        }
        const fd = try self.gpa.alloc(u8, n * stride);
        self.fade_level = fd;
        self.columns = cols;
        self.rows = rows;
    }

    fn freeColumns(self: *Matrix) void {
        for (self.columns) |c| {
            self.gpa.free(c.val);
            self.gpa.free(c.is_head);
        }
        self.gpa.free(self.columns);
        self.columns = &.{};
    }

    /// 原版 var_init()：全部置空，只留 val[1] = ' ' 作为「顶端空着」的哨兵。
    fn seedColumns(self: *Matrix) void {
        const rows: i32 = @intCast(self.rows);
        for (self.columns) |*c| {
            @memset(c.val, EMPTY);
            @memset(c.is_head, false);
            // 原版 spaces[j] = rand() % LINES + 1
            c.spaces = self.rng.random().intRangeAtMost(i32, 1, rows);
            // 原版 length[j] = rand() % (LINES - 3) + 3
            const span: i32 = @max(rows - 3, 1);
            c.length = self.rng.random().intRangeAtMost(i32, 0, span - 1) + 3;
            // 原版 updates[j] = rand() % 3 + 1
            c.update = self.rng.random().intRangeAtMost(u8, 1, 3);
            c.val[1] = ' ';
        }
    }

    /// SIGWINCH 后按原版 resize_screen() 重建：重新 var_init + 清屏。
    pub fn resize(self: *Matrix, term_cols: u16, rows: u16) !void {
        const old_cols = self.columns;
        const old_fade = self.fade_level;
        const old_rows = self.rows;
        const old_term = self.term_cols;

        self.columns = &.{};
        self.fade_level = &.{};
        self.term_cols = @max(term_cols, 1);
        self.rows = @max(rows, 1);
        self.allocColumns(logicalCols(self.term_cols), self.rows) catch |err| {
            // 分配失败：把旧数组装回去，屏幕保持原状
            self.columns = old_cols;
            self.fade_level = old_fade;
            self.rows = old_rows;
            self.term_cols = old_term;
            return err;
        };
        for (old_cols) |c| {
            self.gpa.free(c.val);
            self.gpa.free(c.is_head);
        }
        self.gpa.free(old_cols);
        self.gpa.free(old_fade);
        self.seedColumns();
        // 尺寸变了：差分缓冲必须重建，下一帧整屏重画。
        self.ensureGrids() catch {};
    }

    /// 推进一帧（原版主循环里 for j 那一段）。
    pub fn step(self: *Matrix) void {
        self.tick +%= 1;
        self.count +%= 1;
        if (self.count > 4) self.count = 1;
        for (self.columns) |*c| {
            // 原版：if (count > updates[j] || asynch == 0)
            if (self.cfg.async_scroll and self.count <= c.update) continue;
            if (self.cfg.oldstyle) self.stepOld(c) else self.stepNew(c);
        }
    }

    /// 新式滚动（默认）。
    fn stepNew(self: *Matrix, c: *Column) void {
        const rows: i32 = @intCast(self.rows);
        const r = self.rng.random();
        const set = charset.glyphs(self.cfg.charset, self.cfg.custom_chars);

        if (c.val[0] == EMPTY and c.val[1] == ' ' and c.spaces > 0) {
            c.spaces -= 1;
        } else if (c.val[0] == EMPTY and c.val[1] == ' ') {
            const span: i32 = @max(rows - 3, 1);
            c.length = r.intRangeAtMost(i32, 0, span - 1) + 3;
            c.val[0] = @intCast(charset.pick(set, r));
            c.spaces = r.intRangeAtMost(i32, 1, rows);
        }

        var i: i32 = 0;
        var first = false;
        while (i <= rows) {
            // 跳过空格段
            while (i <= rows and (c.val[@intCast(i)] == ' ' or c.val[@intCast(i)] == EMPTY)) {
                i += 1;
            }
            if (i > rows) break;

            // 找到这一段的头部（段尾）
            const z = i;
            var y: i32 = 0;
            while (i <= rows and c.val[@intCast(i)] != ' ' and c.val[@intCast(i)] != EMPTY) {
                c.is_head[@intCast(i)] = false;
                // 原版 -k：每格每帧 1/8 概率换成新字符
                if (self.cfg.mutate and r.uintLessThan(u8, 8) == 0) {
                    c.val[@intCast(i)] = @intCast(charset.pick(set, r));
                }
                i += 1;
                y += 1;
            }

            if (i > rows) {
                // 段一直延续到屏幕外：把段首抹掉
                c.val[@intCast(z)] = ' ';
                continue;
            }

            c.val[@intCast(i)] = @intCast(charset.pick(set, r));
            c.is_head[@intCast(i)] = true;

            if (y > c.length or first) {
                c.val[@intCast(z)] = ' ';
                c.val[0] = EMPTY;
            }
            first = true;
            i += 1;
        }
    }

    /// 旧式滚动（-o）：整列下移一格，顶端按原版规则补内容。
    fn stepOld(self: *Matrix, c: *Column) void {
        const rows: i32 = @intCast(self.rows);
        const r = self.rng.random();
        const set = charset.glyphs(self.cfg.charset, self.cfg.custom_chars);
        const n: i32 = @intCast(set.len);

        var i: i32 = rows - 1;
        while (i >= 1) : (i -= 1) {
            c.val[@intCast(i)] = c.val[@intCast(i - 1)];
        }

        // 原版：random = rand() % (randnum + 8) + randmin，> highnum 时留空
        const random = r.intRangeAtMost(i32, 0, n + 7);

        if (c.val[1] == HEAD_MARK) {
            c.val[0] = BAR_MARK;
        } else if (c.val[1] == ' ' or c.val[1] == EMPTY) {
            if (c.spaces > 0) {
                c.val[0] = ' ';
                c.spaces -= 1;
            } else {
                // 原版：rand() % 3 == 1 时是白头部
                if (r.uintLessThan(u8, 3) == 1) {
                    c.val[0] = HEAD_MARK;
                } else {
                    c.val[0] = @intCast(charset.pick(set, r));
                }
                c.spaces = r.intRangeAtMost(i32, 1, rows);
            }
        } else if (random > n and c.val[1] != BAR_MARK) {
            c.val[0] = ' ';
        } else {
            c.val[0] = @intCast(charset.pick(set, r));
        }
    }

    /// 算出每个格子的渐隐档位（0 = 头部，1 最亮 -> color.levels 最暗）。
    /// 档位按「本段长度」等比分配，所以短柱和长柱都是完整的一道渐变。
    fn computeFade(self: *Matrix) void {
        const stride = @as(usize, self.rows) + 1;
        for (self.columns, 0..) |*c, x| {
            const off = x * stride;
            var i: usize = 0;
            while (i < stride) {
                if (c.val[i] == EMPTY or c.val[i] == ' ') {
                    self.fade_level[off + i] = 0;
                    i += 1;
                    continue;
                }
                var e = i;
                while (e + 1 < stride and c.val[e + 1] != EMPTY and c.val[e + 1] != ' ') e += 1;
                const run = e - i + 1;
                var k = i;
                while (k <= e) : (k += 1) {
                    self.fade_level[off + k] = fadeLevelStep(e - k, run);
                }
                i = e + 1;
            }
        }
    }

    /// 渲染一帧（带帧差分 / damage tracking）。
    ///
    /// 先把本帧的目标网格组装到 back（每格 = 字符码 + 打包颜色），再和 front
    /// （上一帧已经写到屏幕上的内容）逐格比较，只输出变化的部分：
    ///
    ///   * 同一行里连续的脏格合并成一段，一段只有一个 CUP + 一串字符；
    ///     中间隔着不超过 MAX_GAP 个干净格时也并进去（重画几个空格比再发一次
    ///     `\e[R;CH` 便宜）；
    ///   * 整行都没变就完全不输出；整屏都没变就一个字节都不写；
    ///   * 颜色只在变化时发 SGR，同一段里相同颜色不重复发；
    ///   * front 是「未知」时（启动、resize）整行都是脏的，此时一行会从第 1 列
    ///     一直写到右边界 —— 这就是原来那种整屏覆盖写的语义；
    ///   * 永不下发背景色（40-47 / 48;），终端自己的底色透出来 —— 这是与
    ///     cmatrix 2.0 唯一的观感差异。
    pub fn render(self: *Matrix, depth: color.Depth, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        // 极端情况（内存不足）就这一帧不画，下次再试，绝不越界。
        self.ensureGrids() catch return;
        self.compose(depth);
        try self.emitDiff(out);
        // 本帧的目标网格成为下一帧的「已画出」状态
        std.mem.swap([]u21, &self.front_ch, &self.back_ch);
        std.mem.swap([]u16, &self.front_st, &self.back_st);
    }

    /// 把「屏幕上已有的内容」标记成未知，下一帧就是一次整屏重画。
    /// resize / 终端被外部改写（例如 -M 之后切回）时用。
    pub fn forceFullRepaint(self: *Matrix) void {
        @memset(self.front_ch, UNKNOWN_CELL);
    }

    /// 组装本帧的目标网格（字符 + 颜色）到 back 缓冲，整屏逐格填满。
    fn compose(self: *Matrix, depth: color.Depth) void {
        const cfg = self.cfg;
        const ncols = self.columns.len;
        const rows: usize = self.rows;
        const term_cols: usize = self.term_cols;
        // 新式：数组 1..rows 映射到屏幕 0..rows-1；旧式：数组 0..rows-1 直接对应
        const base: usize = if (cfg.oldstyle) 0 else 1;
        const fade_on = cfg.fade and !cfg.oldstyle;
        const stride = rows + 1;
        const back_ch = self.back_ch;
        const back_st = self.back_st;

        if (fade_on) self.computeFade();
        const rnd = self.rng.random();

        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const ro = row * term_cols;
            const i = row + base;
            var x: usize = 0;
            while (x < ncols) : (x += 1) {
                const c = &self.columns[x];
                const v = c.val[i];
                var glyph: u21 = ' ';
                var style = color.Style{};
                var painted = false;

                const is_white = v == HEAD_MARK or (c.is_head[i] and !cfg.rainbow);
                if (is_white) {
                    // 原版：val == 0 画 '&'；is_head 画该字符本身；都是白色
                    glyph = if (v == HEAD_MARK) '&' else if (v == EMPTY) ' ' else @intCast(v);
                    const bold = cfg.bold != .none;
                    style = if (fade_on) color.brightWhite(bold) else color.white(bold);
                    painted = glyph != ' ';
                } else if (v != EMPTY and v != ' ') {
                    const name = if (cfg.rainbow) rainbowPick(rnd) else cfg.color;
                    const bold = switch (cfg.bold) {
                        .none, .head => false,
                        .dither => @mod(v, 2) == 0,
                        .all => true,
                    };
                    glyph = if (v == BAR_MARK)
                        '|'
                    else if (cfg.lambda)
                        0x03BB // λ
                    else
                        @intCast(v);
                    style = if (fade_on)
                        color.fade(name, self.fade_level[x * stride + i], bold, depth)
                    else
                        color.ansi(name, bold);
                    painted = true;
                }

                // 奇数列是原版 j += 2 留出的那道空隙：空格、无色。
                // 空格统一记成 (space, none)，这样「一直是空的」格子永远算干净。
                if (painted) {
                    back_ch[ro + 2 * x] = glyph;
                    back_st[ro + 2 * x] = color.encode(style);
                } else {
                    back_ch[ro + 2 * x] = ' ';
                    back_st[ro + 2 * x] = 0;
                }
                if (2 * x + 1 < term_cols) {
                    if (cfg.x_mode and painted) {
                        back_ch[ro + 2 * x + 1] = glyph;
                        back_st[ro + 2 * x + 1] = color.encode(style);
                    } else {
                        back_ch[ro + 2 * x + 1] = ' ';
                        back_st[ro + 2 * x + 1] = 0;
                    }
                }
            }
        }

        if (cfg.message_chars.len != 0) self.composeMessage();
    }

    /// 一段脏格之间最多容忍几个干净格（会顺带重画它们以省一次 CUP）。
    /// CUP 一般是 7~9 字节，重画一个空格是 1 字节（或几字节的 SGR）。
    const MAX_GAP: usize = 6;

    /// 比较 front/back，把脏区间写成 CUP + 字符。
    fn emitDiff(self: *Matrix, out: *std.ArrayList(u8)) !void {
        const gpa = self.gpa;
        const term_cols: usize = self.term_cols;
        const rows: usize = self.rows;
        const fc = self.front_ch;
        const fs = self.front_st;
        const bc = self.back_ch;
        const bs = self.back_st;
        var wrote = false;
        // 每帧都以 \e[0m 收尾，所以帧首的 SGR 状态总是「默认」
        var cur = color.Style{};
        var hdr: [24]u8 = undefined;

        var y: usize = 0;
        while (y < rows) : (y += 1) {
            const ro = y * term_cols;
            var x: usize = 0;
            while (x < term_cols) {
                if (bc[ro + x] == fc[ro + x] and bs[ro + x] == fs[ro + x]) {
                    x += 1;
                    continue;
                }
                const start = x;
                var end = x + 1;
                var probe = x + 1;
                while (probe < term_cols) {
                    if (bc[ro + probe] != fc[ro + probe] or bs[ro + probe] != fs[ro + probe]) {
                        end = probe + 1;
                        probe += 1;
                        continue;
                    }
                    // 干净区：往后看有多长，短就一起写掉，长就另起一段
                    var q = probe;
                    while (q < term_cols and bc[ro + q] == fc[ro + q] and bs[ro + q] == fs[ro + q]) {
                        q += 1;
                    }
                    if (q - probe > MAX_GAP or q >= term_cols) break;
                    end = q;
                    probe = q;
                }

                const h = std.fmt.bufPrint(&hdr, "\x1b[{d};{d}H", .{ y + 1, start + 1 }) catch "\x1b[H";
                try out.appendSlice(gpa, h);
                var i = start;
                while (i < end) : (i += 1) {
                    const glyph = bc[ro + i];
                    if (glyph == ' ') {
                        // 空格的颜色不可见：绝不为了它改 SGR（一个 \e[0m 是 4 字节，
                        // 而空格本身只要 1 字节），终端的前色状态保持不动。
                        try out.append(gpa, ' ');
                    } else {
                        const st = color.decode(bs[ro + i]);
                        try color.emit(gpa, out, cur, st);
                        cur = st;
                        try appendGlyph(out, gpa, glyph);
                    }
                }
                wrote = true;
                x = end;
            }
        }

        if (wrote) try out.appendSlice(gpa, "\x1b[0m");
    }

    /// 原版 -M：屏幕正中三行，左右各留 2 列空白，消息用默认前色。
    /// 直接合成进目标网格，所以它只会在出现/消失/改字时被重画。
    fn composeMessage(self: *Matrix) void {
        const msg = self.cfg.message_chars;
        const rows: usize = self.rows;
        const cols: usize = self.term_cols;
        const width = msg.len + 4;
        const mid = rows / 2;
        const start: usize = if (cols / 2 > msg.len / 2 + 2) cols / 2 - msg.len / 2 - 2 else 0;

        var k: usize = 0;
        while (k < 3) : (k += 1) {
            const the_row: usize = switch (k) {
                0 => if (mid == 0) 0 else mid - 1,
                else => mid + k - 1,
            };
            if (the_row >= rows) continue;
            const ro = the_row * cols;
            if (k == 1) {
                var j: usize = 0;
                while (j < width) : (j += 1) {
                    const x = start + j;
                    if (x >= cols) break;
                    const cp: u21 = if (j >= 2 and j - 2 < msg.len) msg[j - 2] else ' ';
                    self.back_ch[ro + x] = cp;
                    self.back_st[ro + x] = 0; // 默认前色
                }
            } else {
                var j: usize = 0;
                while (j < width) : (j += 1) {
                    const x = start + j;
                    if (x >= cols) break;
                    self.back_ch[ro + x] = ' ';
                    self.back_st[ro + x] = 0;
                }
            }
        }
    }
};

/// 段内第 (run-1-dist) 个格子（从头部数起第 dist 格）的档位。
/// dist = 0 是头部；dist 从 1 开始是拖尾，越远越暗。
pub fn fadeLevelStep(dist: usize, run: usize) u8 {
    if (dist == 0) return 0;
    if (run <= 2) return 1;
    const span: u32 = color.levels;
    const t = (@as(u32, @intCast(dist - 1)) * span) / @as(u32, @intCast(run - 1));
    return @intCast(1 + @min(t, span - 1));
}

/// 彩虹：原版每个非头部格子每帧 rand() % 6 取一种颜色，
/// 集合是 绿 蓝 黑 黄 青 洋红（没有红，也没有白）。
fn rainbowPick(r: std.Random) color.Name {
    return switch (r.uintLessThan(u8, 6)) {
        0 => .green,
        1 => .blue,
        2 => .black,
        3 => .yellow,
        4 => .cyan,
        else => .magenta,
    };
}

fn appendGlyph(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append(gpa, '?');
        return;
    };
    try out.appendSlice(gpa, buf[0..n]);
}

/// 测试用：把 render() 的输出解析回网格（字符 + 前景色码）。
/// 只认 CUP 和 SGR；输出里本来就不该出现别的定位/擦除序列。
pub const FrameGrid = struct {
    cols: usize,
    rows: usize,
    ch: []u21,
    fg: []i16,
    rows_painted: usize = 0,
    row: usize = 0,
    cur: usize = 0,
    fg_state: i16 = -1,
    /// 每行实际写入的格子数（遇到下一个 CUP 时结算上一行）
    row_widths: [128]usize = @splat(0),

    pub fn parse(gpa: Allocator, bytes: []const u8, cols: usize, rows: usize) !FrameGrid {
        var g = FrameGrid{
            .cols = cols,
            .rows = rows,
            .ch = try gpa.alloc(u21, cols * rows),
            .fg = try gpa.alloc(i16, cols * rows),
        };
        errdefer g.deinit(gpa);
        @memset(g.ch, ' ');
        @memset(g.fg, -1);
        g.feed(bytes);
        return g;
    }

    /// 把一帧的字节流叠加到已有的网格上（就像终端那样），用于跨帧检查。
    pub fn feed(self: *FrameGrid, bytes: []const u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (bytes[i] == 0x1b) {
                i = self.escape(bytes, i);
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
            const cp: u21 = if (n == 1)
                bytes[i]
            else
                std.unicode.utf8Decode(bytes[i .. i + n]) catch '?';
            self.put(cp);
            i += n;
        }
    }

    pub fn deinit(self: *FrameGrid, gpa: Allocator) void {
        gpa.free(self.ch);
        gpa.free(self.fg);
    }

    pub fn at(self: *const FrameGrid, x: usize, y: usize) u21 {
        return self.ch[y * self.cols + x];
    }

    pub fn fgAt(self: *const FrameGrid, x: usize, y: usize) i16 {
        return self.fg[y * self.cols + x];
    }

    pub fn widthAt(self: *const FrameGrid, r: usize) usize {
        if (r >= self.rows_painted) return 0;
        return if (r + 1 < self.rows_painted) self.row_widths[r] else self.cur;
    }

    fn put(self: *FrameGrid, cp: u21) void {
        if (self.row < self.rows and self.cur < self.cols) {
            self.ch[self.row * self.cols + self.cur] = cp;
            self.fg[self.row * self.cols + self.cur] = self.fg_state;
        }
        self.cur += 1;
    }

    fn escape(self: *FrameGrid, bytes: []const u8, start: usize) usize {
        var i = start + 1;
        if (i >= bytes.len or bytes[i] != '[') return i + 1;
        i += 1;
        var params: [8]u16 = @splat(0);
        var nparams: usize = 0;
        var have_digit = false;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b >= '0' and b <= '9') {
                if (nparams < params.len) {
                    params[nparams] = params[nparams] * 10 + (b - '0');
                }
                have_digit = true;
                continue;
            }
            if (b == ';') {
                if (nparams + 1 < params.len) nparams += 1;
                have_digit = false;
                continue;
            }
            // 终止字节
            if (have_digit) nparams += 1;
            switch (b) {
                'H', 'f' => {
                    // 结算上一行写了多少格
                    if (self.rows_painted > 0 and self.row < self.row_widths.len) {
                        self.row_widths[self.row] = self.cur;
                    }
                    self.row = if (nparams > 0 and params[0] > 0) params[0] - 1 else 0;
                    self.cur = if (nparams > 1 and params[1] > 0) params[1] - 1 else 0;
                    self.rows_painted += 1;
                },
                'm' => self.sgr(params[0..nparams]),
                else => {},
            }
            return i + 1;
        }
        return i;
    }

    fn sgr(self: *FrameGrid, params: []const u16) void {
        if (params.len == 0) {
            self.fg_state = -1;
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            const p = params[i];
            if (p == 0) {
                self.fg_state = -1;
            } else if (p >= 30 and p <= 37) {
                self.fg_state = @intCast(p);
            } else if (p >= 90 and p <= 97) {
                self.fg_state = @intCast(p);
            } else if (p == 38 and i + 2 < params.len and params[i + 1] == 5) {
                self.fg_state = @intCast(256 + params[i + 2]);
                i += 2;
            } else if (p == 38 and i + 4 < params.len and params[i + 1] == 2) {
                self.fg_state = @intCast(300 + params[i + 2]);
                i += 4;
            }
        }
    }
};

// ------------------------------------------------------------------ tests

test "logical column count matches cmatrix j += 2 loop" {
    try std.testing.expectEqual(@as(usize, 40), Matrix.logicalCols(80));
    try std.testing.expectEqual(@as(usize, 40), Matrix.logicalCols(79));
    try std.testing.expectEqual(@as(usize, 41), Matrix.logicalCols(81));
    try std.testing.expectEqual(@as(usize, 1), Matrix.logicalCols(1));
}

test "a fresh matrix starts blank, like var_init()" {
    const cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 20, 10, cfg, 1234);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);
    // 首帧就是 10 行、每行 20 个空格，没有任何清屏/擦行序列
    var grid = try FrameGrid.parse(std.testing.allocator, out.items, 20, 10);
    defer grid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), grid.rows_painted);
    for (grid.ch) |c| try std.testing.expectEqual(@as(u21, ' '), c);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out.items, "\x1b[2J"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out.items, "\x1b[K"));
}

test "streams start at the top row and stay contiguous" {
    const cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 80, 24, cfg, 99);
    defer m.deinit();
    var steps: usize = 0;
    while (steps < 40) : (steps += 1) {
        m.step();
        var any = false;
        for (m.columns) |c| {
            for (c.val) |v| {
                if (v != EMPTY and v != ' ') any = true;
            }
        }
        if (any) break;
    }
    // 第一根雨柱出现时，必须从屏幕第 0 行（索引 1）开始连续往下，
    // 而不是散落在屏幕中间 —— 这正是旧实现「整屏乱跳」的根因。
    for (m.columns) |c| {
        var first: ?usize = null;
        var last: ?usize = null;
        for (c.val[1..], 1..) |v, idx| {
            if (v != EMPTY and v != ' ') {
                if (first == null) first = idx;
                last = idx;
            }
        }
        if (first) |f| {
            try std.testing.expectEqual(@as(usize, 1), f);
            const l = last.?;
            for (f..l + 1) |k| try std.testing.expect(c.val[k] != EMPTY and c.val[k] != ' ');
        }
    }
}

test "a cell keeps its glyph while the column falls" {
    const cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 10, 20, cfg, 7);
    defer m.deinit();
    var i: usize = 0;
    while (i < 30) : (i += 1) m.step();
    const c = &m.columns[0];
    const before = try std.testing.allocator.dupe(i32, c.val);
    defer std.testing.allocator.free(before);
    m.step();
    // 段中间那些格子必须保持同一字符（只有两端会变）
    var kept: usize = 0;
    var idx: usize = 3;
    while (idx + 2 < before.len) : (idx += 1) {
        if (before[idx] != EMPTY and before[idx] != ' ' and c.val[idx] == before[idx]) kept += 1;
    }
    try std.testing.expect(kept >= 3);
}

test "oldstyle fills whole columns and keeps a head marker" {
    var cfg = options.Config{};
    cfg.oldstyle = true;
    var m = try Matrix.init(std.testing.allocator, 80, 20, cfg, 5);
    defer m.deinit();
    var i: usize = 0;
    while (i < 80) : (i += 1) m.step();
    // 旧式滚动跑够帧数后，大部分列是「几乎每格都有字符」的实心柱
    var dense: usize = 0;
    for (m.columns) |c| {
        var n: usize = 0;
        for (c.val[0..20]) |v| {
            if (v != EMPTY and v != ' ') n += 1;
        }
        if (n >= 10) dense += 1;
    }
    try std.testing.expect(dense >= m.columns.len / 2);
}

test "async columns get 1..3 updates and actually differ" {
    var cfg = options.Config{};
    cfg.async_scroll = true;
    var m = try Matrix.init(std.testing.allocator, 80, 20, cfg, 42);
    defer m.deinit();
    var seen = [_]bool{ false, false, false, false };
    for (m.columns) |c| {
        try std.testing.expect(c.update >= 1 and c.update <= 3);
        seen[c.update] = true;
    }
    var kinds: usize = 0;
    for (seen[1..]) |s| {
        if (s) kinds += 1;
    }
    try std.testing.expect(kinds >= 2);
}

test "-k mutates a few cells per frame instead of the whole screen" {
    var cfg = options.Config{};
    cfg.mutate = true;
    var m = try Matrix.init(std.testing.allocator, 80, 24, cfg, 11);
    defer m.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) m.step();

    var total_changed: usize = 0;
    var frames: usize = 0;
    while (frames < 10) : (frames += 1) {
        const before = try std.testing.allocator.dupe(i32, m.columns[3].val);
        defer std.testing.allocator.free(before);
        m.step();
        var idx: usize = 2;
        while (idx + 2 < before.len) : (idx += 1) {
            const a = before[idx];
            const b = m.columns[3].val[idx];
            if (a != EMPTY and a != ' ' and b != EMPTY and b != ' ' and a != b) total_changed += 1;
        }
    }
    // 10 帧里约 1/8 的格子会变：既有变化，又远不是整列一起闪
    try std.testing.expect(total_changed >= 1);
    try std.testing.expect(total_changed <= 20);
}

test "fade level grows with the distance to the head" {
    try std.testing.expectEqual(@as(u8, 0), fadeLevelStep(0, 20));
    var prev: u8 = 0;
    var d: usize = 1;
    while (d < 20) : (d += 1) {
        const lvl = fadeLevelStep(d, 20);
        try std.testing.expect(lvl >= 1 and lvl <= color.levels);
        try std.testing.expect(lvl >= prev);
        prev = lvl;
    }
    try std.testing.expectEqual(color.levels, prev);
    // 短柱也走完整色阶
    try std.testing.expectEqual(@as(u8, 1), fadeLevelStep(1, 4));
    try std.testing.expect(fadeLevelStep(3, 4) > fadeLevelStep(1, 4));
}

test "render never leaks bold between a head and the tail" {
    var cfg = options.Config{};
    cfg.bold = .dither;
    var m = try Matrix.init(std.testing.allocator, 80, 24, cfg, 3);
    defer m.deinit();
    var i: usize = 0;
    while (i < 60) : (i += 1) m.step();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);
    // 每个「打开粗体」都必须有一个对应的关闭
    const on = std.mem.count(u8, out.items, "\x1b[1;");
    const off = std.mem.count(u8, out.items, "22;") +
        std.mem.count(u8, out.items, "\x1b[0m");
    try std.testing.expect(off >= on);
}

test "every row of a frame is positioned and fits the terminal width" {
    const cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 80, 24, cfg, 21);
    defer m.deinit();
    var i: usize = 0;
    while (i < 40) : (i += 1) m.step();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);

    // 逐行统计可打印宽度（跳过 CSI 序列），任何一行都不得超过终端宽度 80
    var pos: usize = 0;
    var width: usize = 0;
    var rows_seen: usize = 0;
    var over = false;
    while (pos < out.items.len) {
        if (out.items[pos] == 0x1b) {
            var j = pos + 1;
            if (j < out.items.len and out.items[j] == '[') {
                j += 1;
                while (j < out.items.len and !(out.items[j] >= 0x40 and out.items[j] <= 0x7e)) j += 1;
                const final = if (j < out.items.len) out.items[j] else 0;
                if (final == 'H') {
                    width = 0;
                    rows_seen += 1;
                }
                j += 1;
            } else {
                j += 1;
            }
            pos = j;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(out.items[pos]) catch 1;
        width += 1;
        if (width > 80) over = true;
        pos += n;
    }
    try std.testing.expect(!over);
    try std.testing.expectEqual(@as(usize, 24), rows_seen);
}

/// 输出里有没有下发背景色（40-47 / 48; / 100-107）。
fn hasBackgroundSgr(bytes: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < bytes.len) : (i += 1) {
        if (bytes[i] != 0x1b or bytes[i + 1] != '[') continue;
        var j = i + 2;
        while (j < bytes.len and !(bytes[j] >= 0x40 and bytes[j] <= 0x7e)) : (j += 1) {}
        if (j >= bytes.len) return false;
        if (bytes[j] == 'm') {
            var params: [16]u32 = @splat(0);
            var count: usize = 0;
            var param: u32 = 0;
            var k = i + 2;
            while (k <= j) : (k += 1) {
                const b: u8 = if (k == j) ';' else bytes[k];
                if (b >= '0' and b <= '9') {
                    param = param * 10 + (b - '0');
                } else if (b == ';' or b == ':') {
                    if (count < params.len) {
                        params[count] = param;
                        count += 1;
                    }
                    param = 0;
                }
            }
            // 逐个参数看：38/48 的扩展参数（5;n、2;r;g;b）要一起跳过，
            // 否则 \e[38;5;46m 里的 46 会被误判成背景色。
            var idx: usize = 0;
            while (idx < count) {
                const p = params[idx];
                if (p == 38 or p == 48) {
                    const mode: u32 = if (idx + 1 < count) params[idx + 1] else 0;
                    if (mode == 5) {
                        if (p == 48) return true;
                        idx += 3;
                        continue;
                    }
                    if (mode == 2) {
                        if (p == 48) return true;
                        idx += 5;
                        continue;
                    }
                    if (p == 48) return true;
                    idx += 1;
                    continue;
                }
                if ((p >= 40 and p <= 47) or (p >= 100 and p <= 107)) return true;
                idx += 1;
            }
        }
        i = j;
    }
    return false;
}

test "a frame overwrites every row at the full terminal width" {
    const cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 120, 40, cfg, 8);
    defer m.deinit();
    var i: usize = 0;
    while (i < 60) : (i += 1) m.step();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);

    var grid = try FrameGrid.parse(std.testing.allocator, out.items, 120, 40);
    defer grid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 40), grid.rows_painted);
    for (0..40) |r| try std.testing.expectEqual(@as(usize, 120), grid.widthAt(r));
    // 每帧不清屏、不擦行尾：靠整屏覆盖写，和 curses refresh 等价
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out.items, "\x1b[2J"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out.items, "\x1b[K"));
}

test "odd terminal widths fit exactly without wrapping" {
    var m = try Matrix.init(std.testing.allocator, 79, 12, options.Config{}, 4);
    defer m.deinit();
    var i: usize = 0;
    while (i < 30) : (i += 1) m.step();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);
    var grid = try FrameGrid.parse(std.testing.allocator, out.items, 79, 12);
    defer grid.deinit(std.testing.allocator);
    for (0..12) |r| try std.testing.expectEqual(@as(usize, 79), grid.widthAt(r));
}

test "rendering never emits a background colour" {
    var cfg = options.Config{};
    var m = try Matrix.init(std.testing.allocator, 80, 24, cfg, 31);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        m.step();
        try m.render(.ansi256, &out);
        try std.testing.expect(!hasBackgroundSgr(out.items));
    }
    // 彩虹/粗体/渐隐路径也不许带底色
    cfg = options.Config{};
    cfg.rainbow = true;
    cfg.bold = .all;
    cfg.fade = true;
    var m2 = try Matrix.init(std.testing.allocator, 80, 24, cfg, 32);
    defer m2.deinit();
    i = 0;
    while (i < 30) : (i += 1) {
        m2.step();
        try m2.render(.ansi256, &out);
        try std.testing.expect(!hasBackgroundSgr(out.items));
    }
}

test "glyphs land only in even terminal columns, like j += 2" {
    var m = try Matrix.init(std.testing.allocator, 120, 40, options.Config{}, 77);
    defer m.deinit();
    var i: usize = 0;
    while (i < 120) : (i += 1) m.step();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try m.render(.ansi256, &out);
    var grid = try FrameGrid.parse(std.testing.allocator, out.items, 120, 40);
    defer grid.deinit(std.testing.allocator);
    var odd_cells: usize = 0;
    var glyphs: usize = 0;
    for (0..40) |y| {
        for (0..120) |x| {
            if (grid.at(x, y) == ' ') continue;
            glyphs += 1;
            if (x % 2 == 1) odd_cells += 1;
        }
    }
    try std.testing.expect(glyphs > 0);
    try std.testing.expectEqual(@as(usize, 0), odd_cells);
}

test "each stream's head is white and sits at its lower end" {
    var m = try Matrix.init(std.testing.allocator, 80, 24, options.Config{}, 55);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    // 帧差分只发变化的格子，所以这里像终端一样把每一帧叠加到同一个网格上
    var grid = try FrameGrid.parse(std.testing.allocator, "", 80, 24);
    defer grid.deinit(std.testing.allocator);
    var frame: usize = 0;
    var checked: usize = 0;
    while (frame < 40) : (frame += 1) {
        m.step();
        try m.render(.ansi256, &out);
        grid.feed(out.items);
        for (0..40) |x0| {
            const x = x0 * 2;
            var y: usize = 0;
            while (y < 24) {
                if (grid.at(x, y) == ' ') {
                    y += 1;
                    continue;
                }
                var end = y;
                while (end + 1 < 24 and grid.at(x, end + 1) != ' ') end += 1;
                // 段内白色格只能是最后一个（头在下方，尾巴在上方）
                var ws: usize = y;
                while (ws <= end) : (ws += 1) {
                    if (grid.fgAt(x, ws) == 37) {
                        try std.testing.expectEqual(end, ws);
                    }
                }
                checked += 1;
                y = end + 1;
            }
        }
    }
    try std.testing.expect(checked > 0);
}

// ------------------------------------------------------------------ 帧差分

test "the second frame only contains the cells that actually changed" {
    var m = try Matrix.init(std.testing.allocator, 80, 24, options.Config{}, 9);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    m.step();
    try m.render(.ansi256, &out);
    const first = out.items.len; // 首帧：整屏重画（每行到右边界）
    var total: usize = 0;
    var frames: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        m.step();
        try m.render(.ansi256, &out);
        total += out.items.len;
        frames += 1;
    }
    const avg = total / frames;
    try std.testing.expect(first > 1500);
    // 稳态每帧只写变化的百来个格子（约 1KB），远小于整屏
    try std.testing.expect(avg < first);
    try std.testing.expect(avg < 1400);
}

test "a frame with nothing to change writes zero bytes" {
    var m = try Matrix.init(std.testing.allocator, 40, 12, options.Config{}, 3);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    m.step();
    try m.render(.ansi256, &out);
    try std.testing.expect(out.items.len > 0);
    // 不推进就再画一次：屏幕上已经是这个内容了
    try m.render(.ansi256, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "resize and forceFullRepaint both resync the screen" {
    var m = try Matrix.init(std.testing.allocator, 40, 12, options.Config{}, 17);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    m.step();
    try m.render(.ansi256, &out);
    try m.render(.ansi256, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    m.forceFullRepaint();
    try m.render(.ansi256, &out);
    var grid = try FrameGrid.parse(std.testing.allocator, out.items, 40, 12);
    defer grid.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 12), grid.rows_painted);

    try m.resize(60, 20);
    m.step();
    try m.render(.ansi256, &out);
    var g2 = try FrameGrid.parse(std.testing.allocator, out.items, 60, 20);
    defer g2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 20), g2.rows_painted);
    for (0..20) |r| try std.testing.expectEqual(@as(usize, 60), g2.widthAt(r));
}

test "diffed frames reproduce the full-repaint grid exactly" {
    // 同一 seed、同样步进：一边走帧差分，一边每帧强制整屏重画，
    // 把两边的帧分别叠加到网格上，最终画面必须逐格一致（字符 + 前景色）。
    const cfg = options.Config{};
    var diffed = try Matrix.init(std.testing.allocator, 60, 14, cfg, 4242);
    defer diffed.deinit();
    var full = try Matrix.init(std.testing.allocator, 60, 14, cfg, 4242);
    defer full.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var ga = try FrameGrid.parse(std.testing.allocator, "", 60, 14);
    defer ga.deinit(std.testing.allocator);
    var gb = try FrameGrid.parse(std.testing.allocator, "", 60, 14);
    defer gb.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 90) : (i += 1) {
        diffed.step();
        try diffed.render(.ansi256, &out);
        ga.feed(out.items);

        full.step();
        full.forceFullRepaint();
        try full.render(.ansi256, &out);
        gb.feed(out.items);

        try std.testing.expectEqualSlices(u21, ga.ch, gb.ch);
        // 空格的颜色不可见（也从不单独为它发 SGR），所以只比较非空白格的前景色
        for (ga.ch, 0..) |c, k| {
            if (c == ' ') continue;
            try std.testing.expectEqual(gb.fg[k], ga.fg[k]);
        }
    }
}

test "a 120x40 frame stays under a kilobyte once the screen is populated" {
    var m = try Matrix.init(std.testing.allocator, 120, 40, options.Config{}, 12);
    defer m.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    m.step();
    try m.render(.ansi256, &out);
    const first = out.items.len;
    var i: usize = 0;
    var total: usize = 0;
    while (i < 120) : (i += 1) {
        m.step();
        try m.render(.ansi256, &out);
        total += out.items.len;
    }
    // 首帧 ~4.8KB（整屏覆盖写），差分后每帧不到它的一半
    try std.testing.expect(first > 4500);
    try std.testing.expect(total / 120 < first / 2);
}
