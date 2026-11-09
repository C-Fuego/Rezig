const std = @import("std");

/// Buffered stdout/stderr wrapper that swallows write errors, so the rest of
/// the program never has to handle a broken pipe.
pub const Out = struct {
    w: *std.Io.Writer,
    /// ANSI styling, the way clap decides it: tty only, unless forced or
    /// switched off through the usual environment variables.
    styled: bool = false,
    failed: bool = false,

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        if (self.failed) return;
        self.w.print(fmt, args) catch {
            self.failed = true;
        };
    }

    pub fn write(self: *Out, bytes: []const u8) void {
        if (self.failed) return;
        self.w.writeAll(bytes) catch {
            self.failed = true;
        };
    }

    pub fn flush(self: *Out) void {
        if (self.failed) return;
        self.w.flush() catch {};
    }

    const bold_code = "\x1b[1m";
    const underline_code = "\x1b[4m";
    const reset_code = "\x1b[0m";
    const red_bold_code = "\x1b[1m\x1b[31m";
    const yellow_code = "\x1b[33m";
    const green_code = "\x1b[32m";

    fn code(self: *Out, sequence: []const u8) void {
        if (self.styled) self.write(sequence);
    }

    /// Bold, as clap styles literals such as command and flag names.
    pub fn bold(self: *Out, text: []const u8) void {
        self.code(bold_code);
        self.write(text);
        self.code(reset_code);
    }

    /// Bold and underlined, as clap styles the "Usage:" style headers.
    pub fn header(self: *Out, text: []const u8) void {
        self.code(bold_code);
        self.code(underline_code);
        self.write(text);
        self.code(reset_code);
    }

    pub fn yellow(self: *Out, text: []const u8) void {
        self.code(yellow_code);
        self.write(text);
        self.code(reset_code);
    }

    pub fn green(self: *Out, text: []const u8) void {
        self.code(green_code);
        self.write(text);
        self.code(reset_code);
    }

    pub fn errorBadge(self: *Out) void {
        self.code(red_bold_code);
        self.write("error:");
        self.code(reset_code);
    }

    pub fn tipBadge(self: *Out) void {
        self.code(green_code);
        self.write("tip:");
        self.code(reset_code);
    }
};

/// Usage problems exit with 2, everything else with 1.
pub const Fail = error{ Usage, Failure };

pub const Ctx = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    out: Out,
    err: Out,
    /// Scratch space for path formatting, so printing never allocates.
    buffer: [256]u8 = undefined,

    /// "Error: ..." on stderr, exit code 1.
    pub fn die(ctx: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        ctx.err.print("Error: " ++ fmt ++ "\n", args);
        return error.Failure;
    }
};
