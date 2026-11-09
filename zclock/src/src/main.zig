//! zclock —— tty-clock 2 风格的终端时钟（不链 libc，无第三方依赖）。
//!
//! 参数、几何、交互全部对齐 https://github.com/xorg62/tty-clock 的 ttyclock.c。
const std = @import("std");
const posix = std.posix;

const argsmod = @import("args.zig");
const clocktime = @import("clocktime.zig");
const font = @import("font.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const tz = @import("tz.zig");

pub const VERSION = "1.0.0";

const usage_text =
    \\usage : zclock [-iuvsScbtrahDBxn] [-C [0-7]] [-f format] [-d delay] [-a nsdelay] [-T tty]
    \\    -s            Show seconds
    \\    -S            Screensaver mode
    \\    -x            Show box
    \\    -c            Set the clock at the center of the terminal
    \\    -C [0-7]      Set the clock color
    \\    -b            Use bold colors
    \\    -t            Set the hour in 12h format
    \\    -u            Use UTC time
    \\    -T tty        Display the clock on the specified terminal
    \\    -r            Do rebound the clock
    \\    -f format     Set the date format
    \\    -n            Don't quit on keypress
    \\    -v            Show zclock version
    \\    -i            Show some info about zclock
    \\    -h            Show this page
    \\    -D            Hide date
    \\    -B            Enable blinking colon
    \\    -d delay      Set the delay between two redraws of the clock. Default 1s.
    \\    -a nsdelay    Additional delay between two redraws in nanoseconds. Default 0ns.
    \\
    \\    keys:
    \\        q / Q / Ctrl-C   quit (Ctrl-C is a signal, as in tty-clock)
    \\        arrows / hjkl    move the clock (ignored while centered)
    \\        s                toggle seconds
    \\        t                toggle 12h format
    \\        c                toggle centering
    \\        b                toggle bold
    \\        r                toggle rebound
    \\        x                toggle box
    \\        0-7              set color
    \\    extended keys:
    \\        Esc              quit
    \\        + / -            color +1 / -1
    \\        p / space        pause / resume the time
    \\
;

const info_text =
    "zclock " ++ VERSION ++ " - a tty-clock 2 compatible terminal clock\n" ++
    "original: TTY-Clock 2 (c) by Martin Duquesnoy (xorg62@gmail.com), Grey (grey@greytheory.net)\n" ++
    "this build: 19 command line options, no libc, no third-party dependencies\n";

const MAX_CANVAS_COLS: i32 = 384;
/// 画布要同时装下时钟窗和日期窗。平时是 7+2=9 行，但"时钟窗被 ncurses 的
/// mvwin 挡在屏幕外、日期窗照常挪过去"时两者会分开，行数就不再是 9；留足
/// 余量（终端再高也够用），免得把日期画丢。
const MAX_CANVAS_ROWS: i32 = 512;

const Geo = struct {
    /// 屏幕行（原版 geo.x 就是 ncurses 的 begin_y）
    x: i32 = 0,
    /// 屏幕列（原版 geo.y 就是 ncurses 的 begin_x）
    y: i32 = 0,
    /// 反弹方向
    a: i32 = 1,
    b: i32 = 1,
};

const Key = enum {
    quit,
    up,
    down,
    left,
    right,
    seconds,
    twelve,
    center,
    bold,
    rebound,
    box,
    pause,
    brighter,
    dimmer,
};

const App = struct {
    cfg: argsmod.Config,
    geo: Geo = .{},
    /// 时钟窗在屏幕上的**实际**原点。原版 geo 是逻辑坐标，窗口位置由 ncurses
    /// 的 mvwin() 决定，两者在"时钟放不下"时会分家（见 clockMove）。
    win_x: i32 = 0,
    win_y: i32 = 0,
    /// 日期窗在屏幕上的实际原点（原版 datewin：init() 里按 geo=(0,0) 建，
    /// 之后每次 clock_move() 再挪一次，挪不动就留在原地）。
    date_win_x: i32 = 6,
    date_win_y: i32 = 11,
    /// 上一帧日期文本的长度（决定日期窗宽度 = len + 2）
    date_len: i32 = 10,
    size: term.Size = term.DEFAULT_SIZE,
    out: render.Out,
    canvas: render.Canvas,
    in_fd: posix.fd_t,
    prev: ?render.Rect = null,
    paused: bool = false,
    frozen: i64 = 0,
    zone: ?tz.Zone = null,
    box_unicode: bool = true,
    quit: bool = false,
    /// stdin 到 EOF 后就只当时钟跑（原版 pselect 在没有按键输入时也是继续画）
    input_eof: bool = false,

    // ---------------------------------------------------------- 时间与内容

    fn now(self: *App) i64 {
        return if (self.paused) self.frozen else clocktime.nowUnix();
    }

    fn frameOpts(self: *App, at: i64, datebuf: []u8) render.FrameOpts {
        const info: tz.Info = if (self.cfg.utc)
            .{ .offset = 0, .isdst = false, .abbr = "UTC" }
        else if (self.zone) |zone|
            zone.infoAt(at)
        else
            tz.Info{};

        const civil = clocktime.civilFromUnix(at, info.offset);
        var date_str = clocktime.strftime(datebuf, self.cfg.format, civil, .{
            .tzname = info.abbr,
            .offset = info.offset,
            .unix = at,
            .am = "AM",
            .pm = "PM",
        });
        // 原版：datestr = strftime(format) + meridiem（只在 12 小时制下追加）
        if (self.cfg.twelve) {
            const suffix = clocktime.meridiem(civil.hour);
            if (date_str.len + suffix.len <= datebuf.len) {
                @memcpy(datebuf[date_str.len..][0..suffix.len], suffix);
                date_str = datebuf[0 .. date_str.len + suffix.len];
            }
        }
        const hour = if (self.cfg.twelve) clocktime.hour12(civil.hour) else civil.hour;

        return .{
            .color = self.cfg.color,
            .box = self.cfg.box,
            .bold = self.cfg.bold,
            .date = self.cfg.date,
            .second = self.cfg.second,
            // 原版：dotcolor 可见，除非 -B 且 time(NULL) % 2 == 0
            .colon_visible = !(self.cfg.blink and @mod(at, 2) == 0),
            .hour = clocktime.twoDigits(hour),
            .minute = clocktime.twoDigits(civil.minute),
            .second_digits = clocktime.twoDigits(civil.second),
            .date_str = if (self.cfg.date) date_str else "",
            .box_unicode = self.box_unicode,
        };
    }

    // -------------------------------------------------------------- 绘制一帧

    fn drawFrame(self: *App) void {
        var datebuf: [320]u8 = undefined;
        const at = self.now();
        var opts = self.frameOpts(at, &datebuf);
        self.date_len = @intCast(opts.date_str.len);
        self.placeDate(&opts);
        const r = render.rect(opts, self.win_x, self.win_y);
        if (self.prev) |p| {
            if (!p.eql(r)) render.eraseRect(&self.out, p, self.size.cols, self.size.rows);
        }
        self.canvas.begin(r);
        render.draw(&self.canvas, opts, self.win_x, self.win_y);
        render.emit(&self.out, &self.canvas, self.size.cols, self.size.rows);
        self.prev = r;
        self.out.flush();
    }

    /// 日期窗自己的位置（原版 datewin 是独立窗口，文字在窗口内第 1 行第 1 列，
    /// 也就是窗口原点往右下各一格）。
    fn placeDate(self: *App, o: *render.FrameOpts) void {
        if (!self.cfg.date) return;
        o.date_row = self.date_win_x + 1;
        o.date_col = self.date_win_y + 1;
    }

    /// 原版 init()：日期窗在 geo=(0,0) 处创建（行 6、列 w/2-len/2-1），
    /// 之后才由 set_center() 挪走。
    fn dateWindowToStart(self: *App) void {
        self.date_win_x = render.FRAME_HEIGHT - 1;
        self.date_win_y = @divTrunc(render.frameWidth(self.cfg.second), 2) -
            @divTrunc(self.date_len, 2) - 1;
        if (self.date_win_x < 0) self.date_win_x = 0;
        if (self.date_win_y < 0) self.date_win_y = 0;
    }

    /// 非 tty：一次纯文本打印，绝不发转义序列。
    fn printOnce(self: *App) void {
        var datebuf: [320]u8 = undefined;
        const at = clocktime.nowUnix();
        var o = self.frameOpts(at, &datebuf);
        self.date_len = @intCast(o.date_str.len);
        self.dateWindowToStart();
        self.placeDate(&o);
        const r = render.rect(o, self.win_x, self.win_y);
        self.canvas.begin(r);
        render.draw(&self.canvas, o, self.win_x, self.win_y);
        render.emitPlain(&self.out, &self.canvas, '#');
        self.out.flush();
    }

    // ---------------------------------------------------------------- 按键

    /// 原版 `clock_move(x, y, w, h)`：参数在 `mvwin(win, (geo.x = x), (geo.y = y))`
    /// 里先被写进 geo，然后 ncurses 才去挪窗口。ncurses 的 `mvwin()` 不会把窗口
    /// 挪到屏幕外（负坐标，或者窗口会伸出右/下边界时返回 ERR、位置不变），而
    /// tty-clock 从不检查返回值 —— 于是"居中/移动"只是 geo 前进了，窗口留在原处。
    /// 照抄这一点，40x12 这种放不下 54 列时钟的终端才和原版画得一模一样。
    fn clockMove(self: *App, x: i32, y: i32) void {
        self.geo.x = x;
        self.geo.y = y;
        // 原版两次 mvwin 是独立的：时钟窗挪不动，日期窗照样挪
        self.moveDateWindow();

        const w = render.frameWidth(self.cfg.second);
        if (x < 0 or y < 0) return;
        if (x + render.FRAME_HEIGHT > self.size.rows) return;
        if (y + w > self.size.cols) return;
        self.win_x = x;
        self.win_y = y;
    }

    /// 原版 clock_move() 里给日期窗的那次 `mvwin()`：坐标来自 geo（不是时钟窗
    /// 的实际位置），窗口是 DATEWINH × (len+2)，同样挪不动就留在原处。
    fn moveDateWindow(self: *App) void {
        if (!self.cfg.date) return;
        const w = render.frameWidth(self.cfg.second);
        const len = self.date_len;
        const x = self.geo.x + render.FRAME_HEIGHT - 1;
        const y = self.geo.y + @divTrunc(w, 2) - @divTrunc(len, 2) - 1;
        if (x < 0 or y < 0) return;
        if (x + render.DATEWINH > self.size.rows) return;
        if (y + len + 2 > self.size.cols) return;
        self.date_win_x = x;
        self.date_win_y = y;
    }

    fn moveUp(self: *App) void {
        if (self.geo.x >= 1 and !self.cfg.center) self.clockMove(self.geo.x - 1, self.geo.y);
    }

    fn moveDown(self: *App) void {
        const limit = self.size.rows - render.FRAME_HEIGHT - render.DATEWINH;
        if (self.geo.x <= limit and !self.cfg.center) self.clockMove(self.geo.x + 1, self.geo.y);
    }

    fn moveLeft(self: *App) void {
        if (self.geo.y >= 1 and !self.cfg.center) self.clockMove(self.geo.x, self.geo.y - 1);
    }

    fn moveRight(self: *App) void {
        const limit = self.size.cols - render.frameWidth(self.cfg.second) - 1;
        if (self.geo.y <= limit and !self.cfg.center) self.clockMove(self.geo.x, self.geo.y + 1);
    }

    fn setCenter(self: *App) void {
        // 原版 set_center()：行 = LINES/2 - h/2，列 = COLS/2 - w/2，其中
        // h 恒为 7、w 恒为 35 或 54。-x 的边框、日期框和 -t 的 " [AM]"
        // 只改画进去的内容，不改 w —— 它们不参与居中计算。
        self.clockMove(
            @divTrunc(self.size.rows, 2) - @divTrunc(render.FRAME_HEIGHT, 2),
            @divTrunc(self.size.cols, 2) - @divTrunc(render.frameWidth(self.cfg.second), 2),
        );
    }

    /// 原版 set_center(true)：居中会顺手关掉 rebound。
    fn centerNow(self: *App) void {
        self.cfg.rebound = false;
        self.setCenter();
    }

    fn toggleCenter(self: *App) void {
        self.cfg.center = !self.cfg.center;
        if (self.cfg.center) self.centerNow();
    }

    /// 原版 set_second()：切换秒后如果右边越界就整体左移。
    /// 原版 `for(y_adj = 0; geo.y - y_adj > COLS - w - 1; ++y_adj);` 在终端比时钟
    /// 还窄时会死循环，这里加了"最多挪到第 0 列"的下界，避免挂住。
    fn toggleSeconds(self: *App) void {
        self.cfg.second = !self.cfg.second;
        const new_w = render.frameWidth(self.cfg.second);
        var y_adj: i32 = 0;
        while (self.geo.y - y_adj > self.size.cols - new_w - 1 and
            self.geo.y - y_adj > 0) : (y_adj += 1)
        {}
        self.clockMove(self.geo.x, self.geo.y - y_adj);
        if (self.cfg.center) self.setCenter();
    }

    fn reboundStep(self: *App) void {
        if (!self.cfg.rebound) return;
        if (self.geo.x < 1) self.geo.a = 1;
        if (self.geo.x > self.size.rows - render.FRAME_HEIGHT - render.DATEWINH) self.geo.a = -1;
        if (self.geo.y < 1) self.geo.b = 1;
        if (self.geo.y > self.size.cols - render.frameWidth(self.cfg.second) - 1) self.geo.b = -1;
        self.clockMove(self.geo.x + self.geo.a, self.geo.y + self.geo.b);
    }

    fn press(self: *App, key: Key) void {
        switch (key) {
            .quit => {
                if (!self.cfg.noquit) self.quit = true;
            },
            .up => self.moveUp(),
            .down => self.moveDown(),
            .left => self.moveLeft(),
            .right => self.moveRight(),
            .seconds => self.toggleSeconds(),
            .twelve => self.cfg.twelve = !self.cfg.twelve,
            .center => self.toggleCenter(),
            .bold => self.cfg.bold = !self.cfg.bold,
            .rebound => {
                self.cfg.rebound = !self.cfg.rebound;
                if (self.cfg.rebound and self.cfg.center) self.cfg.center = false;
            },
            .box => self.cfg.box = !self.cfg.box,
            .pause => {
                self.paused = !self.paused;
                if (self.paused) self.frozen = clocktime.nowUnix();
            },
            // "+/-" 是色彩索引上的"亮度"，原版只有 0-7 直接选色
            .brighter => self.cfg.color = @intCast((@as(u16, self.cfg.color) + 1) % 8),
            .dimmer => self.cfg.color = @intCast((@as(u16, self.cfg.color) + 7) % 8),
        }
    }

    fn handleInput(self: *App, bytes: []const u8) void {
        if (self.cfg.screensaver) {
            // 原版：屏保模式下任意键退出；-n 时只保留 0-7 换色
            for (bytes) |b| {
                if (!self.cfg.noquit) {
                    self.quit = true;
                    return;
                }
                if (b >= '0' and b <= '7') self.cfg.color = b - '0';
            }
            return;
        }

        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == 0x1b) {
                if (i + 1 < bytes.len and (bytes[i + 1] == '[' or bytes[i + 1] == 'O')) {
                    var j = i + 2;
                    while (j < bytes.len and !(bytes[j] >= 0x40 and bytes[j] <= 0x7e)) : (j += 1) {}
                    if (j >= bytes.len) return; // 转义序列不完整，丢弃
                    switch (bytes[j]) {
                        'A' => self.press(.up),
                        'B' => self.press(.down),
                        'C' => self.press(.right),
                        'D' => self.press(.left),
                        else => {},
                    }
                    i = j + 1;
                    continue;
                }
                // 单个 Esc：扩展成"退出"（原版没有这个绑定）
                self.press(.quit);
                i += 1;
                continue;
            }
            switch (b) {
                0x03 => self.press(.quit), // ISIG 关掉时也能退出
                'q', 'Q' => self.press(.quit),
                'k', 'K' => self.press(.up),
                'j', 'J' => self.press(.down),
                'h', 'H' => self.press(.left),
                'l', 'L' => self.press(.right),
                's', 'S' => self.press(.seconds),
                't', 'T' => self.press(.twelve),
                'c', 'C' => self.press(.center),
                'b', 'B' => self.press(.bold),
                'r', 'R' => self.press(.rebound),
                'x', 'X' => self.press(.box),
                'p', 'P', ' ' => self.press(.pause),
                '+', '=' => self.press(.brighter),
                '-', '_' => self.press(.dimmer),
                '0'...'7' => self.cfg.color = b - '0',
                else => {},
            }
            i += 1;
        }
    }

    /// 画一帧 → 等输入（原版 key_event 里的 pselect(delay, nsdelay)）。
    fn step(self: *App) void {
        if (term.takeResize()) {
            self.size = term.getSize(self.out.fd);
            if (self.cfg.center) self.centerNow();
            self.out.put(term.CLEAR_SCREEN);
            self.prev = null;
        }
        self.reboundStep();
        self.drawFrame();

        const zero = posix.timespec{ .sec = 0, .nsec = 0 };
        const delay = posix.timespec{
            .sec = @intCast(self.cfg.delay),
            .nsec = @intCast(self.cfg.nsdelay),
        };
        if (self.input_eof) {
            term.sleepFor(&delay);
            return;
        }
        if (!term.waitReadable(self.in_fd, &zero)) {
            if (!term.waitReadable(self.in_fd, &delay)) return;
        }
        var buf: [64]u8 = undefined;
        switch (term.readSome(self.in_fd, &buf)) {
            .data => |bytes| self.handleInput(bytes),
            .eof => {
                // 输入没了：之后每帧就只按 delay 节流，保持原来的节奏
                self.input_eof = true;
                term.sleepFor(&delay);
            },
            .retry => {},
        }
    }
};

