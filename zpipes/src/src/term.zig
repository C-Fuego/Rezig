const std = @import("std");
const posix = std.posix;
const sys = @import("xsys.zig");

pub const Size = struct {
    cols: usize,
    rows: usize,
};

/// 信号处理器只写这两个原子标志，主循环负责真正的清理。
pub var winch_pending = std.atomic.Value(bool).init(false);
pub var quit_pending = std.atomic.Value(bool).init(false);

fn onWinch(_: posix.SIG) callconv(.c) void {
    winch_pending.store(true, .monotonic);
}

fn onQuit(_: posix.SIG) callconv(.c) void {
    quit_pending.store(true, .monotonic);
}

pub fn installSignals() void {
    // 全零 sigset 就是空信号集。
    const empty: posix.sigset_t = std.mem.zeroes(posix.sigset_t);

    const winch_action: posix.Sigaction = .{
        .handler = .{ .handler = onWinch },
        .mask = empty,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &winch_action, null);

    const quit_action: posix.Sigaction = .{
        .handler = .{ .handler = onQuit },
        .mask = empty,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &quit_action, null);
    posix.sigaction(posix.SIG.TERM, &quit_action, null);
    posix.sigaction(posix.SIG.HUP, &quit_action, null);
    posix.sigaction(posix.SIG.QUIT, &quit_action, null);

    // 输出被管道关闭时不要被 SIGPIPE 直接杀死，让 write 返回错误走清理路径。
    const ignore_action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = empty,
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &ignore_action, null);
}

pub fn getSize() Size {
    const fds = [_]posix.fd_t{
        posix.STDOUT_FILENO,
        posix.STDIN_FILENO,
        posix.STDERR_FILENO,
    };
    for (fds) |fd| {
        var ws: posix.winsize = std.mem.zeroes(posix.winsize);
        const rc = sys.ioctl(fd, sys.ioctl_req.TIOCGWINSZ, @intFromPtr(&ws));
        if (sys.errno(rc) == .SUCCESS and ws.col > 0 and ws.row > 0) {
            return .{
                .cols = @as(usize, @max(ws.col, 2)),
                .rows = @as(usize, @max(ws.row, 2)),
            };
        }
    }
    // 非终端（例如被重定向到管道）时给一个安全尺寸。
    return .{ .cols = 80, .rows = 24 };
}

/// 0.17 不再提供 std.posix.write，经 xsys 垫片写 fd 并处理 EINTR/短写。
pub fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = sys.write(fd, bytes.ptr + off, bytes.len - off);
        switch (sys.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                off += rc;
            },
            .INTR => continue,
            .AGAIN => {
                var fds = [_]posix.pollfd{.{
                    .fd = fd,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = posix.poll(&fds, 100) catch return error.WriteFailed;
            },
            else => return error.WriteFailed,
        }
    }
}

/// fd 是不是终端：用 ioctl(TCGETS) 判错，坏 fd 安全返回 false。
pub fn isTty(fd: posix.fd_t) bool {
    if (fd < 0) return false;
    var t: sys.termios = undefined;
    const rc = sys.tcgetattr(fd, &t);
    return sys.errno(rc) == .SUCCESS;
}

pub fn print(fd: posix.fd_t, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return error.MessageTooLong;
    try writeAll(fd, s);
}

/// 非阻塞地读按键；没有输入时返回 0。
/// 经 xsys 垫片统一 errno 语义：EOF / EIO / EAGAIN 都当作"此刻没有按键"，不冒泡成致命错误。
pub fn readInput(buf: []u8) !usize {
    const rc = sys.read_nonblock(posix.STDIN_FILENO, buf);
    return switch (sys.errno(rc)) {
        .SUCCESS => rc,
        .INTR, .AGAIN, .IO => 0,
        else => if (rc == 0) 0 else 0,
    };
}

pub const RawMode = struct {
    orig: posix.termios,
    fd: posix.fd_t,
    active: bool = true,

    /// 等价于 cfmakeraw：关闭行缓冲、回显、信号键和输出处理。
    pub fn enable(fd: posix.fd_t) !RawMode {
        // 非终端（stdin 被重定向成管道/文件）时直接告诉调用方，而不是让
        // std.posix.tcgetattr 把 ENOTTY 当成 unreachable 触发 panic/意外错误。
        if (!isTty(fd)) return error.NotATerminal;
        const orig = try posix.tcgetattr(fd);
        var raw = orig;

        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        raw.lflag.ISIG = false;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.IEXTEN = false;

        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);
        return .{ .orig = orig, .fd = fd };
    }

    pub fn restore(self: *RawMode) void {
        if (!self.active) return;
        posix.tcsetattr(self.fd, .NOW, self.orig) catch {};
        self.active = false;
    }
};

pub fn enterScreen() !void {
    // 备用屏幕 + 隐藏光标 + 关闭自动换行 + 清屏。
    try writeAll(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H\x1b[0m");
}

pub fn leaveScreen() void {
    writeAll(posix.STDOUT_FILENO, "\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l") catch {};
}

pub fn nowNs() u64 {
    var ts: posix.timespec = undefined;
    const rc = sys.clock_gettime(sys.CLOCK.MONOTONIC, &ts);
    if (sys.errno(rc) != .SUCCESS) return 0;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *% 1_000_000_000 +% nsec;
}

pub fn sleepNs(ns: u64) void {
    var ts: posix.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = sys.nanosleep(&ts, null);
}
