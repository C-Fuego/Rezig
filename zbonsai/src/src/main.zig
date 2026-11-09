//! zbonsai -- a beautifully random bonsai tree generator for the terminal.
//!
//! Layout of a run:
//!   1. parse arguments (args.zig),
//!   2. work out the terminal geometry and where the pot/tree go,
//!   3. grow one tree (tree.zig),
//!   4. draw it into a cell grid (canvas.zig) either all at once, step by step
//!      (live), or repeatedly (infinite / screensaver),
//!   5. restore the terminal on every exit path.
//!
//! When stdout is not a terminal the TUI is skipped entirely and the tree is
//! printed as plain text, so `zbonsai -p | cat` always works.
const std = @import("std");

const args = @import("args.zig");
const base = @import("base.zig");
const canvas = @import("canvas.zig");
const message = @import("message.zig");
const term = @import("term.zig");
const tree = @import("tree.zig");

const Allocator = std.mem.Allocator;

const stdout_fd: term.fd_t = 1;
const stdin_fd: term.fd_t = 0;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv_slices = try init.minimal.args.toSlice(arena);
    const argv: []const []const u8 = if (argv_slices.len > 0) argv_slices[1..] else &.{};

    // A bad option is reported by args.parse() itself; exit quietly instead of
    // unwinding with an error trace.
    var cfg: args.Config = switch (args.parse(arena, argv) catch std.process.exit(1)) {
        .help => {
            args.printHelp();
            return;
        },
        .version => {
            args.printVersion();
            return;
        },
        .run => |c| c,
    };
    defer cfg.deinit(arena);

    term.installSignalHandlers();

    // Not a terminal on either end: no raw mode, no escape sequences, no
    // "press any key" - just render one tree and exit.
    //
    // `ZBONSAI_FORCE_TTY=1` forces the TUI path anyway; that is the only way to
    // smoke-test raw mode, the alternate screen and the live animation in a
    // sandbox without a pty.
    const force_tty = init.environ_map.get("ZBONSAI_FORCE_TTY") != null;
    const interactive = force_tty or (term.isTty(stdin_fd) and term.isTty(stdout_fd));
    var app = App.init(gpa, init.io, &cfg, init.environ_map, arena, interactive);
    defer app.deinit();

    try app.run();
}

const KeyEvent = union(enum) {
    none,
    resize,
    quit,
    key: u8,
};

