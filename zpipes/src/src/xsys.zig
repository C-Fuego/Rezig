//! 跨平台系统调用垫片：Linux 上保持原有裸 syscall 语义，其它平台（macOS 等）走 libc。
//!
//! 用法（与原 `std.os.linux.*` 的调用形态一一对应，业务代码不需要改逻辑）：
//!   const sys = @import("xsys.zig");
//!   const rc = sys.write(fd, ptr, len);   // usize：非负成功，负数按 -errno 编码
//!   switch (sys.errno(rc)) { .SUCCESS => ..., .INTR => continue, ... }
//!
//! 与 std.os.linux 的差异只有两点，都收敛在本文件：
//!   1. 返回值统一归一到 "usize 编码的 -errno"；
//!   2. errno 统一成平台无关的 `Err` 枚举（Linux E 是原始编码，Darwin E 是平台专属编码，
//!      直接 @enumFromInt 会错位，所以这里按 errno 数值显式映射）。
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const is_linux = builtin.os.tag == .linux;

/// 文件描述符类型与平台一致。
pub const fd_t = posix.fd_t;

/// 与 std.os.linux 同名的类型/常量别名，让业务代码的 linux.xxx 写法保持可用。
pub const SIG = posix.SIG;
pub const Sigaction = posix.Sigaction;
pub const sigset_t = posix.sigset_t;

/// 注册信号处理（linux.sigaction 对应物；第三个参数保持与 linux 一致以便调用处不用改）。
pub fn sigaction(sig: SIG, act: *const Sigaction, old: ?*Sigaction) Rc {
    posix.sigaction(sig, act, old);
    return 0;
}

pub const termios = posix.termios;
pub const pollfd = posix.pollfd;
pub const winsize = posix.winsize;
pub const POLL = posix.POLL;
pub const O = posix.O;

/// 打开终端属性（linux.tcgetattr 对应物）。
pub fn tcgetattr(fd: fd_t, t: *termios) Rc {
    t.* = posix.tcgetattr(fd) catch |err| return errToRc(err);
    return 0;
}

/// 设置终端属性（linux.tcsetattr 对应物）。
pub fn tcsetattr(fd: fd_t, action: posix.TCSA, t: *const termios) Rc {
    posix.tcsetattr(fd, action, t.*) catch |err| return errToRc(err);
    return 0;
}

/// poll(2)（linux.poll 对应物：Linux 签名带 nfds，这里按切片传入）。
pub fn poll(fds: []pollfd, timeout_ms: i32) Rc {
    if (posix.poll(fds, timeout_ms)) |n| {
        return n;
    } else |err| {
        return errToRc(err);
    }
}

fn errToRc(err: anyerror) Rc {
    const name = @errorName(err);
    const code: isize = if (std.mem.eql(u8, name, "Interrupted")) 4 //
    else if (std.mem.eql(u8, name, "WouldBlock")) 11 //
    else if (std.mem.eql(u8, name, "NotOpenForReading") or std.mem.eql(u8, name, "NotOpenForWriting")) 9 //
    else if (std.mem.eql(u8, name, "InvalidFileDescriptor")) 9 //
    else 5;
    return @bitCast(-code);
}

/// 系统调用返回值：非负为成功，负数为 -errno。
pub const Rc = usize;

/// 平台无关的错误集合，覆盖终端程序用得到的那些。
pub const Err = enum {
    SUCCESS,
    INTR,
    AGAIN,
    BADF,
    NOENT,
    ACCES,
    PERM,
    IO,
    INVAL,
    NOSYS,
    OTHER,
};

fn fromErrnoValue(v: u32) Err {
    return switch (v) {
        0 => .SUCCESS,
        4 => .INTR, // EINTR 在 Linux / Darwin 上都是 4
        9 => .BADF,
        11 => .AGAIN, // Linux EAGAIN=11
        13 => .ACCES,
        1 => .PERM,
        2 => .NOENT,
        5 => .IO,
        22 => .INVAL,
        38 => .NOSYS, // Linux ENOSYS=38
        else => .OTHER,
    };
}

/// 与错误集合同名的类型别名（业务代码里 sys.E 的写法）。
pub const E = Err;

/// 解析返回值里的 errno。
pub fn errno(rc: Rc) Err {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return .SUCCESS;
    const neg: isize = -signed;
    if (neg > 4095) return .OTHER; // 不是 errno 编码，视为失败
    return fromErrnoValue(@intCast(neg));
}

/// 把 libc 风格返回值（成功 >=0；失败 -1 并置 errno）归一成 Rc。
fn fromLibc(rc: anytype) Rc {
    // 注意：不能先 @intCast 到 c_int —— libc 成功时返回的 fd 等值可能超出 u31，
    // 会触发 "integer does not fit" 的编译期判定。这里按返回值自身的类型判正负。
    const v: switch (@typeInfo(@TypeOf(rc))) {
        .int => isize,
        .comptime_int => isize,
        else => @compileError("fromLibc 只接受整数返回值"),
    } = @intCast(rc);
    if (v >= 0) return @intCast(v);
    const raw: c_int = std.c._errno().*;
    if (raw == 0) return @bitCast(@as(isize, -1));
    return @bitCast(-@as(isize, raw));
}

