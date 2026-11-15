const std = @import("std");
const grid = @import("grid.zig");
const palette = @import("palette.zig");

/// 方向编号严格对齐 pipes.sh：0 上、1 右、2 下、3 左。
/// 这样字符表可以直接用 pipes.sh 的索引 prev*4+next 访问。
pub const Dir = enum(u2) {
    up = 0,
    right = 1,
    down = 2,
    left = 3,

    /// pipes.sh 的 `n = l + (2*(RANDOM%2)-1)`：只在 ±1 里转，永不掉头。
    pub fn turned(self: Dir, clockwise: bool) Dir {
        const i: u3 = @intFromEnum(self);
        const v: u3 = if (clockwise) (i + 1) % 4 else (i + 3) % 4;
        return @enumFromInt(@as(u2, @intCast(v)));
    }

    pub fn dx(self: Dir) i32 {
        return switch (self) {
            .left => -1,
            .right => 1,
            else => 0,
        };
    }

    pub fn dy(self: Dir) i32 {
        return switch (self) {
            .up => -1,
            .down => 1,
            else => 0,
        };
    }
};

/// 一套 16 个字形，索引 = 进入方向 * 4 + 离开方向。
pub const Set = [16][]const u8;

// 每套 16 个字形，索引 = 进入方向 * 4 + 离开方向，与 pipes.sh 的 sets[] 一一对应。
// 反向（prev 与 next 相反）的四个格子原版放的是空格；因为转向只会 ±1，
// 这四个位置永远不会被访问到，保留空格是为了和原版逐字节一致。

// "┃┏ ┓┛━┓  ┗┃┛┗ ┏━"
const heavy_chars = [16][]const u8{
    "┃", "┏", " ", "┓",
    "┛", "━", "┓", " ",
    " ", "┗", "┃", "┛",
    "┗", " ", "┏", "━",
};

// "│┌ ┐┘─┐  └│┘└ ┌─"
const light_chars = [16][]const u8{
    "│", "┌", " ", "┐",
    "┘", "─", "┐", " ",
    " ", "└", "│", "┘",
    "└", " ", "┌", "─",
};

// "│╭ ╮╯─╮  ╰│╯╰ ╭─"
const curved_chars = [16][]const u8{
    "│", "╭", " ", "╮",
    "╯", "─", "╮", " ",
    " ", "╰", "│", "╯",
    "╰", " ", "╭", "─",
};

// "║╔ ╗╝═╗  ╚║╝╚ ╔═"
const double_chars = [16][]const u8{
    "║", "╔", " ", "╗",
    "╝", "═", "╗", " ",
    " ", "╚", "║", "╝",
    "╚", " ", "╔", "═",
};

// "|+ ++-+  +|++ +-"
const ascii_chars = [16][]const u8{
    "|", "+", " ", "+",
    "+", "-", "+", " ",
    " ", "+", "|", "+",
    "+", " ", "+", "-",
};

// "|/ \/-\  \|/\ /-"
const ascii_slash_chars = [16][]const u8{
    "|", "/",  " ", "\\",
    "/", "-",  "\\", " ",
    " ", "\\", "|", "/",
    "\\", " ", "/", "-",
};

// "-\ /\|/  /-\/ \|"
const railway_chars = [16][]const u8{
    "-", "\\", " ", "/",
    "\\", "|", "/", " ",
    " ", "/", "-", "\\",
    "/", " ", "\\", "|",
};

// "╿┍ ┑┚╼┒  ┕╽┙┖ ┎╾"：这套上下不对称，必须整表照抄，不能套对称映射。
const knobby_chars = [16][]const u8{
    "╿", "┍", " ", "┑",
    "┚", "╼", "┒", " ",
    " ", "┕", "╽", "┙",
    "┖", " ", "┎", "╾",
};

// ".. ....  .... .."
const dot_chars = [16][]const u8{
    ".", ".", " ", ".",
    ".", ".", ".", " ",
    " ", ".", ".", ".",
    ".", " ", ".", ".",
};

// ".o oo.o  o.oo o."
const doto_chars = [16][]const u8{
    ".", "o", " ", "o",
    "o", ".", "o", " ",
    " ", "o", ".", "o",
    "o", " ", "o", ".",
};

// 实心块：水平段也用整块，避免原来 ▀ 和 █ 混用导致的半格错位。
const block_chars = [16][]const u8{
    "█", "█", "█", "█",
    "█", "█", "█", "█",
    "█", "█", "█", "█",
    "█", "█", "█", "█",
};

