//! The bonsai growth algorithm: cbonsai's recursive `branch()` walker,
//! reproduced faithfully.
//!
//! The original draws as it recurses (and sleeps between steps). Here the walk
//! is pure computation: every glyph it would have printed is appended to a node
//! list together with a `tick`. `tick` counts exactly the points where cbonsai
//! calls `updateScreen()`, so a "live" replay can draw the same tree step by
//! step, and a resize can regenerate the tree from the same seed.
const std = @import("std");
const canvas = @import("canvas.zig");
const rand = @import("rand.zig");

pub const Allocator = std.mem.Allocator;

/// Branch kinds; the numeric values are the ones cbonsai's `setDeltas()` and
/// `chooseString()` switch on.
pub const BranchKind = enum(u8) {
    trunk = 0,
    shoot_left = 1,
    shoot_right = 2,
    dying = 3,
    dead = 4,
};

pub const max_nodes: usize = 500_000;
pub const max_depth: u32 = 1024;

pub const Params = struct {
    life_start: i32 = 32,
    multiplier: i32 = 5,
    /// Rows available to the tree (the pot starts at row `growth_height`).
    growth_height: i32 = 24,
    cols: i32 = 80,
    leaves: []const []const u8 = &.{"&"},
    /// dark leaves, dark wood, light leaves, light wood
    colors: [4]u8 = .{ 2, 3, 10, 11 },
};

pub const Node = struct {
    y: i32,
    x: i32,
    cp: u21,
    color: u8,
    bold: bool,
    tick: u32,
};

pub const Tree = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    /// Number of growth steps (== number of live-mode frames).
    ticks: u32 = 0,
    branches: u32 = 0,
    shoots: u32 = 0,
    shoot_counter: u32 = 0,
    seed: u64 = 0,
    params: Params = .{},

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    /// Draw every node with `tick <= upto` that has not been drawn yet.
    pub fn drawUntil(self: *const Tree, c: *canvas.Canvas, drawn: *usize, upto: u32) void {
        while (drawn.* < self.nodes.items.len) {
            const node = self.nodes.items[drawn.*];
            if (node.tick > upto) break;
            c.putCodepoint(node.y, node.x, node.cp, node.color, node.bold);
            drawn.* += 1;
        }
    }

    /// Number of nodes whose tick is <= `upto`.
    pub fn countUpTo(self: *const Tree, upto: u32) usize {
        var n: usize = 0;
        while (n < self.nodes.items.len and self.nodes.items[n].tick <= upto) n += 1;
        return n;
    }
};