fn stderrPrint(comptime fmt: []const u8, a: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, a) catch return;
    term.writeAll(term.STDERR, s) catch {};
}

/// -T：原版用 fopen(path,"r+") + S_ISCHR 检查；这里用 open(RDWR) + 是否能 tcgetattr。
fn openTty(alloc: std.mem.Allocator, path: []const u8) posix.fd_t {
    const zpath = alloc.allocSentinel(u8, path.len, 0) catch {
        stderrPrint("zclock: error: out of memory.\n", .{});
        std.process.exit(1);
    };
    @memcpy(zpath[0..path.len], path);
    switch (term.openRdwr(zpath)) {
        .err => |e| {
            stderrPrint("zclock: error: '{s}' couldn't be opened: {s}.\n", .{ path, @tagName(e) });
            std.process.exit(1);
        },
        .fd => |fd| {
            if (!term.isTty(fd)) {
                stderrPrint("zclock: error: '{s}' doesn't appear to be a character device.\n", .{path});
                std.process.exit(1);
            }
            return fd;
        },
    }
}

fn detectUnicodeBox(environ: *std.process.Environ.Map) bool {
    const keys = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (keys) |k| {
        if (environ.get(k)) |v| {
            if (v.len == 0) continue;
            if (containsIgnoreCase(v, "utf-8") or containsIgnoreCase(v, "utf8")) return true;
            return false;
        }
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var argv_buf: std.ArrayList([]const u8) = .empty;
    var it = init.minimal.args.iterate();
    _ = it.next(); // 跳过 argv[0]
    while (it.next()) |a| try argv_buf.append(alloc, a);
    const argv = argv_buf.items;

    const parsed = argsmod.parse(argv);
    switch (parsed.action) {
        .help => {
            term.writeAll(term.STDOUT, usage_text) catch {};
            return;
        },
        .version => {
            term.writeAll(term.STDOUT, "zclock " ++ VERSION ++ " (tty-clock 2 compatible)\n") catch {};
            return;
        },
        .info => {
            term.writeAll(term.STDOUT, info_text) catch {};
            return;
        },
        .usage_error => {
            // 原版 getopt 遇到未知选项也是打印 usage 后 EXIT_SUCCESS
            term.writeAll(term.STDOUT, usage_text) catch {};
            return;
        },
        .run => {},
    }

    var cfg = parsed.cfg;
    // -C 颜色只在 0-7 有效
    if (cfg.color > 7) cfg.color = 2;

    var out_fd: posix.fd_t = term.STDOUT;
    var in_fd: posix.fd_t = term.STDIN;
    var own_tty: ?posix.fd_t = null;
    if (cfg.tty) |path| {
        const fd = openTty(alloc, path);
        own_tty = fd;
        out_fd = fd;
        in_fd = fd;
    }
    defer {
        if (own_tty) |fd| _ = std.os.linux.close(fd);
    }

    var out_buf: [64 * 1024]u8 = undefined;
    const canvas = try render.Canvas.init(alloc, MAX_CANVAS_COLS, MAX_CANVAS_ROWS);
    var app = App{
        .cfg = cfg,
        .out = .{ .fd = out_fd, .buf = &out_buf },
        .canvas = canvas,
        .in_fd = in_fd,
        .box_unicode = detectUnicodeBox(init.environ_map),
    };

    if (!cfg.utc) app.zone = tz.loadLocal(alloc, init.environ_map.get("TZ"));

    // -------- 非 tty：单次纯文本打印后退出（沙箱/管道友好） --------
    // ZCLOCK_FORCE_TTY=1 是给没有 pty 的沙箱做交互自测用的调试开关，
    // 不是 tty-clock 的命令行功能，正常使用不需要它。
    const force_tty = init.environ_map.get("ZCLOCK_FORCE_TTY") != null;
    if (!force_tty and !term.isTty(out_fd)) {
        app.printOnce();
        return;
    }

    // -------- 交互模式 --------
    app.size = term.getSize(out_fd);
    // 原版 init(): 先按 geo=(0,0) 建日期窗（宽度取决于日期串长度），再 set_center()
    var probe_buf: [320]u8 = undefined;
    app.date_len = @intCast(app.frameOpts(clocktime.nowUnix(), &probe_buf).date_str.len);
    app.dateWindowToStart();
    if (cfg.center) app.centerNow(); // -c 和 -r 同时给时居中优先（原版 init() 的行为）

    var cbreak = term.Cbreak.enable(in_fd) catch null;
    term.installSignalHandlers();

    term.writeAll(out_fd, term.ALT_ON ++ term.CURSOR_HIDE) catch {};
    defer {
        term.writeAll(out_fd, term.SGR_RESET ++ term.CURSOR_SHOW ++ term.ALT_OFF) catch {};
        if (cbreak) |*c| c.restore(in_fd);
    }

    while (!app.quit and !term.quitRequested()) {
        app.step();
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "frameOpts applies 24h and UTC without a zone" {
    var buf: [320]u8 = undefined;
    var app = App{
        .cfg = .{ .utc = true, .format = "%F %T" },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 16, 9),
        .in_fd = -1,
    };
    defer app.canvas.deinit();

    // 2026-11-08T00:00:00Z
    const o = app.frameOpts(1794096000, &buf);
    try testing.expectEqualStrings("2026-11-08 00:00:00", o.date_str);
    try testing.expectEqual([2]u8{ 0, 0 }, o.hour);
    try testing.expectEqual([2]u8{ 0, 0 }, o.second_digits);
    try testing.expect(!o.second);
}

test "frameOpts handles 12h + meridiem + positive UTC offset" {
    var buf: [320]u8 = undefined;
    var app = App{
        .cfg = .{ .utc = true, .twelve = true, .second = true, .format = "%F %T" },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 16, 9),
        .in_fd = -1,
    };
    defer app.canvas.deinit();
    // UTC 13:07:09 → 12 小时制 01:07:09 PM（date 串带 [PM]）
    const o = app.frameOpts(1794096000 + 13 * 3600 + 7 * 60 + 9, &buf);
    try testing.expectEqual([2]u8{ 0, 1 }, o.hour);
    try testing.expectEqual([2]u8{ 0, 7 }, o.minute);
    try testing.expectEqual([2]u8{ 0, 9 }, o.second_digits);
    try testing.expectEqualStrings("2026-11-08 13:07:09 [PM]", o.date_str);
    try testing.expect(o.second);
}

test "colon blink follows time(NULL) % 2 like the original" {
    var buf: [320]u8 = undefined;
    var app = App{
        .cfg = .{ .utc = true, .blink = true },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 16, 9),
        .in_fd = -1,
    };
    defer app.canvas.deinit();
    try testing.expect(!app.frameOpts(100, &buf).colon_visible);
    try testing.expect(app.frameOpts(101, &buf).colon_visible);
}