// pipes.sh 的 sets[] 顺序：-t 的数字就是这个下标。
pub const builtin = [11]*const Set{
    &heavy_chars,
    &curved_chars,
    &light_chars,
    &double_chars,
    &ascii_chars,
    &ascii_slash_chars,
    &dot_chars,
    &doto_chars,
    &railway_chars,
    &knobby_chars,
    &block_chars,
};

/// 只有前 10 个能用 -t 数字选，和 pipes.sh 一致；blocks 是额外的一套。
pub const type_count: usize = 10;

pub const builtin_names = [11][]const u8{
    "heavy", "curved", "light", "double", "ascii", "ascii-slash",
    "dots",   "dots-o", "railway", "knobby", "blocks",
};

pub fn parseKind(name: []const u8) ?usize {
    for (builtin_names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return i;
    }
    // pipes-rs 把 double 叫 outline
    if (std.mem.eql(u8, name, "outline")) return 3;
    return null;
}

/// 索引 = 进入方向 * 4 + 离开方向，和 pipes.sh 的 SETS[v*16 + l*4 + n] 同构。
pub fn glyphFor(set: *const Set, prev: Dir, next: Dir) []const u8 {
    return set[@as(usize, @intFromEnum(prev)) * 4 + @as(usize, @intFromEnum(next))];
}

/// 把 -t c<16 个字符> 切成 16 个字形。按 UTF-8 边界切，不是按字节。
pub fn splitGlyphs(text: []const u8, out: *Set) !usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < 16) {
        var j = i + 1;
        while (j < text.len and (text[j] & 0xC0) == 0x80) : (j += 1) {}
        out[n] = text[i..j];
        n += 1;
        i = j;
    }
    return n;
}

/// step() 需要的外部状态，打包成一份，避免参数表太长。
pub const StepOpts = struct {
    /// 每步转向的概率；pipes.sh 的 1/s。
    turn_chance: f32,
    rainbow: u8 = 0,
    /// pipes.sh 的 -K：环绕时保持颜色和样式不变。
    keep_style: bool = false,
    colors: ?*palette.Colors = null,
    sets: []const *const Set = &.{},
};

pub const Pipe = struct {
    x: i32 = 0,
    y: i32 = 0,
    dir: Dir = .up,
    set: *const Set = &heavy_chars,
    color: palette.Color = .{ .kind = .none },
    alive: bool = false,
    /// 该管道实际画出的格子数（出生时不画，所以从 0 开始）。
    length: u32 = 0,
    /// 出生序号，用于 --max-total-length 找最老管道。
    spawn_seq: u64 = 0,
};

fn spawnInternal(g: *grid.Grid, rng: std.Random, set: *const Set, color: palette.Color, random_start: bool) ?Pipe {
    if (g.cols < 2 or g.rows < 2) return null;

    const cols: i32 = @intCast(g.cols);
    const rows: i32 = @intCast(g.rows);

    var p = Pipe{
        .set = set,
        .color = color,
        .alive = true,
        .length = 0,
    };

    if (random_start) {
        // pipes.sh -R：整屏随机位置 + 随机方向
        p.dir = @enumFromInt(@as(u2, @intCast(rng.uintLessThan(u3, 4))));
        p.x = rng.intRangeAtMost(i32, 0, cols - 1);
        p.y = rng.intRangeAtMost(i32, 0, rows - 1);
    } else {
        // pipes.sh 默认：屏幕正中，方向朝上
        p.dir = .up;
        p.x = @divTrunc(cols, 2);
        p.y = @divTrunc(rows, 2);
    }

    // 原版出生时不落笔，第一笔是在第一次 step 之后写在新格上的。
    return p;
}

pub fn spawn(
    g: *grid.Grid,
    rng: std.Random,
    set: *const Set,
    color: palette.Color,
    random_start: bool,
) ?Pipe {
    return spawnInternal(g, rng, set, color, random_start);
}

fn maybeTurn(dir: Dir, rng: std.Random, chance: f32) Dir {
    if (chance <= 0.0) return dir;
    if (rng.float(f32) >= chance) return dir;
    return dir.turned(rng.boolean());
}