const Grower = struct {
    gpa: Allocator,
    params: Params,
    tree: *Tree,
    prng: rand.Rand,
    tick: u32 = 0,
    depth: u32 = 0,
    truncated: bool = false,

    fn roll(self: *Grower, mod: u32) u32 {
        return self.prng.roll(mod);
    }

    fn multiplier(self: *const Grower) i32 {
        return @max(self.params.multiplier, 1);
    }

    fn setDeltas(self: *Grower, kind: BranchKind, life: i32, age: i32, dx: *i32, dy: *i32) void {
        const m = self.multiplier();
        dx.* = 0;
        dy.* = 0;
        switch (kind) {
            .trunk => {
                if (age <= 2 or life < 4) {
                    // New or dying trunk: squirm sideways.
                    dy.* = 0;
                    dx.* = @as(i32, @intCast(self.roll(3))) - 1;
                } else if (age < m * 3) {
                    // Young trunk grows wide; lift every half-multiplier steps.
                    const period = @max(@divTrunc(m, 2), 1);
                    dy.* = if (@mod(age, period) == 0) -1 else 0;
                    const dice = self.roll(10);
                    if (dice == 0) {
                        dx.* = -2;
                    } else if (dice <= 3) {
                        dx.* = -1;
                    } else if (dice <= 5) {
                        dx.* = 0;
                    } else if (dice <= 8) {
                        dx.* = 1;
                    } else {
                        dx.* = 2;
                    }
                } else {
                    // Middle-aged trunk: mostly upward.
                    const dice = self.roll(10);
                    dy.* = if (dice > 2) -1 else 0;
                    dx.* = @as(i32, @intCast(self.roll(3))) - 1;
                }
            },
            .shoot_left => {
                const d1 = self.roll(10);
                if (d1 <= 1) {
                    dy.* = -1;
                } else if (d1 <= 7) {
                    dy.* = 0;
                } else {
                    dy.* = 1;
                }
                const d2 = self.roll(10);
                if (d2 <= 1) {
                    dx.* = -2;
                } else if (d2 <= 5) {
                    dx.* = -1;
                } else if (d2 <= 8) {
                    dx.* = 0;
                } else {
                    dx.* = 1;
                }
            },
            .shoot_right => {
                const d1 = self.roll(10);
                if (d1 <= 1) {
                    dy.* = -1;
                } else if (d1 <= 7) {
                    dy.* = 0;
                } else {
                    dy.* = 1;
                }
                const d2 = self.roll(10);
                if (d2 <= 1) {
                    dx.* = 2;
                } else if (d2 <= 5) {
                    dx.* = 1;
                } else if (d2 <= 8) {
                    dx.* = 0;
                } else {
                    dx.* = -1;
                }
            },
            .dying => {
                const d1 = self.roll(10);
                if (d1 <= 1) {
                    dy.* = -1;
                } else if (d1 <= 8) {
                    dy.* = 0;
                } else {
                    dy.* = 1;
                }
                const d2 = self.roll(15);
                if (d2 == 0) {
                    dx.* = -3;
                } else if (d2 <= 2) {
                    dx.* = -2;
                } else if (d2 <= 5) {
                    dx.* = -1;
                } else if (d2 <= 8) {
                    dx.* = 0;
                } else if (d2 <= 11) {
                    dx.* = 1;
                } else if (d2 <= 13) {
                    dx.* = 2;
                } else {
                    dx.* = 3;
                }
            },
            .dead => {
                const d1 = self.roll(10);
                if (d1 <= 2) {
                    dy.* = -1;
                } else if (d1 <= 6) {
                    dy.* = 0;
                } else {
                    dy.* = 1;
                }
                dx.* = @as(i32, @intCast(self.roll(3))) - 1;
            },
        }
    }

    const Style = struct { color: u8, bold: bool };

    fn chooseColor(self: *Grower, kind: BranchKind) Style {
        const c = self.params.colors;
        return switch (kind) {
            .trunk, .shoot_left, .shoot_right => if (self.roll(2) == 0)
                .{ .color = c[3], .bold = true }
            else
                .{ .color = c[1], .bold = false },
            .dying => .{ .color = c[2], .bold = self.roll(10) == 0 },
            .dead => .{ .color = c[0], .bold = self.roll(3) == 0 },
        };
    }

    fn chooseString(self: *Grower, kind_in: BranchKind, life: i32, dx: i32, dy: i32) []const u8 {
        var kind = kind_in;
        if (life < 4) kind = .dying;
        switch (kind) {
            .trunk => {
                if (dy == 0) return "/~";
                if (dx < 0) return "\\|";
                if (dx == 0) return "/|\\";
                return "|/";
            },
            .shoot_left => {
                if (dy > 0) return "\\";
                if (dy == 0) return "\\_";
                if (dx < 0) return "\\|";
                if (dx == 0) return "/|";
                return "/";
            },
            .shoot_right => {
                if (dy > 0) return "/";
                if (dy == 0) return "_/";
                if (dx < 0) return "\\|";
                if (dx == 0) return "/|";
                return "/";
            },
            .dying, .dead => {
                const leaves = self.params.leaves;
                if (leaves.len == 0) return "&";
                return leaves[self.roll(@intCast(leaves.len))];
            },
        }
    }

    /// Append the glyphs of `text` at (y, x), clipped to the tree window
    /// (`0 <= y < growth_height`, `0 <= x < cols`) exactly like ncurses would.
    fn emit(self: *Grower, y: i32, x: i32, text: []const u8, style: Style) void {
        if (text.len == 0) return;
        const first_len: usize = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
        if (first_len > text.len) return;
        const first = std.unicode.utf8Decode(text[0..first_len]) catch '?';
        const width = canvas.charWidth(first);
        if (width == 0) return;
        // cbonsai skips glyphs that would straddle a wide-character boundary.
        if (@rem(x, @as(i32, width)) != 0) return;

        var cx = x;
        var i: usize = 0;
        while (i < text.len) {
            const n: usize = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + n > text.len) break;
            const cp = std.unicode.utf8Decode(text[i..][0..n]) catch 0xFFFD;
            i += n;
            if (cp < 0x20) continue;
            if (cx >= 0 and cx < self.params.cols and y >= 0 and y < self.params.growth_height) {
                if (self.tree.nodes.items.len >= max_nodes) {
                    self.truncated = true;
                } else {
                    self.tree.nodes.append(self.gpa, .{
                        .y = y,
                        .x = cx,
                        .cp = cp,
                        .color = style.color,
                        .bold = style.bold,
                        .tick = self.tick,
                    }) catch {
                        self.truncated = true;
                    };
                }
            }
            cx += @max(canvas.charWidth(cp), 1);
        }
    }

    fn branch(self: *Grower, x0: i32, y0: i32, kind: BranchKind, life_in: i32) void {
        if (self.depth >= max_depth) return;
        self.depth += 1;
        defer self.depth -= 1;

        const m = self.multiplier();
        self.tree.branches += 1;

        var x = x0;
        var y = y0;
        var life = life_in;
        var shoot_cooldown: i32 = m;

        while (life > 0) {
            if (self.tree.nodes.items.len >= max_nodes) {
                self.truncated = true;
                return;
            }
            life -= 1;
            const age = self.params.life_start - life;

            var dx: i32 = 0;
            var dy: i32 = 0;
            self.setDeltas(kind, life, age, &dx, &dy);

            // Do not grow down into the pot / off the bottom of the tree window.
            if (dy > 0 and y > self.params.growth_height - 2) dy -= 1;

            if (life < 3) {
                // Nearly dead branches turn into a burst of leaves.
                self.branch(x, y, .dead, life);
            } else if ((kind == .trunk or kind == .shoot_left or kind == .shoot_right) and
                life < m + 2)
            {
                self.branch(x, y, .dying, life);
            } else if (kind == .trunk and (self.roll(3) == 0 or @rem(life, m) == 0)) {
                if (self.roll(8) == 0 and life > 7) {
                    // Split the trunk into another trunk.
                    shoot_cooldown = m * 2;
                    const jitter = @as(i32, @intCast(self.roll(5))) - 2;
                    self.branch(x, y, .trunk, life + jitter);
                } else if (shoot_cooldown <= 0) {
                    // Fresh side shoot, alternating left/right.
                    shoot_cooldown = m * 2;
                    self.tree.shoots += 1;
                    self.tree.shoot_counter += 1;
                    const new_kind: BranchKind = @enumFromInt((self.tree.shoot_counter % 2) + 1);
                    self.branch(x, y, new_kind, life + m);
                }
            }
            shoot_cooldown -= 1;

            x += dx;
            y += dy;

            const style = self.chooseColor(kind);
            const text = self.chooseString(kind, life, dx, dy);
            self.emit(y, x, text, style);

            // cbonsai sleeps here in live mode; this is one "tick".
            self.tick +%= 1;
        }
    }
};

