//! zmatrix —— 终端字符雨，cmatrix 风格。
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const charset = @import("charset.zig");
const color = @import("color.zig");
const matrix = @import("matrix.zig");
const options = @import("options.zig");
const term = @import("term.zig");

pub const VERSION = "1.1.0";

/// `-u 0` 的帧预算。
///
/// cmatrix 在 `-u 0`（`napms(0)`）时并没有真的「无限快」：curses 每帧要算一遍
/// 1920 个格子的 diff 再刷新，固定开销把它压在几千 fps。zmatrix 的帧差分把每帧
/// 降到几十微秒，不设下限就会以 ~3 万 fps 往终端灌转义（实测 28 MB/s，cmatrix
/// 只有 3~7 MB/s）—— 画面完全一样，白烧 CPU 和带宽，也正是「卡顿」的来源。
/// 这里给 `-u 0` 一个 80µs 的帧预算（含内核定时器松弛后实测 ≈7200 fps，仍比
/// cmatrix 快），输出量就回到
/// 和 cmatrix 同一个量级；`-u 1..10` 不受影响，仍是 `u*10 ms`。
const zero_delay_budget_ns: u64 = 80_000;

const help_text =
    \\ Usage: zmatrix -[abBcfhknmorsxV] [-u delay] [-C color] [-l chars] [-M message]
    \\
    \\ -a: Asynchronous scroll
    \\ -b: Bold characters on
    \\ -B: All bold characters (overrides -b)
    \\ -c: Use Japanese characters as seen in the original matrix. Requires appropriate fonts
    \\ -f: Force the linux $TERM type to be on (accepted, no effect here)
    \\ -o: Use old-style scrolling
    \\ -h: Print usage and exit
    \\ -n: No bold characters (overrides -b and -B, default)
    \\ -s: "Screensaver" mode, exits on first keystroke
    \\ -x: X window mode, use if your xterm is using mtx.pcf
    \\ -V: Print version information and exit
    \\ -M [message]: Prints your message in the center of the screen.
    \\ -u delay (0 - 10, default 4): Screen update delay
    \\ -C [color]: Use this color for matrix (default green)
    \\ -r: rainbow mode
    \\ -m: lambda mode
    \\ -k: Characters change while scrolling. (Works without -o opt.)
    \\
    \\ Extended options:
    \\ -l chars: Use the given characters as the character set
    \\ --fade: 256-color fading trail (off by default)
    \\
    \\ Keys while running:
    \\   q, Q, Ctrl-C   quit
    \\   0-9            set update delay (0 = as fast as possible)
    \\   !@#$%^&        red green yellow blue magenta cyan white
    \\   a              toggle asynchronous scrolling
    \\   r              toggle rainbow
    \\   b, B, n        bold head and dither / all bold / bold head only
    \\   m              toggle lambda mode
    \\   c              cycle character set (ASCII -> katakana -> custom)
    \\   k              toggle "characters change while scrolling"
    \\   p              pause / resume
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv_list: std.ArrayList([]const u8) = .empty;
    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // 跳过 argv[0]
    while (args_it.next()) |a| try argv_list.append(gpa, a);
    defer argv_list.deinit(gpa);

    const parsed = options.parse(gpa, argv_list.items) catch |err| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "zmatrix: bad command line ({s}); try 'zmatrix -h' for usage\n",
            .{@errorName(err)},
        ) catch "zmatrix: bad command line; try 'zmatrix -h' for usage\n";
        term.writeAll(term.STDERR, msg) catch {};
        std.process.exit(1);
    };

    if (parsed.help) {
        term.writeAll(term.STDOUT, help_text) catch {};
        return;
    }
    if (parsed.version) {
        term.writeAll(term.STDOUT, " zmatrix version " ++ VERSION ++ "\n") catch {};
        return;
    }

    const cfg = parsed.cfg;
    defer if (cfg.custom_chars.len > 0) gpa.free(cfg.custom_chars);
    defer if (cfg.message_chars.len > 0) gpa.free(cfg.message_chars);
    defer if (cfg.message) |msg| gpa.free(msg);
    // 色深只影响 --fade 的色阶；默认路径永远是 cmatrix 的 8 色。
    const depth = color.detectDepth(init.environ_map.get("TERM"));

    term.installSignalHandlers();

    // ZMATRIX_FORCE_TTY 仅用于在没有真实 pty 的环境（CI/沙箱）里验证
    // alternate screen / raw mode / 退出恢复这几条路径。
    const force_tty = if (init.environ_map.get("ZMATRIX_FORCE_TTY")) |v|
        (v.len > 0 and !std.mem.eql(u8, v, "0"))
    else
        false;
    const out_tty = term.isTty(term.STDOUT) or force_tty;
    const in_tty = term.isTty(term.STDIN) or force_tty;

    var raw_mode: ?term.RawMode = null;
    if (in_tty) raw_mode = term.RawMode.enable() catch null;
    defer if (raw_mode) |*r| r.restore();

    // 光标无条件隐藏：管道模式（`zmatrix | zlolcat`）下输出最后还是落在终端上，
    // 不隐藏的话那个闪烁的方块会一直悬在雨里。alt-screen 仍只在直接输出到 tty 时用。
    if (out_tty) term.writeAll(term.STDOUT, term.ALT_ON ++ term.CLEAR) catch {};
    term.writeAll(term.STDOUT, term.CURSOR_HIDE) catch {};
    defer {
        term.writeAll(term.STDOUT, term.CURSOR_SHOW ++ term.RESET) catch {};
        if (out_tty) term.writeAll(term.STDOUT, term.ALT_OFF) catch {};
    }

    // 尺寸顺序：ioctl(stdout) → ioctl(/dev/tty) → $COLUMNS/$LINES → 80x24。
    // stdout 是管道时（`zmatrix | zlolcat`）第 2 步保证仍按真实终端尺寸出雨。
    var size = term.detectSize(
        init.environ_map.get("COLUMNS"),
        init.environ_map.get("LINES"),
    );
    // ZMATRIX_SEED 固定随机种子，让两次运行的帧可以逐格对比（测试/回归用）。
    const seed = if (init.environ_map.get("ZMATRIX_SEED")) |v|
        std.fmt.parseInt(u64, v, 10) catch seedNow()
    else
        seedNow();
    var m = try matrix.Matrix.init(gpa, size.cols, size.rows, cfg, seed);
    defer m.deinit();

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);

    var paused = false;
    var stdin_open = true;
    var dirty = false;

    while (!term.quitRequested()) {
        const frame_start = term.nowNs();
        if (term.takeResize()) {
            // 原版 resize_screen()：ttyname(0) 上 ioctl 重新取尺寸。
            // 这里用同一套回退链，管道模式下也能跟上窗口变化。
            size = term.detectSize(
                init.environ_map.get("COLUMNS"),
                init.environ_map.get("LINES"),
            );
            m.resize(size.cols, size.rows) catch {};
            // 原版 resize_screen() 也会 clear() + refresh()
            term.writeAll(term.STDOUT, term.CLEAR) catch {};
        }

        var quit = false;

        if (stdin_open) {
            var fds = [_]posix.pollfd{.{
                .fd = term.STDIN,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            // 原版：timeout(0) 的 wgetch，非阻塞取键；睡眠放到帧末的 napms()。
            const nready = posix.poll(&fds, 0) catch 0;
            if (nready > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
                var kbuf: [64]u8 = undefined;
                switch (term.readSome(term.STDIN, &kbuf)) {
                    .eof => stdin_open = false,
                    .retry => {},
                    .data => |bytes| {
                        for (bytes) |b| {
                            dirty = true;
                            if (m.cfg.screensaver) {
                                quit = true;
                                break;
                            }
                            switch (b) {
                                'q', 'Q', 0x03 => {
                                    quit = true;
                                    break;
                                },
                                'a' => m.cfg.async_scroll = !m.cfg.async_scroll,
                                '0'...'9' => m.cfg.delay = b - '0',
                                // 原版：换色会同时关掉彩虹
                                '!' => {
                                    m.cfg.color = .red;
                                    m.cfg.rainbow = false;
                                },
                                '@' => {
                                    m.cfg.color = .green;
                                    m.cfg.rainbow = false;
                                },
                                '#' => {
                                    m.cfg.color = .yellow;
                                    m.cfg.rainbow = false;
                                },
                                '$' => {
                                    m.cfg.color = .blue;
                                    m.cfg.rainbow = false;
                                },
                                '%' => {
                                    m.cfg.color = .magenta;
                                    m.cfg.rainbow = false;
                                },
                                '^' => {
                                    m.cfg.color = .cyan;
                                    m.cfg.rainbow = false;
                                },
                                '&' => {
                                    m.cfg.color = .white;
                                    m.cfg.rainbow = false;
                                },
                                'r' => m.cfg.rainbow = !m.cfg.rainbow,
                                'b' => if (m.cfg.bold != .all) {
                                    m.cfg.bold = .dither;
                                },
                                'B' => m.cfg.bold = .all,
                                'n', 'N' => m.cfg.bold = .head,
                                'm' => m.cfg.lambda = !m.cfg.lambda,
                                'c' => m.cfg.charset = nextCharset(m.cfg.charset, m.cfg.custom_chars.len),
                                'k' => m.cfg.mutate = !m.cfg.mutate,
                                'p', 'P' => paused = !paused,
                                else => {},
                            }
                        }
                    },
                }
            } else if (nready > 0 and
                (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0)
            {
                // stdin 已经关闭（例如 `0<&-`）：停止轮询，否则 poll 会立刻返回变成忙等
                stdin_open = false;
            }
        }

        if (quit or term.quitRequested()) break;

        if (!paused) {
            m.step();
            m.render(depth, &frame) catch break;
            term.writeAll(term.STDOUT, frame.items) catch break;
            dirty = false;
        } else if (dirty) {
            // 暂停时按键（换色/粗体/彩虹）也要立刻反映到屏幕上，只是不推进
            m.render(depth, &frame) catch break;
            term.writeAll(term.STDOUT, frame.items) catch break;
            dirty = false;
        }

        // 原版主循环末尾：napms(update * 10)，挪到画完之后才是同一节奏。
        if (m.cfg.delay == 0) {
            const spent = term.nowNs() -% frame_start;
            if (spent < zero_delay_budget_ns) term.sleepNs(zero_delay_budget_ns - spent);
        } else {
            term.sleepMs(@as(u32, m.cfg.delay) * 10);
        }
    }
}

fn nextCharset(current: charset.Kind, custom_len: usize) charset.Kind {
    const has_custom = custom_len > 0;
    return switch (current) {
        .ascii => .katakana,
        .katakana => if (has_custom) .custom else .ascii,
        .custom => .ascii,
    };
}

fn seedNow() u64 {
    var ts: posix.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const sec: u64 = @intCast(@max(ts.sec, 0));
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    const pid: u64 = @intCast(linux.getpid());
    return (sec *% 1_000_000_007) ^ (nsec *% 2_654_435_761) ^ (pid << 32);
}

// 让 `zig build test` 找到各子模块里的测试
test {
    _ = @import("charset.zig");
    _ = @import("color.zig");
    _ = @import("options.zig");
    _ = @import("matrix.zig");
    _ = @import("term.zig");
}
