//! 终端底层：只用 std.os.linux 的裸系统调用（0.17 里 std.fs 变成 std.Io，
//! std.posix.write / std.time.* 都没了），外加几个信号标志。
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const STDOUT = posix.STDOUT_FILENO;
pub const STDIN = posix.STDIN_FILENO;
pub const STDERR = posix.STDERR_FILENO;

pub const ALT_ON = "\x1b[?1049h";
pub const ALT_OFF = "\x1b[?1049l";
pub const CURSOR_HIDE = "\x1b[?25l";
pub const CURSOR_SHOW = "\x1b[?25h";
pub const SGR_RESET = "\x1b[0m";
pub const CLEAR_SCREEN = "\x1b[2J";

pub const Size = struct { cols: i32, rows: i32 };
pub const DEFAULT_SIZE = Size{ .cols = 80, .rows = 24 };

const TIOCGWINSZ: u32 = 0x5413;
const TCGETS: u32 = 0x5401;

/// 系统调用返回 usize，负数按 -errno 编码（0.17 没有 std.posix 的错误装饰了）。
pub fn errnoOf(rc: usize) ?linux.E {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return null;
    return @enumFromInt(@as(u16, @intCast(-signed)));
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (errnoOf(rc)) |e| {
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

pub fn readSome(fd: posix.fd_t, buf: []u8) ReadResult {
    if (buf.len == 0) return .retry;
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (errnoOf(rc)) |e| {
        switch (e) {
            .INTR, .AGAIN => return .retry,
            else => return .eof,
        }
    }
    if (rc == 0) return .eof;
    return .{ .data = buf[0..rc] };
}

pub fn getSize(fd: posix.fd_t) Size {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = linux.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws));
    if (errnoOf(rc) != null) return DEFAULT_SIZE;
    if (ws.col == 0 or ws.row == 0) return DEFAULT_SIZE;
    return .{ .cols = @intCast(ws.col), .rows = @intCast(ws.row) };
}

/// tty-clock 用 S_ISCHR 判断 -T 参数；0.17 没有 fstat 包装，
/// 这里用 TCGETS 是否成功判断"是不是终端设备"（够用，且对坏 fd 不会像
/// std.posix.tcgetattr 那样把 EBADF 当 unreachable 直接 panic）。
pub fn isTty(fd: posix.fd_t) bool {
    if (fd < 0) return false;
    var buf: [128]u8 = undefined;
    const rc = linux.ioctl(fd, TCGETS, @intFromPtr(&buf));
    return errnoOf(rc) == null;
}

pub const OpenResult = union(enum) {
    fd: posix.fd_t,
    err: linux.E,
};

/// 以读写打开（对应原版 fopen(tty, "r+")）。
pub fn openRdwr(path: [:0]const u8) OpenResult {
    const flags = linux.O{ .ACCMODE = .RDWR, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, flags, 0);
    if (errnoOf(rc)) |e| return .{ .err = e };
    return .{ .fd = @intCast(rc) };
}

/// 整文件读入（时区数据库文件用），上限 max 字节。
pub fn readFileAlloc(alloc: std.mem.Allocator, path: [:0]const u8, max: usize) ?[]u8 {
    const flags = linux.O{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, flags, 0);
    if (errnoOf(rc)) |_| return null;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var list: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (list.items.len < max) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (errnoOf(n)) |e| {
            if (e == .INTR) continue;
            break;
        }
        if (n == 0) break;
        list.appendSlice(alloc, chunk[0..n]) catch break;
    }
    if (list.items.len == 0) return null;
    return list.items;
}

/// ncurses 的 cbreak()：关 ICANON/ECHO/IEXTEN，保留 ISIG（Ctrl-C 仍能产生 SIGINT）。
pub const Cbreak = struct {
    original: posix.termios,
    active: bool = false,

    pub fn enable(fd: posix.fd_t) !Cbreak {
        const orig = try posix.tcgetattr(fd);
        var mode = orig;
        mode.lflag.ICANON = false;
        mode.lflag.ECHO = false;
        mode.lflag.IEXTEN = false;
        mode.cc[@intFromEnum(posix.V.MIN)] = 1;
        mode.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, mode);
        return .{ .original = orig, .active = true };
    }

    pub fn restore(self: *Cbreak, fd: posix.fd_t) void {
        if (!self.active) return;
        posix.tcsetattr(fd, .FLUSH, self.original) catch {};
        self.active = false;
    }
};

/// 等 fd 可读，超时用 timespec（原版就是 pselect(delay, nsdelay)）。
pub fn waitReadable(fd: posix.fd_t, timeout: ?*const posix.timespec) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    _ = posix.ppoll(&fds, timeout, null) catch return false;
    return fds[0].revents != 0;
}

/// 纯睡眠（原版 pselect 的 delay 部分）。
pub fn sleepFor(timeout: ?*const posix.timespec) void {
    _ = posix.ppoll(&.{}, timeout, null) catch {};
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
    // 管道被关闭时让 write 返回 EPIPE，而不是被 SIGPIPE 杀掉。
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

pub fn takeResize() bool {
    return resize_flag.swap(false, .monotonic);
}

test "errnoOf decodes negative syscall results" {
    try std.testing.expect(errnoOf(0) == null);
    try std.testing.expect(errnoOf(7) == null);
    const encoded: usize = @bitCast(@as(isize, -@as(isize, @intFromEnum(linux.E.INVAL))));
    try std.testing.expect(errnoOf(encoded).? == .INVAL);
}

test "getSize falls back to 80x24 on a non-tty fd" {
    const s = getSize(-1);
    try std.testing.expect(s.cols > 0 and s.rows > 0);
    try std.testing.expect(!isTty(-1));
}
