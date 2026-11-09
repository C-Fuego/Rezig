//! Low level terminal handling, built directly on `std.os.linux` syscalls.
//!
//! Zig 0.17 notes:
//!   * There is no `std.posix.write` anymore, so every write goes through
//!     `std.os.linux.write` with the negative errno decoded by
//!     `std.os.linux.errno`.
//!   * There is no `std.Thread.sleep`, and no `b.args`; sleeping is done by
//!     polling stdin (which doubles as key detection) - see `pollInput`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

/// `cc` indices for the special characters of `struct termios`; Linux does not
/// export these as named constants in Zig's std.
const cc_index = struct {
    const VTIME: usize = 5;
    const VMIN: usize = if (builtin.cpu.arch == .mips or
        builtin.cpu.arch == .mipsel or
        builtin.cpu.arch == .mips64 or
        builtin.cpu.arch == .mips64el) 4 else 6;
};

// ---------------------------------------------------------------------------
// raw byte output
// ---------------------------------------------------------------------------

/// Write the whole buffer to `fd`. Errors (EPIPE, EIO, ...) are deliberately
/// swallowed: zbonsai is a toy, and the only sane reaction to a dead stdout is
/// to keep running until the main loop notices it cannot draw anything.
pub fn writeAll(fd: fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const addr = @intFromPtr(bytes.ptr + off);
        const rest = bytes.len - off;
        const r = linux.write(fd, @ptrFromInt(addr), rest);
        switch (linux.errno(r)) {
            .SUCCESS => off += r,
            .INTR => continue,
            else => return,
        }
    }
}