test "centering and movement bounds mirror tty-clock" {
    var buf: [64]u8 = undefined;
    var app = App{
        .cfg = .{},
        .size = .{ .cols = 80, .rows = 24 },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 16, 9),
        .in_fd = -1,
    };
    defer app.canvas.deinit();

    app.toggleCenter();
    try testing.expect(app.cfg.center);
    try testing.expectEqual(@as(i32, 12 - 3), app.geo.x); // 24/2 - 7/2
    try testing.expectEqual(@as(i32, 40 - 17), app.geo.y); // 80/2 - 35/2

    // 居中时方向键无效
    app.moveUp();
    try testing.expectEqual(@as(i32, 9), app.geo.x);

    app.toggleCenter();
    try testing.expect(!app.cfg.center);
    app.moveUp();
    try testing.expectEqual(@as(i32, 8), app.geo.x);

    // 下边界：原版判断是 `geo.x <= LINES - h - DATEWINH`（14），
    // 也就是允许越过一格到 15，这里照抄这个 off-by-one
    var i: usize = 0;
    while (i < 40) : (i += 1) app.moveDown();
    try testing.expectEqual(@as(i32, 15), app.geo.x);
    app.moveDown();
    try testing.expectEqual(@as(i32, 15), app.geo.x);

    // 秒数切换会把过宽的时钟左移
    app.geo.y = 70;
    app.toggleSeconds();
    try testing.expect(app.cfg.second);
    try testing.expect(app.geo.y <= 80 - 54 - 1);

    // 终端比时钟还窄时不能死循环（原版这里会挂住）
    app.size = .{ .cols = 30, .rows = 10 };
    app.geo.y = 5;
    app.toggleSeconds();
    try testing.expect(app.geo.y >= 0);
}

