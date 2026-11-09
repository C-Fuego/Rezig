//! 终端控制：raw 模式、alternate screen、光标、窗口尺寸、信号。
//! 直接用 std.os.linux 的系统调用，绕开 0.17 的 std.Io 体系。
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const STDOUT = posix.STDOUT_FILENO;
pub const STDIN = posix.STDIN_FILENO;
pub const STDERR = posix.STDERR_FILENO;

pub const HOME = "\x1b[H";
pub const CLEAR = "\x1b[2J\x1b[H";
pub const ALT_ON = "\x1b[?1049h";
pub const ALT_OFF = "\x1b[?1049l";
pub const CURSOR_HIDE = "\x1b[?25l";
pub const CURSOR_SHOW = "\x1b[?25h";
pub const RESET = "\x1b[0m";

pub const Size = struct { cols: u16, rows: u16 };
pub const DEFAULT_SIZE = Size{ .cols = 80, .rows = 24 };

/// 控制终端。stdout 是管道时（`zmatrix | zlolcat`）只能从这里问到真实尺寸。
pub const TTY_PATH = "/dev/tty";

const TIOCGWINSZ: u32 = 0x5413;
const TCGETS: u32 = 0x5401;

fn linuxErrno(rc: usize) ?linux.E {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return null;
    return @enumFromInt(@as(u16, @intCast(-signed)));
}

/// 写全部字节到 fd；EINTR/零进展时重试。
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (linuxErrno(rc)) |e| {
            switch (e) {
                .INTR, .AGAIN => continue,
                else => return error.WriteFailed,
            }
        }
        if (rc == 0) return error.WriteFailed;
        off += rc;
    }
}

pub const ReadResult = union(enum) {
    data: []const u8,
    eof,
    retry,
};

/// 从 fd 读一次（非阻塞/管道都安全）。
pub fn readSome(fd: posix.fd_t, buf: []u8) ReadResult {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (linuxErrno(rc)) |e| {
        switch (e) {
            .INTR, .AGAIN => return .retry,
            else => return .eof,
        }
    }
    if (rc == 0) return .eof;
    return .{ .data = buf[0..rc] };
}

/// ioctl(TIOCGWINSZ)；只有拿不到或维度为 0 时才返回 null，交由调用者继续回退。
pub fn querySize(fd: posix.fd_t) ?Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = linux.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (linuxErrno(rc) != null) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

pub fn getSize(fd: posix.fd_t) Size {
    return querySize(fd) orelse DEFAULT_SIZE;
}

/// 打开控制终端；没有控制终端（daemon / 容器）时返回 null。
pub fn openTty() ?posix.fd_t {
    const rc = linux.open(TTY_PATH, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linuxErrno(rc)) |_| return null;
    return @intCast(rc);
}

fn parseDim(text: ?[]const u8) ?u16 {
    const raw = text orelse return null;
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0) return null;
    const v = std.fmt.parseInt(u32, s, 10) catch return null;
    if (v == 0 or v > 10_000) return null;
    return @intCast(v);
}

/// `$COLUMNS` / `$LINES` 回退。两个都要么给出，要么用默认值补齐。
pub fn sizeFromEnv(env_cols: ?[]const u8, env_rows: ?[]const u8) ?Size {
    const c = parseDim(env_cols);
    const r = parseDim(env_rows);
    if (c == null and r == null) return null;
    return .{ .cols = c orelse DEFAULT_SIZE.cols, .rows = r orelse DEFAULT_SIZE.rows };
}

/// 终端尺寸，顺序与需求一致：
///   ioctl(stdout) -> ioctl(/dev/tty) -> $COLUMNS/$LINES -> 80x24
/// 取第一个有效值。stdout 是管道时第 1 步失败，第 2 步仍然拿到真实终端尺寸，
/// 于是 `zmatrix | zlolcat` 也能铺满屏幕，而不是退回 80x24。
pub fn detectSize(env_cols: ?[]const u8, env_rows: ?[]const u8) Size {
    if (querySize(STDOUT)) |s| return s;
    if (openTty()) |fd| {
        defer _ = linux.close(fd);
        if (querySize(fd)) |s| return s;
    }
    if (sizeFromEnv(env_cols, env_rows)) |s| return s;
    return DEFAULT_SIZE;
}

/// fd 是不是终端。
/// 注意：不能用 std.posix.tcgetattr —— 它把 EBADF 当成 unreachable，
/// stdin 被关掉（`zmatrix 0<&-`）时会直接 panic。这里自己发 ioctl 判错。
pub fn isTty(fd: posix.fd_t) bool {
    var t: posix.termios = undefined;
    const rc = linux.ioctl(fd, TCGETS, @intFromPtr(&t));
    return linuxErrno(rc) == null;
}