/// Grow one tree. `start_x`/`start_y` is where the trunk sprouts (one row above
/// the pot).
pub fn grow(
    gpa: Allocator,
    params: Params,
    seed: u64,
    start_x: i32,
    start_y: i32,
) Allocator.Error!Tree {
    var tree: Tree = .{ .gpa = gpa, .seed = seed, .params = params };
    errdefer tree.deinit();
    try tree.nodes.ensureTotalCapacity(gpa, 1024);

    var grower = Grower{
        .gpa = gpa,
        .params = params,
        .tree = &tree,
        .prng = rand.Rand.init(seed),
    };
    // cbonsai seeds the side-shoot parity with one random draw before any
    // growth happens; keeping it makes `-s N` reproduce cbonsai's trees.
    tree.shoot_counter = @intCast(grower.prng.next());
    grower.branch(start_x, start_y, .trunk, params.life_start);
    tree.ticks = grower.tick;
    return tree;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

fn testParams(rows: i32, cols: i32) Params {
    return .{
        .life_start = 32,
        .multiplier = 5,
        .growth_height = rows - 4,
        .cols = cols,
    };
}

test "growth never leaves the tree window" {
    const gpa = std.testing.allocator;
    const sizes = [_][2]i32{ .{ 24, 80 }, .{ 12, 40 }, .{ 6, 20 }, .{ 40, 120 }, .{ 5, 8 } };
    for (sizes) |sz| {
        const rows = sz[0];
        const cols = sz[1];
        const params = testParams(rows, cols);
        var t = try grow(gpa, params, 42, @divTrunc(cols, 2), params.growth_height - 1);
        defer t.deinit();
        try std.testing.expect(t.nodes.items.len > 0);
        for (t.nodes.items) |node| {
            try std.testing.expect(node.x >= 0);
            try std.testing.expect(node.x < cols);
            try std.testing.expect(node.y >= 0);
            try std.testing.expect(node.y < params.growth_height);
        }
        // Ticks are monotonically non-decreasing, which the live replay relies on.
        var prev: u32 = 0;
        for (t.nodes.items) |node| {
            try std.testing.expect(node.tick >= prev);
            prev = node.tick;
        }
    }
}

test "same seed produces the same tree" {
    const gpa = std.testing.allocator;
    const params = testParams(24, 80);
    var a = try grow(gpa, params, 1234, 40, 19);
    defer a.deinit();
    var b = try grow(gpa, params, 1234, 40, 19);
    defer b.deinit();
    var c = try grow(gpa, params, 4321, 40, 19);
    defer c.deinit();

    try std.testing.expectEqual(a.nodes.items.len, b.nodes.items.len);
    for (a.nodes.items, b.nodes.items) |na, nb| {
        try std.testing.expectEqual(na.x, nb.x);
        try std.testing.expectEqual(na.y, nb.y);
        try std.testing.expectEqual(na.cp, nb.cp);
    }
    try std.testing.expect(a.ticks == b.ticks);
    // A different seed must give a different tree.
    var same = a.nodes.items.len == c.nodes.items.len;
    if (same) {
        for (a.nodes.items, c.nodes.items) |na, nc| {
            if (na.x != nc.x or na.y != nc.y) {
                same = false;
                break;
            }
        }
    }
    try std.testing.expect(!same);
}

test "life and multiplier change the amount of branching" {
    const gpa = std.testing.allocator;
    var base_params = testParams(40, 120);
    base_params.leaves = &.{"&"};

    var small = try grow(gpa, .{ .life_start = 10, .multiplier = 2, .growth_height = 36, .cols = 120 }, 7, 60, 35);
    defer small.deinit();
    var big = try grow(gpa, base_params, 7, 60, 35);
    defer big.deinit();

    try std.testing.expect(big.nodes.items.len > small.nodes.items.len);
    try std.testing.expect(big.branches >= small.branches);
    try std.testing.expect(big.shoots >= 1);

    // Leaves: with the default "-c &" every leaf glyph is '&'.
    var leaves: usize = 0;
    for (big.nodes.items) |node| {
        if (node.cp == '&') leaves += 1;
    }
    try std.testing.expect(leaves > 0);

    // A multiplier of 1 should still terminate and produce a tree.
    var low = try grow(gpa, .{ .life_start = 32, .multiplier = 1, .growth_height = 36, .cols = 120 }, 3, 60, 35);
    defer low.deinit();
    try std.testing.expect(low.nodes.items.len > 0);
    try std.testing.expect(low.ticks > 0);
}

test "custom leaf glyphs are used for dying branches" {
    const gpa = std.testing.allocator;
    var params = testParams(30, 90);
    params.leaves = &.{"*"};
    var t = try grow(gpa, params, 99, 45, params.growth_height - 1);
    defer t.deinit();

    var leaves: usize = 0;
    var wood: usize = 0;
    for (t.nodes.items) |node| {
        switch (node.cp) {
            '*' => leaves += 1,
            '/', '\\', '|', '~', '_' => wood += 1,
            else => try std.testing.expect(false),
        }
    }
    try std.testing.expect(leaves > 0);
    try std.testing.expect(wood > 0);
}

test "drawing a tree into a canvas clips instead of crashing" {
    const gpa = std.testing.allocator;
    const params = testParams(10, 30);
    var t = try grow(gpa, params, 5, 15, params.growth_height - 1);
    defer t.deinit();

    var c = try canvas.Canvas.init(gpa, 10, 30);
    defer c.deinit();
    var drawn: usize = 0;
    t.drawUntil(&c, &drawn, std.math.maxInt(u32));
    try std.testing.expectEqual(t.nodes.items.len, drawn);
    try std.testing.expectEqual(t.countUpTo(std.math.maxInt(u32)), t.nodes.items.len);
}

test "golden tree: seed 42 at 80x24 matches cbonsai" {
    // These numbers were verified against cbonsai built from gitlab HEAD:
    // its branch() walks the exact same sequence of (life, age, dx, dy, x, y,
    // glyph) tuples for the same seed, and `stages` equals cbonsai's
    // growthSteps counter.
    const gpa = std.testing.allocator;
    const params = testParams(24, 80);
    var t = try grow(gpa, params, 42, 40, params.growth_height - 1);
    defer t.deinit();

    try std.testing.expectEqual(@as(u32, 512), t.ticks);
    try std.testing.expectEqual(@as(usize, 653), t.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 360), t.branches);
    try std.testing.expectEqual(@as(u32, 3), t.shoots);

    // A cheap position+glyph checksum, to notice any drift in the walk.
    var hash: u64 = 1469598103934665603;
    for (t.nodes.items) |node| {
        const code = (@as(u64, @intCast(node.y + 128)) << 32) |
            (@as(u64, @intCast(node.x + 128)) << 16) |
            @as(u64, node.cp);
        hash ^= code;
        hash *%= 1099511628211;
    }
    try std.testing.expectEqual(@as(u64, 0xcf45_6413_da59_2798), hash);
}