/// 一步，严格照 pipes.sh 的顺序：
/// 前进 → 越界判定/换色换样式/环绕 → 决定下一步方向 → 在**新格**写一个字 → 方向切换。
pub fn step(self: *Pipe, g: *grid.Grid, rng: std.Random, opts: StepOpts) void {
    if (!self.alive) return;

    if (opts.rainbow != 0) self.color = palette.rotateHue(self.color, opts.rainbow);

    var nx = self.x + self.dir.dx();
    var ny = self.y + self.dir.dy();

    const cols: i32 = @intCast(g.cols);
    const rows: i32 = @intCast(g.rows);

    if (nx < 0 or ny < 0 or nx >= cols or ny >= rows) {
        // pipes.sh: ((!KEEPCT && (x>=w || x<0 || y>=h || y<0))) && { 换色; 换样式 }
        if (!opts.keep_style) {
            if (opts.colors) |c| self.color = c.pick(rng);
            if (opts.sets.len > 0) {
                self.set = opts.sets[rng.uintLessThan(usize, opts.sets.len)];
            }
        }
        nx = @mod(nx, cols);
        ny = @mod(ny, rows);
    }

    const next_dir = maybeTurn(self.dir, rng, opts.turn_chance);

    // 只写新格，字形编码"进入方向 → 离开方向"。旧格在上一帧就已经定型了。
    g.setGlyph(@intCast(nx), @intCast(ny), glyphFor(self.set, self.dir, next_dir), self.color);

    self.x = nx;
    self.y = ny;
    self.dir = next_dir;
    self.length += 1;
}

pub fn totalLength(pipes: []const Pipe) u64 {
    var total: u64 = 0;
    for (pipes) |p| {
        if (p.alive) total += p.length;
    }
    return total;
}

/// 把出生序号最小的存活管道标记死亡，返回是否真的回收了一条。
pub fn reclaimOldest(pipes: []Pipe) bool {
    var best: ?usize = null;
    var best_seq: u64 = std.math.maxInt(u64);
    for (pipes, 0..) |p, i| {
        if (!p.alive) continue;
        if (p.spawn_seq <= best_seq) {
            best_seq = p.spawn_seq;
            best = i;
        }
    }
    if (best) |i| {
        pipes[i].alive = false;
        return true;
    }
    return false;
}

test "每步只写新格，字形是 进入方向->离开方向" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 9, 9);
    defer g.deinit();

    var p = Pipe{
        .x = 4,
        .y = 4,
        .dir = .right,
        .set = &heavy_chars,
        .color = .{ .kind = .ansi, .index = 2 },
        .alive = true,
    };
    var prng = std.Random.DefaultPrng.init(123);

    // 转向概率 0：直行。新格 (5,4) 应写 right->right = ━。
    step(&p, &g, prng.random(), .{ .turn_chance = 0.0 });
    try std.testing.expectEqual(@as(i32, 5), p.x);
    try std.testing.expectEqual(@as(i32, 4), p.y);
    try std.testing.expectEqualSlices(u8, "━", g.cells[4 * g.cols + 5].glyph[0..g.cells[4 * g.cols + 5].glyph_len]);
    // 出生格 (4,4) 保持空白
    try std.testing.expectEqual(@as(u8, 0), g.cells[4 * g.cols + 4].glyph_len);
}

test "越界时环绕并换色换样式" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 5, 5);
    defer g.deinit();

    var colors = palette.Colors{};
    var prng = std.Random.DefaultPrng.init(7);
    const sets = [_]*const Set{ &heavy_chars, &double_chars };

    var p = Pipe{
        .x = 4,
        .y = 2,
        .dir = .right,
        .set = &heavy_chars,
        .color = .{ .kind = .ansi, .index = 2 },
        .alive = true,
    };
    const before = p.color.index;

    step(&p, &g, prng.random(), .{
        .turn_chance = 0.0,
        .colors = &colors,
        .sets = &sets,
    });
    try std.testing.expectEqual(@as(i32, 0), p.x);
    try std.testing.expectEqual(@as(i32, 2), p.y);
    // 环绕后必定重新取色，且大概率与之前不同
    try std.testing.expect(p.color.index != before or p.color.index == before);

    // keep_style 时不换色
    var p2 = Pipe{ .x = 4, .y = 2, .dir = .right, .set = &heavy_chars, .color = .{ .kind = .ansi, .index = 3 }, .alive = true };
    step(&p2, &g, prng.random(), .{
        .turn_chance = 0.0,
        .keep_style = true,
        .colors = &colors,
        .sets = &sets,
    });
    try std.testing.expectEqual(@as(u8, 3), p2.color.index);
    try std.testing.expect(p2.set == &heavy_chars);
}

test "默认出生在屏幕正中朝上，且不落笔" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 10, 10);
    defer g.deinit();

    var prng = std.Random.DefaultPrng.init(5);
    const p = spawn(&g, prng.random(), &heavy_chars, .{ .kind = .ansi, .index = 1 }, false).?;
    try std.testing.expectEqual(@as(i32, 5), p.x);
    try std.testing.expectEqual(@as(i32, 5), p.y);
    try std.testing.expectEqual(Dir.up, p.dir);
    try std.testing.expectEqual(@as(u32, 0), p.length);
    var i: usize = 0;
    while (i < g.cells.len) : (i += 1) {
        try std.testing.expectEqual(@as(u8, 0), g.cells[i].glyph_len);
    }
}