/// raw 模式：关掉行缓冲、回显、信号键，MIN=1/TIME=0。
pub const RawMode = struct {
    original: posix.termios,
    active: bool = false,

    pub fn enable() !RawMode {
        // 先确认 fd 真的可读终端属性，否则 tcgetattr 会 panic
        if (!isTty(STDIN)) return error.NotATerminal;
        const orig = try posix.tcgetattr(STDIN);
        var raw = orig;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(STDIN, .FLUSH, raw);
        return .{ .original = orig, .active = true };
    }

    pub fn restore(self: *RawMode) void {
        if (!self.active) return;
        posix.tcsetattr(STDIN, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

/// 用 poll 睡眠（nfds=0），避免依赖已改动的 std.time API。
pub fn sleepMs(ms: u32) void {
    if (ms == 0) return;
    _ = posix.poll(&.{}, @intCast(ms)) catch {};
}

/// 纳秒级睡眠。poll 的精度只有 1ms，`-u 0` 的帧预算要用到亚毫秒。
pub fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    var ts: posix.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    // EINTR 时直接返回：主循环下一轮还会再来，不需要在这里补睡。
    _ = linux.nanosleep(&ts, null);
}

/// 单调时钟纳秒，用于算「这一帧已经花了多久」。
pub fn nowNs() u64 {
    var ts: posix.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const sec: u64 = @intCast(@max(ts.sec, 0));
    const nsec: u64 = @intCast(@max(ts.nsec, 0));
    return sec * std.time.ns_per_s + nsec;
}

// ------------------------------------------------------------------ signals

var quit_flag = std.atomic.Value(bool).init(false);
var resize_flag = std.atomic.Value(bool).init(false);

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    if (sig == posix.SIG.WINCH) {
        resize_flag.store(true, .monotonic);
    } else {
        quit_flag.store(true, .monotonic);
    }
}

/// 安装 SIGINT/SIGTERM/SIGQUIT/SIGHUP/SIGWINCH。
pub fn installSignalHandlers() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);
    posix.sigaction(posix.SIG.QUIT, &act, null);
    posix.sigaction(posix.SIG.HUP, &act, null);
    posix.sigaction(posix.SIG.WINCH, &act, null);
    // 写已关闭的管道时不要被 SIGPIPE 杀掉，改为让 write 返回错误。
    var ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ign, null);
}

pub fn quitRequested() bool {
    return quit_flag.load(.monotonic);
}

pub fn requestQuit() void {
    quit_flag.store(true, .monotonic);
}

pub fn takeResize() bool {
    return resize_flag.swap(false, .monotonic);
}

test "default size is a sane fallback" {
    // 非 tty fd 应当退化到 80x24 而不是崩溃
    const s = getSize(-1);
    try std.testing.expect(s.cols > 0 and s.rows > 0);
    try std.testing.expect(querySize(-1) == null);
}

test "size falls back to COLUMNS/LINES and then to 80x24" {
    try std.testing.expectEqual(Size{ .cols = 120, .rows = 40 }, sizeFromEnv("120", "40").?);
    // 只给一个维度时，另一个用默认值补齐
    try std.testing.expectEqual(Size{ .cols = 100, .rows = 24 }, sizeFromEnv("100", null).?);
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 50 }, sizeFromEnv(null, "50").?);
    // 脏值忽略：坏的那一维退回默认值
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 40 }, sizeFromEnv("abc", "40").?);
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 40 }, sizeFromEnv("0", "40").?);
    try std.testing.expectEqual(Size{ .cols = 80, .rows = 40 }, sizeFromEnv("  ", "40").?);
    // 两维都无效 -> 没有环境变量层面的答案，交给 80x24
    try std.testing.expect(sizeFromEnv("-3", "x") == null);
    // detectSize 在无 tty 的测试进程里也必须给出合理值
    const s = detectSize("7", "9");
    try std.testing.expect(s.cols > 0 and s.rows > 0);
}

test "raw mode is rejected on a non-tty without crashing" {
    if (!isTty(STDIN)) {
        if (RawMode.enable()) |raw| {
            var r = raw;
            defer r.restore();
            return error.ExpectedNotATerminal;
        } else |_| {}
    }
}

test "writeAll and readSome survive bad fds" {
    try writeAll(STDERR, "");
    try std.testing.expect(writeAll(-1, "x") == error.WriteFailed);
    const r = readSome(-1, &[_]u8{});
    try std.testing.expect(r == .eof);
}