const App = struct {
    gpa: Allocator,
    arena: Allocator,
    io: std.Io,
    cfg: *args.Config,
    environ: *const std.process.Environ.Map,
    out: term.Out,
    raw: term.RawMode = .{},
    interactive: bool,
    use_alt_screen: bool = false,
    cursor_hidden: bool = false,

    size: term.Size = term.default_size,
    c: canvas.Canvas,
    renderer: canvas.Renderer,

    // Layout, recomputed on every resize.
    base_dims: base.Size = .{},
    base_x: i32 = 0,
    base_y: i32 = 0,
    growth_height: i32 = 0,
    trunk_x: i32 = 0,
    trunk_y: i32 = 0,
    msg_layout: ?message.Layout = null,

    tree: tree.Tree,
    drawn: usize = 0,
    seed: u64 = 0,
    /// How many trees this run has grown; mixed into fresh seeds.
    tree_count: u64 = 0,

    fn init(
        gpa: Allocator,
        io: std.Io,
        cfg: *args.Config,
        environ: *const std.process.Environ.Map,
        arena: Allocator,
        interactive: bool,
    ) App {
        return .{
            .gpa = gpa,
            .arena = arena,
            .io = io,
            .cfg = cfg,
            .environ = environ,
            .out = term.Out.init(stdout_fd),
            .interactive = interactive,
            .c = .{ .gpa = gpa },
            .renderer = canvas.Renderer.init(gpa),
            .tree = .{ .gpa = gpa },
        };
    }

    fn deinit(self: *App) void {
        self.teardown();
        self.c.deinit();
        self.renderer.deinit();
        self.tree.deinit();
        if (self.msg_layout) |*l| l.deinit();
    }

    // -- terminal lifecycle ------------------------------------------------

    fn enterTui(self: *App) void {
        if (!self.interactive) return;
        // Alternate screen everywhere except a pure `--print` run, where the
        // result has to survive on the normal screen.
        if (!self.cfg.print_tree or self.cfg.live) {
            term.enterAltScreen(&self.out);
            self.use_alt_screen = true;
        }
        // Raw mode may fail (stdin is not a terminal); the cursor is hidden
        // either way, because the tree is positioned with absolute moves.
        _ = self.raw.enable(stdin_fd);
        term.hideCursor(&self.out);
        self.cursor_hidden = true;
        self.out.flush();
    }

    /// Restore the terminal. Safe to call more than once.
    fn teardown(self: *App) void {
        if (!self.interactive) return;
        if (self.cursor_hidden) {
            term.showCursor(&self.out);
            self.cursor_hidden = false;
        }
        term.resetStyle(&self.out);
        if (self.use_alt_screen) {
            term.exitAltScreen(&self.out);
            self.use_alt_screen = false;
        }
        self.out.flush();
        self.raw.disable();
    }

    // -- layout ------------------------------------------------------------

    fn applyLayout(self: *App) !void {
        self.size = term.querySize(stdout_fd, self.environ);
        const rows: i32 = self.size.rows;
        const cols: i32 = self.size.cols;
        try self.c.resize(@intCast(rows), @intCast(cols));
        self.renderer.invalidate();

        self.base_dims = base.dimensions(self.cfg.base_type);
        // A pot that does not fit is simply not drawn (cbonsai does the same).
        if (self.base_dims.width > cols or self.base_dims.height > rows) self.base_dims = .{};

        self.base_y = rows - self.base_dims.height;
        self.base_x = @divTrunc(cols, 2) - @divTrunc(self.base_dims.width, 2);
        if (self.base_x < 0) self.base_x = 0;
        self.growth_height = self.base_y;
        self.trunk_x = self.base_x + @divTrunc(self.base_dims.width, 2);
        self.trunk_y = self.base_y - 1;

        // The message wraps differently at a different width.
        if (self.msg_layout) |*l| l.deinit();
        self.msg_layout = null;
        if (self.cfg.message) |text| {
            self.msg_layout = try message.layout(self.arena, text, message.contentMaxWidth(@intCast(cols)));
        }
    }

    fn treeParams(self: *const App) tree.Params {
        return .{
            .life_start = self.cfg.life_start,
            .multiplier = self.cfg.multiplier,
            .growth_height = self.growth_height,
            .cols = self.size.cols,
            .leaves = self.cfg.leafList(),
            .colors = self.cfg.colors,
        };
    }

    /// Grow a fresh tree for `seed` using the current geometry.
    fn regrow(self: *App, seed: u64) !void {
        self.tree.deinit();
        self.tree = try tree.grow(self.gpa, self.treeParams(), seed, self.trunk_x, self.trunk_y);
        self.seed = seed;
        self.tree_count += 1;
    }

    fn paintBackground(self: *App) void {
        self.c.clear();
        base.draw(&self.c, self.cfg.base_type, self.base_x, self.base_y, self.cfg.colors);
        self.drawn = 0;
    }

    /// The message box lives in ncurses panels above the tree window, so it is
    /// always painted last: growth can never punch holes into it.
    fn paintMessage(self: *App) void {
        if (self.msg_layout) |*l| _ = message.drawBox(&self.c, l);
    }

    fn paintVerbose(self: *App) void {
        if (self.cfg.verbose == 0) return;
        const color = base.text_color;
        var buf: [128]u8 = undefined;

        var text = std.fmt.bufPrint(&buf, "maxX: {d:0>3}, maxY: {d:0>3}", .{ self.size.cols, self.size.rows }) catch "";
        self.c.putAscii(2, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "life: {d}, multiplier: {d}", .{ self.cfg.life_start, self.cfg.multiplier }) catch "";
        self.c.putAscii(3, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "shoots: {d:0>2}", .{self.tree.shoots}) catch "";
        self.c.putAscii(4, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "branches: {d}", .{self.tree.branches}) catch "";
        self.c.putAscii(5, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "stages: {d}", .{self.tree.ticks}) catch "";
        self.c.putAscii(6, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "nodes: {d}", .{self.tree.nodes.items.len}) catch "";
        self.c.putAscii(7, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "seed: {d}", .{self.seed}) catch "";
        self.c.putAscii(8, 5, text, color, true);
        text = std.fmt.bufPrint(&buf, "base: {d} at {d},{d}", .{ self.cfg.base_type, self.base_x, self.base_y }) catch "";
        self.c.putAscii(9, 5, text, color, true);
    }

    /// Repaint everything that should be visible at growth stage `tick`.
    fn paint(self: *App, tick: u32) void {
        self.paintBackground();
        self.paintVerbose();
        self.tree.drawUntil(&self.c, &self.drawn, tick);
        self.paintMessage();
    }

    fn commit(self: *App) void {
        self.renderer.draw(&self.c, &self.out) catch {};
    }

    // -- input -------------------------------------------------------------

    /// Wait up to `timeout_ns` for a key or a signal (0 = non-blocking).
    fn waitKey(self: *App, timeout_ns: u64) KeyEvent {
        if (term.quitRequested()) return .quit;
        if (term.tookResize()) return .resize;
        if (!self.interactive) return .none;

        const ms_i64: i64 = @intCast(@min(@divTrunc(timeout_ns, std.time.ns_per_ms), 1000));
        if (!term.pollInput(stdin_fd, @intCast(ms_i64))) {
            if (term.quitRequested()) return .quit;
            if (term.tookResize()) return .resize;
            return .none;
        }
        const key = term.readKey(stdin_fd);
        if (term.quitRequested()) return .quit;
        if (term.tookResize()) return .resize;
        return .{ .key = key orelse 0 };
    }

    // -- modes -------------------------------------------------------------

    fn run(self: *App) !void {
        self.seed = self.resolveSeed();
        self.enterTui();

        if (!self.interactive) {
            try self.runPlain();
            return;
        }

        try self.runInteractive();

        if (self.cfg.print_tree) {
            // Leave the alternate screen first, so the tree survives in the
            // scrollback exactly like `cbonsai -p` does after `endwin()`.
            self.teardown();
            canvas.printPlain(&self.c, &self.out, true);
        }
    }

    fn resolveSeed(self: *App) u64 {
        if (self.cfg.seed_given and self.cfg.seed != 0) return self.cfg.seed;
        return self.freshSeed();
    }

    /// A new seed that never reuses `--seed`; infinite mode reseeds between
    /// trees just like cbonsai's `srand(time(NULL))`.
    fn freshSeed(self: *App) u64 {
        const now = std.Io.Clock.real.now(self.io);
        const ns: i96 = now.nanoseconds;
        var x: u64 = @truncate(@as(u96, @bitCast(ns)));
        const pid: u64 = @intCast(std.os.linux.getpid());
        x ^= pid *% 0x9E3779B97F4A7C15;
        x ^= self.tree_count *% 0x2545F4914F6CDD1D;
        // splitmix64 finalizer: cheap avalanche, no /dev/urandom needed.
        x ^= x >> 30;
        x *%= 0xBF58476D1CE4E5B9;
        x ^= x >> 27;
        x *%= 0x94D049BB133111EB;
        x ^= x >> 31;
        if (x == 0) x = 1;
        return x;
    }

    /// Non-TTY: one static tree as plain text, no escapes, no key waiting.
    fn runPlain(self: *App) !void {
        try self.applyLayout();
        try self.regrow(self.seed);
        self.paint(std.math.maxInt(u32));
        canvas.printPlain(&self.c, &self.out, false);
    }

    fn runInteractive(self: *App) !void {
        try self.applyLayout();
        var seed = self.seed;
        while (true) {
            try self.regrow(seed);

            if (self.cfg.live) {
                // Start with the pot and the very first stage, then replay.
                self.paint(0);
                self.commit();
                if (try self.liveGrow() == .quit) return;
            } else {
                self.paint(std.math.maxInt(u32));
                self.commit();
            }

            if (self.cfg.print_tree) return;

            if (self.cfg.infinite) {
                if (try self.holdTree()) return;
                seed = self.freshSeed();
                continue;
            }

            // Static mode: keep the tree on screen until a key arrives.
            while (true) {
                switch (self.waitKey(250 * std.time.ns_per_ms)) {
                    .quit => return,
                    .resize => {
                        try self.applyLayout();
                        try self.regrow(self.seed);
                        self.paint(std.math.maxInt(u32));
                        self.commit();
                    },
                    .key => return,
                    .none => {},
                }
            }
        }
    }

    /// Infinite mode: hold the finished tree for `--wait`, then move on.
    /// Returns true when the program should quit.
    fn holdTree(self: *App) !bool {
        const start = std.Io.Clock.awake.now(self.io).nanoseconds;
        const total: i96 = @intCast(self.cfg.wait_ns);
        while (true) {
            const now = std.Io.Clock.awake.now(self.io).nanoseconds;
            const elapsed = now - start;
            if (elapsed >= total) return false;
            const left: u64 = @intCast(@divTrunc(total - elapsed, 1));
            const chunk = @min(left, 100 * std.time.ns_per_ms);
            switch (self.waitKey(chunk)) {
                .quit => return true,
                .resize => {
                    try self.applyLayout();
                    try self.regrow(self.seed);
                    self.paint(std.math.maxInt(u32));
                    self.commit();
                },
                // In infinite mode any key quits (that is what `-S` relies on).
                .key => return true,
                .none => {},
            }
        }
    }

    const LiveOutcome = enum { done, quit };

    /// Replay the finished tree one growth stage at a time.
    fn liveGrow(self: *App) !LiveOutcome {
        var tick: u32 = 0;
        var skip_waits = false;
        while (tick < self.tree.ticks) {
            const before = self.drawn;
            self.tree.drawUntil(&self.c, &self.drawn, tick);
            if (self.drawn != before) {
                self.paintMessage();
                self.commit();
            }
            tick += 1;

            if (skip_waits) {
                if (term.quitRequested()) return .quit;
                if (term.tookResize()) try self.handleResize(tick);
                continue;
            }

            switch (self.waitKey(self.cfg.time_step_ns)) {
                .quit => return .quit,
                .resize => try self.handleResize(tick),
                .key => |key| {
                    if (self.cfg.screensaver or key == 'q' or key == 0x03) return .quit;
                    // Any other key skips the rest of the animation.
                    skip_waits = true;
                },
                .none => {},
            }
        }
        self.tree.drawUntil(&self.c, &self.drawn, std.math.maxInt(u32));
        self.paintMessage();
        self.commit();
        return .done;
    }

    /// Terminal was resized: re-derive the geometry, regenerate the tree from
    /// the same seed (growth depends on the window size, exactly like
    /// cbonsai's replay) and repaint up to the current stage.
    fn handleResize(self: *App, tick: u32) !void {
        const seed = self.seed;
        const was_full = tick >= self.tree.ticks;
        try self.applyLayout();
        try self.regrow(seed);
        self.paint(if (was_full) std.math.maxInt(u32) else tick);
        self.commit();
    }
};