test "ncurses mvwin(): a window that would hang off the screen stays put" {
    var buf: [64]u8 = undefined;
    var app = App{
        .cfg = .{ .center = true, .second = true },
        .size = .{ .cols = 40, .rows = 12 },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 64, 32),
        .in_fd = -1,
        .date_len = 10,
    };
    defer app.canvas.deinit();

    app.dateWindowToStart();
    app.centerNow();
    // geo 记的是 set_center() 算出来的值：行 12/2-7/2、列 40/2-54/2
    try testing.expectEqual(@as(i32, 3), app.geo.x);
    try testing.expectEqual(@as(i32, -7), app.geo.y);
    // 54 列的窗口在 40 列的终端里放不下：ncurses 的 mvwin() 返回 ERR，窗口留在
    // (0,0)，和原版 40x12 -c -s 的画法一致（屏幕上一整块贴左上角）
    try testing.expectEqual(@as(i32, 0), app.win_x);
    try testing.expectEqual(@as(i32, 0), app.win_y);
    // 日期窗是另一次 mvwin()：它放得下，于是照常挪到时钟下方
    try testing.expectEqual(@as(i32, 9), app.date_win_x);
    try testing.expectEqual(@as(i32, 14), app.date_win_y);
}

test "centred windows both move when they fit" {
    var buf: [64]u8 = undefined;
    var app = App{
        .cfg = .{ .center = true },
        .size = .{ .cols = 80, .rows = 24 },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 64, 32),
        .in_fd = -1,
        .date_len = 10,
    };
    defer app.canvas.deinit();

    app.dateWindowToStart();
    app.centerNow();
    try testing.expectEqual(@as(i32, 9), app.geo.x); // 24/2 - 7/2
    try testing.expectEqual(@as(i32, 23), app.geo.y); // 80/2 - 35/2
    try testing.expectEqual(@as(i32, 9), app.win_x);
    try testing.expectEqual(@as(i32, 23), app.win_y);
    // 日期窗：行 geo.x+7-1、列 geo.y+35/2-10/2-1
    try testing.expectEqual(@as(i32, 15), app.date_win_x);
    try testing.expectEqual(@as(i32, 34), app.date_win_y);

    // 时钟窗挪到放不下的位置时窗口不动，geo 照旧前进（原版不看 mvwin 返回值）
    app.clockMove(-1, 23);
    try testing.expectEqual(@as(i32, -1), app.geo.x);
    try testing.expectEqual(@as(i32, 9), app.win_x);
}

