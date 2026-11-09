const std = @import("std");
const grid = @import("grid.zig");
const palette = @import("palette.zig");

pub const Dir = enum {
    up,
    down,
    left,
    right,
};

pub const Kind = enum {
    heavy,
    light,
    curved,
    double,
    blocks,
    knobby,
    dots,
};

// 每种管道 8 个字符：上、下、左、右、左上弯、右上弯、左下弯、右下弯。
const heavy_chars = [8][]const u8{ "┃", "┃", "━", "━", "┏", "┓", "┗", "┛" };
const light_chars = [8][]const u8{ "│", "│", "─", "─", "┌", "┐", "└", "┘" };
const curved_chars = [8][]const u8{ "│", "│", "─", "─", "╭", "╮", "╰", "╯" };
const double_chars = [8][]const u8{ "║", "║", "═", "═", "╔", "╗", "╚", "╝" };
const block_chars = [8][]const u8{ "█", "█", "▀", "▀", "█", "█", "▀", "▀" };
const knobby_chars = [8][]const u8{ "╽", "╿", "╼", "╾", "┎", "┒", "┖", "┚" };
const dot_chars = [8][]const u8{ "•", "•", "•", "•", "•", "•", "•", "•" };

fn chars(kind: Kind) *const [8][]const u8 {
    return switch (kind) {
        .heavy => &heavy_chars,
        .light => &light_chars,
        .curved => &curved_chars,
        .double => &double_chars,
        .blocks => &block_chars,
        .knobby => &knobby_chars,
        .dots => &dot_chars,
    };
}

pub fn parseKind(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "heavy")) return .heavy;
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "curved")) return .curved;
    if (std.mem.eql(u8, name, "double")) return .double;
    // pipes-rs 把这一套叫 outline；两个名字都收
    if (std.mem.eql(u8, name, "outline")) return .double;
    if (std.mem.eql(u8, name, "blocks")) return .blocks;
    if (std.mem.eql(u8, name, "knobby")) return .knobby;
    if (std.mem.eql(u8, name, "dots")) return .dots;
    return null;
}

/// 根据进入方向和离开方向选出字符下标。
fn glyphIndex(prev: Dir, next: Dir) usize {
    return switch (prev) {
        .up => switch (next) {
            .left => 5,
            .right => 4,
            else => 0,
        },
        .down => switch (next) {
            .left => 7,
            .right => 6,
            else => 1,
        },
        .left => switch (next) {
            .up => 6,
            .down => 4,
            else => 2,
        },
        .right => switch (next) {
            .up => 7,
            .down => 5,
            else => 3,
        },
    };
}

fn straightIndex(dir: Dir) usize {
    return switch (dir) {
        .up => 0,
        .down => 1,
        .left => 2,
        .right => 3,
    };
}

fn glyphFor(kind: Kind, prev: Dir, next: Dir) []const u8 {
    return chars(kind)[glyphIndex(prev, next)];
}

fn straightGlyph(kind: Kind, dir: Dir) []const u8 {
    return chars(kind)[straightIndex(dir)];
}

pub const Pipe = struct {
    x: i32 = 0,
    y: i32 = 0,
    prev_dir: Dir = .up,
    dir: Dir = .up,
    kind: Kind = .heavy,
    color: palette.Color = .{ .kind = .none },
    alive: bool = false,
    /// 该管道实际画出的格子数（含出生格）。
    length: u32 = 0,
    /// 出生序号，用于 --max-total-length 找最老管道。
    spawn_seq: u64 = 0,

    fn spawnInternal(g: *grid.Grid, rng: std.Random, kind: Kind, color: palette.Color) ?Pipe {
        if (g.cols < 2 or g.rows < 2) return null;

        const cols: i32 = @intCast(g.cols);
        const rows: i32 = @intCast(g.rows);

        var attempt: usize = 0;
        while (attempt < 128) : (attempt += 1) {
            const dir: Dir = switch (rng.uintLessThan(u8, 4)) {
                0 => .up,
                1 => .down,
                2 => .left,
                else => .right,
            };

            var x: i32 = 0;
            var y: i32 = 0;
            switch (dir) {
                .up => {
                    x = rng.intRangeAtMost(i32, 0, cols - 1);
                    y = rows - 1;
                },
                .down => {
                    x = rng.intRangeAtMost(i32, 0, cols - 1);
                    y = 0;
                },
                .left => {
                    x = cols - 1;
                    y = rng.intRangeAtMost(i32, 0, rows - 1);
                },
                .right => {
                    x = 0;
                    y = rng.intRangeAtMost(i32, 0, rows - 1);
                },
            }

            if (!g.isFree(x, y)) continue;
            g.setGlyph(@intCast(x), @intCast(y), straightGlyph(kind, dir), color);

            return .{
                .x = x,
                .y = y,
                .prev_dir = dir,
                .dir = dir,
                .kind = kind,
                .color = color,
                .alive = true,
                .length = 1,
            };
        }
        return null;
    }

    pub fn spawn(
        g: *grid.Grid,
        rng: std.Random,
        colors: *palette.Colors,
        kinds: []const Kind,
    ) ?Pipe {
        if (kinds.len == 0) return null;
        const kind = kinds[rng.uintLessThan(usize, kinds.len)];
        const color = colors.next(rng);
        return spawnInternal(g, rng, kind, color);
    }

    /// -i/--inherit-style：用上一条管道的 kind/color 出生，并换一个随机位置/方向。
    pub fn spawnLike(g: *grid.Grid, rng: std.Random, like: *const Pipe) ?Pipe {
        return spawnInternal(g, rng, like.kind, like.color);
    }

    fn maybeTurn(dir: Dir, rng: std.Random, chance: f32) Dir {
        if (rng.float(f32) >= chance) return dir;
        const go_left = rng.boolean();
        return switch (dir) {
            .up => if (go_left) .left else .right,
            .down => if (go_left) .right else .left,
            .left => if (go_left) .down else .up,
            .right => if (go_left) .up else .down,
        };
    }

    /// 一步：先做 RGB 色相旋转，再把当前格定型，决定方向并前进一格。
    pub fn step(self: *Pipe, g: *grid.Grid, rng: std.Random, turn_chance: f32, rainbow: u8) void {
        if (!self.alive) return;
        self.color = palette.rotateHue(self.color, rainbow);

        const next_dir = maybeTurn(self.dir, rng, turn_chance);
        const glyph = glyphFor(self.kind, self.prev_dir, next_dir);
        if (self.x >= 0 and self.y >= 0) {
            g.setGlyph(@intCast(self.x), @intCast(self.y), glyph, self.color);
        }

        var nx = self.x;
        var ny = self.y;
        switch (next_dir) {
            .up => ny -= 1,
            .down => ny += 1,
            .left => nx -= 1,
            .right => nx += 1,
        }

        if (!g.isFree(nx, ny)) {
            self.alive = false;
            return;
        }

        self.prev_dir = next_dir;
        self.dir = next_dir;
        self.x = nx;
        self.y = ny;
        self.length += 1;
        g.setGlyph(@intCast(nx), @intCast(ny), straightGlyph(self.kind, next_dir), self.color);
    }
};

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