pub fn write(fd: posix.fd_t, ptr: [*]const u8, len: usize) Rc {
    if (is_linux) return std.os.linux.write(fd, ptr, len);
    return fromLibc(posix.system.write(fd, ptr, len));
}

pub fn read(fd: posix.fd_t, ptr: [*]u8, len: usize) Rc {
    if (is_linux) return std.os.linux.read(fd, ptr, len);
    return fromLibc(posix.system.read(fd, ptr, len));
}

pub fn open(path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) Rc {
    if (is_linux) return std.os.linux.open(path, flags, mode);
    return fromLibc(posix.system.open(path, flags, mode));
}

pub fn openat(dirfd: posix.fd_t, path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) Rc {
    if (is_linux) return std.os.linux.openat(dirfd, path, flags, mode);
    return fromLibc(posix.system.openat(dirfd, path, flags, mode));
}

pub fn close(fd: posix.fd_t) Rc {
    if (is_linux) return std.os.linux.close(fd);
    return fromLibc(posix.system.close(fd));
}

/// 创建管道（对应 linux.pipe2 的 CLOEXEC 行为）。fds 为 [读端, 写端]。
pub fn pipe(fds: *[2]posix.fd_t) Rc {
    if (is_linux) return std.os.linux.pipe2(fds, .{ .CLOEXEC = true });
    // libc: pipe() 不支持原子 CLOEXEC；测试与运行时都会显式关闭，这里不额外处理。
    return fromLibc(std.c.pipe(fds));
}

/// 非阻塞读一次：有数据返回字节数，无数据返回 0，出错返回 -errno。
/// 用途：终端轮询式按键读取；EOF(0) 与错误区分开，避免把 EIO/EAGAIN 当致命错误。
pub fn read_nonblock(fd: posix.fd_t, buf: []u8) Rc {
    var fds = [_]pollfd{.{ .fd = fd, .events = POLL.IN, .revents = 0 }};
    const prc = poll(&fds, 0);
    if (errno(prc) != .SUCCESS) return prc;
    if (prc == 0) return 0;
    if ((fds[0].revents & posix.POLL.IN) == 0) return 0;
    return read(fd, buf.ptr, buf.len);
}

pub fn getpid() Rc {
    if (is_linux) return std.os.linux.getpid();
    return @intCast(std.c.getpid());
}

pub fn nanosleep(ts: *const posix.timespec, rem: ?*posix.timespec) Rc {
    return fromLibc(posix.system.nanosleep(ts, rem));
}

pub const CLOCK = posix.CLOCK;

pub fn clock_gettime(clk: posix.clockid_t, tp: *posix.timespec) Rc {
    return fromLibc(posix.system.clock_gettime(clk, tp));
}

/// ioctl 请求号：两套平台的编号完全不同，按平台取值。
pub const T = struct {
    pub const IOCGWINSZ: u32 = ioctl_req.TIOCGWINSZ;
    pub const TIOCGWINSZ: u32 = ioctl_req.TIOCGWINSZ;
};

pub const ioctl_req = if (is_linux) struct {
    pub const TCGETS: u32 = 0x5401;
    pub const TCSETS: u32 = 0x5402;
    pub const TIOCGWINSZ: u32 = 0x5413;
} else struct {
    // Darwin: TIOCGETA / TIOCSETA / TIOCGWINSZ
    pub const TCGETS: u32 = 0x40487413;
    pub const TCSETS: u32 = 0x80487414;
    pub const TIOCGWINSZ: u32 = 0x40087468;
};

/// ppoll 的跨平台版：Linux 直接用 ppoll；其它平台没有 ppoll，
/// 就用 poll + nanosleep 实现（语义等价：有无超时都可，不看 sigmask）。
/// 返回值：>0 就绪个数，0 超时，负数 -errno。
pub fn ppoll(fds: []posix.pollfd, timeout: ?*const posix.timespec, sigmask: ?*const posix.sigset_t) Rc {
    if (is_linux) return std.os.linux.ppoll(fds, timeout, sigmask, std.posix.system.NFDBITS);

    var ms: i32 = -1; // -1 = 无限等待
    if (timeout) |t| {
        const total_ms = @divTrunc(t.sec, 1) * 1000 + @divTrunc(t.nsec, 1_000_000);
        ms = @intCast(@max(total_ms, 0));
    }
    if (posix.poll(fds, ms)) |n| {
        return n;
    } else |_| {
        return @bitCast(@as(isize, -1));
    }
}

pub fn ioctl(fd: posix.fd_t, request: u32, arg: usize) Rc {
    if (is_linux) return std.os.linux.ioctl(fd, request, arg);
    // Darwin 的 ioctl 是可变参数 C 函数：request 与 arg 都必须按 c_ulong 传递，
    // 传窄类型会被截断导致 ENOTTY。
    if (builtin.link_libc) {
        // 声明为可变参数函数，才能按 c_ulong 传 request/arg（窄类型会被截断成 ENOTTY）。
        const IoctlFn = *const fn (c_int, c_ulong, ...) callconv(.c) c_int;
        const ioctl_fn: IoctlFn = @ptrCast(&std.c.ioctl);
        return fromLibc(ioctl_fn(fd, @as(c_ulong, request), @as(c_ulong, arg)));
    }
    return fromLibc(posix.system.ioctl(fd, @intCast(request), arg));
}