// ---------------------------------------------------------------------------
// a test that runs the whole pipeline without a terminal
// ---------------------------------------------------------------------------

test "pipeline: grow, paint into a canvas, print plain text" {
    const gpa = std.testing.allocator;
    const params = tree.Params{
        .life_start = 32,
        .multiplier = 5,
        .growth_height = 20,
        .cols = 80,
    };
    var t = try tree.grow(gpa, params, 42, 40, params.growth_height - 1);
    defer t.deinit();

    var c = try canvas.Canvas.init(gpa, 24, 80);
    defer c.deinit();
    base.draw(&c, 1, 24, 20, .{ 2, 3, 10, 11 });

    var l = try message.layout(gpa, "hello bonsai", message.contentMaxWidth(80));
    defer l.deinit();
    _ = message.drawBox(&c, &l);

    var drawn: usize = 0;
    t.drawUntil(&c, &drawn, std.math.maxInt(u32));
    try std.testing.expect(drawn > 0);
    try std.testing.expectEqualSlices(u8, ":", c.at(20, 24).?.text());

    // Every cell of the grid is addressable - the canvas never delegates
    // out-of-range coordinates to the terminal.
    var y: i32 = 0;
    while (y < 24) : (y += 1) {
        var x: i32 = 0;
        while (x < 80) : (x += 1) {
            _ = c.at(y, x).?;
        }
    }
}

test {
    _ = args;
    _ = base;
    _ = canvas;
    _ = message;
    _ = term;
    _ = tree;
}