test "the date window keeps its place when it does not fit below" {
    var buf: [64]u8 = undefined;
    var app = App{
        .cfg = .{ .center = true },
        .size = .{ .cols = 80, .rows = 8 },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 64, 32),
        .in_fd = -1,
        .date_len = 10,
    };
    defer app.canvas.deinit();

    app.dateWindowToStart();
    try testing.expectEqual(@as(i32, 6), app.date_win_x);
    try testing.expectEqual(@as(i32, 11), app.date_win_y);
    app.centerNow();
    // 时钟窗本身放得下（行 1..7）……
    try testing.expectEqual(@as(i32, 1), app.win_x);
    try testing.expectEqual(@as(i32, 23), app.win_y);
    // ……但日期窗要落在第 7..9 行，超出 8 行终端：mvwin() 失败，留在 init() 位置
    try testing.expectEqual(@as(i32, 6), app.date_win_x);
    try testing.expectEqual(@as(i32, 11), app.date_win_y);
}

test "center beats rebound (-c -r) like init() does" {
    var buf: [64]u8 = undefined;
    var app = App{
        .cfg = .{ .center = true, .rebound = true },
        .size = .{ .cols = 80, .rows = 24 },
        .out = .{ .fd = -1, .buf = &buf },
        .canvas = try render.Canvas.init(testing.allocator, 16, 9),
        .in_fd = -1,
    };
    defer app.canvas.deinit();
    app.centerNow();
    try testing.expect(!app.cfg.rebound);
    try testing.expectEqual(@as(i32, 9), app.geo.x);
}

test "unicode box detection follows the locale" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("LANG", "zh_CN.UTF-8");
    try testing.expect(detectUnicodeBox(&map));
    var map2 = std.process.Environ.Map.init(testing.allocator);
    defer map2.deinit();
    try map2.put("LC_ALL", "C");
    try testing.expect(!detectUnicodeBox(&map2));
}

test "digit font module is wired in" {
    try testing.expectEqual(@as(usize, 5), font.cell_rows);
    try testing.expectEqual(@as(usize, 6), font.cell_cols);
}