test "管道不会走进已占用的格子" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 5, 5);
    defer g.deinit();

    const color: palette.Color = .{ .kind = .ansi, .index = 2 };
    g.setGlyph(3, 2, "┃", color);

    var p = Pipe{
        .x = 2,
        .y = 2,
        .prev_dir = .right,
        .dir = .right,
        .kind = .heavy,
        .color = color,
        .alive = true,
        .length = 1,
    };
    var prng = std.Random.DefaultPrng.init(123);
    p.step(&g, prng.random(), 0.0, 0);

    try std.testing.expect(!p.alive);
    try std.testing.expectEqual(@as(i32, 2), p.x);
    try std.testing.expectEqual(@as(i32, 2), p.y);
}

test "网格占满时 spawn 返回 null" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 3, 3);
    defer g.deinit();

    var y: usize = 0;
    while (y < 3) : (y += 1) {
        var x: usize = 0;
        while (x < 3) : (x += 1) {
            g.setGlyph(x, y, "┃", .{ .kind = .ansi, .index = 2 });
        }
    }

    var colors = palette.Colors{};
    var prng = std.Random.DefaultPrng.init(123);
    const kinds = [_]Kind{.heavy};
    try std.testing.expect(Pipe.spawn(&g, prng.random(), &colors, &kinds) == null);
}

test "inherit-style 真正继承 kind 和 color" {
    const allocator = std.testing.allocator;
    var g = try grid.Grid.init(allocator, 20, 10);
    defer g.deinit();

    const old = Pipe{
        .kind = .knobby,
        .color = .{ .kind = .rgb, .r = 12, .g = 200, .b = 34, .bold = true },
        .alive = false,
        .length = 9,
        .spawn_seq = 7,
    };
    var prng = std.Random.DefaultPrng.init(99);
    const np = Pipe.spawnLike(&g, prng.random(), &old) orelse return error.SpawnFailed;

    try std.testing.expect(np.alive);
    try std.testing.expectEqual(Kind.knobby, np.kind);
    try std.testing.expectEqual(old.color.r, np.color.r);
    try std.testing.expectEqual(old.color.g, np.color.g);
    try std.testing.expectEqual(old.color.b, np.color.b);
    try std.testing.expect(np.color.bold);
    try std.testing.expectEqual(@as(u32, 1), np.length);
}

test "max-total-length 按最老管道回收" {
    var pipes = [_]Pipe{
        .{ .alive = true, .length = 10, .spawn_seq = 3 },
        .{ .alive = true, .length = 20, .spawn_seq = 1 },
        .{ .alive = true, .length = 5, .spawn_seq = 2 },
    };

    try std.testing.expectEqual(@as(u64, 35), totalLength(&pipes));
    try std.testing.expect(reclaimOldest(&pipes));
    try std.testing.expect(!pipes[1].alive);
    try std.testing.expectEqual(@as(u64, 15), totalLength(&pipes));

    try std.testing.expect(reclaimOldest(&pipes));
    try std.testing.expect(!pipes[2].alive);
    try std.testing.expectEqual(@as(u64, 10), totalLength(&pipes));
}