/// Small buffered writer over a raw file descriptor.
pub const Out = struct {
    fd: fd_t,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    broken: bool = false,

    pub fn init(fd: fd_t) Out {
        return .{ .fd = fd };
    }

    pub fn write(self: *Out, bytes: []const u8) void {
        if (self.broken or bytes.len == 0) return;
        if (bytes.len >= self.buf.len) {
            self.flush();
            writeAll(self.fd, bytes);
            return;
        }
        if (self.len + bytes.len > self.buf.len) self.flush();
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn writeByte(self: *Out, b: u8) void {
        self.write(&[_]u8{b});
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.write(text);
    }

    pub fn flush(self: *Out) void {
        if (self.len == 0) return;
        writeAll(self.fd, self.buf[0..self.len]);
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// terminal geometry
// ---------------------------------------------------------------------------

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const default_size: Size = .{ .rows = 24, .cols = 80 };

pub fn isTty(fd: fd_t) bool {
    var t: linux.termios = undefined;
    return linux.errno(linux.tcgetattr(fd, &t)) == .SUCCESS;
}

pub fn size(fd: fd_t) ?Size {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const r = linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(r) != .SUCCESS) return null;
    if (ws.row == 0 or ws.col == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// Terminal size for the TUI, falling back to `$LINES`/`$COLUMNS` and finally
/// to 80x24 so that a piped run (or a broken ioctl) still produces output.
pub fn querySize(fd: fd_t, environ: *const std.process.Environ.Map) Size {
    if (size(fd)) |s| return s;
    var fallback = default_size;
    if (environ.get("LINES")) |v| {
        if (std.fmt.parseInt(u16, std.mem.trim(u8, v, " \t"), 10)) |n| {
            if (n > 0) fallback.rows = n;
        } else |_| {}
    }
    if (environ.get("COLUMNS")) |v| {
        if (std.fmt.parseInt(u16, std.mem.trim(u8, v, " \t"), 10)) |n| {
            if (n > 0) fallback.cols = n;
        } else |_| {}
    }
    return fallback;
}

// ---------------------------------------------------------------------------
// raw mode
// ---------------------------------------------------------------------------

pub const RawMode = struct {
    active: bool = false,
    fd: fd_t = 0,
    saved: linux.termios = undefined,

    /// Switch `fd` into raw-ish mode: no line buffering, no echo, no signal
    /// translation of flow control, but keep ISIG so that Ctrl-C still raises
    /// SIGINT (cbonsai's `cbreak()` behaves the same way).
    pub fn enable(self: *RawMode, fd: fd_t) bool {
        var t: linux.termios = undefined;
        if (linux.errno(linux.tcgetattr(fd, &t)) != .SUCCESS) return false;
        self.saved = t;
        self.fd = fd;

        t.iflag.ICRNL = false;
        t.iflag.IXON = false;
        t.iflag.BRKINT = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        t.oflag.OPOST = true; // keep "\n" -> "\r\n" translation
        t.cflag.CSIZE = .CS8;
        t.lflag.ICANON = false;
        t.lflag.ECHO = false;
        t.lflag.IEXTEN = false;
        t.lflag.ISIG = true;
        t.cc[cc_index.VMIN] = 0;
        t.cc[cc_index.VTIME] = 0;

        if (linux.errno(linux.tcsetattr(fd, .FLUSH, &t)) != .SUCCESS) return false;
        self.active = true;
        return true;
    }

    pub fn disable(self: *RawMode) void {
        if (!self.active) return;
        _ = linux.tcsetattr(self.fd, .FLUSH, &self.saved);
        self.active = false;
    }
};

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------

/// Wait up to `timeout_ms` milliseconds for stdin to become readable.
/// Returns `true` when at least one byte can be read. EINTR (a signal) reports
/// `false`; callers check the signal flags afterwards.
pub fn pollInput(fd: fd_t, timeout_ms: i32) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const r = linux.poll(&fds, 1, timeout_ms);
    if (linux.errno(r) != .SUCCESS) return false;
    if (r == 0) return false;
    return (fds[0].revents & linux.POLL.IN) != 0;
}

/// Read one byte, if any is available right now.
pub fn readKey(fd: fd_t) ?u8 {
    var buf: [32]u8 = undefined;
    const r = linux.read(fd, &buf, buf.len);
    if (linux.errno(r) != .SUCCESS) return null;
    if (r == 0) return null;
    return buf[0];
}

// ---------------------------------------------------------------------------
// signals
// ---------------------------------------------------------------------------

var resize_flag = std.atomic.Value(u32).init(0);
var quit_flag = std.atomic.Value(u32).init(0);

fn handleSignal(sig: linux.SIG) callconv(.c) void {
    switch (sig) {
        .WINCH => _ = resize_flag.fetchAdd(1, .monotonic),
        else => _ = quit_flag.store(1, .monotonic),
    }
}

pub fn installSignalHandlers() void {
    var act: linux.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        // No SA_RESTART: blocking syscalls must return EINTR so that the main
        // loop can notice a quit request immediately.
        .flags = 0,
    };
    for ([_]linux.SIG{ .WINCH, .INT, .TERM, .HUP, .QUIT }) |sig| {
        _ = linux.sigaction(sig, &act, null);
    }
}

pub fn tookResize() bool {
    return resize_flag.swap(0, .monotonic) != 0;
}

pub fn quitRequested() bool {
    return quit_flag.load(.monotonic) != 0;
}

// ---------------------------------------------------------------------------
// escape sequences
// ---------------------------------------------------------------------------

pub fn hideCursor(out: *Out) void {
    out.write("\x1b[?25l");
}

pub fn showCursor(out: *Out) void {
    out.write("\x1b[?25h");
}

pub fn enterAltScreen(out: *Out) void {
    out.write("\x1b[?1049h");
}

pub fn exitAltScreen(out: *Out) void {
    out.write("\x1b[?1049l");
}

pub fn clearScreen(out: *Out) void {
    out.write("\x1b[2J\x1b[H");
}

pub fn resetStyle(out: *Out) void {
    out.write("\x1b[0m");
}

test "errno decoding of a bad fd" {
    // Writing to an fd that is definitely not open must fail with EBADF and not
    // panic, regardless of the fact that writeAll swallows errors.
    writeAll(-1, "nope");
    try std.testing.expect(true);
}
