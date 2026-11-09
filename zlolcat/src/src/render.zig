//! The colouring loop, ported from lolcat's `Lol.cat` / `Lol.println*`.
//!
//! The Ruby original, in full:
//!
//!     def self.cat(fd, opts)
//!       @os = opts[:os]
//!       print "\e[?25l" if opts[:animate]
//!       while true
//!         buf = ''
//!         begin
//!           begin
//!             buf += fd.sysread(4096)
//!             invalid_encoding = ...
//!           end while invalid_encoding or buf.match(INCOMPLETE_ESCAPE)
//!         rescue EOFError
//!           break
//!         end
//!         buf.lines.each do |line|
//!           @os += 1
//!           println(line, opts)
//!         end
//!       end
//!     ensure
//!       if STDOUT.tty? then print "\e[m\e[?25h\e[?1;5;2004l" end
//!     end
//!
//!     def self.println(str, defaults={}, opts={})
//!       opts.merge!(defaults)
//!       chomped = str.sub!(/\n$/, "")
//!       str.gsub! "\t", "        "
//!       opts[:animate] ? println_ani(str, opts, chomped) : println_plain(str, opts, chomped)
//!       puts if chomped
//!     end
//!
//!     def self.println_plain(str, defaults={}, opts={}, chomped)
//!       filtered = str.scan(ANSI_ESCAPE)
//!       filtered.each_with_index do |c, i|
//!         color = rainbow(opts[:freq], @os+i/opts[:spread])
//!         print c[0], Paint.color(color), c[1], "\e[39m"
//!       end
//!       if chomped == nil
//!         @old_os = @os
//!         @os = @os + filtered.length/opts[:spread]
//!       elsif @old_os
//!         @os = @old_os
//!         @old_os = nil
//!       end
//!     end
//!
//! What that means in practice:
//!
//!  * Every code point of a line is printed as `<?>colour<point>\e[39m`; the
//!    escape prefix in front of it (`\e[31m`, an OSC title, ...) is copied
//!    verbatim first, so any colour the input already set is overridden by
//!    ours.  A space, a tab (after expansion), a CR, the BEL of an OSC: all of
//!    them are characters and all of them are painted.
//!  * `@os` advances by **one per line** (the `@os += 1` in `cat`), and the
//!    colour index inside a line is `@os + i/spread`.  The `filtered.length/
//!    spread` in `println_plain` is *not* the per-line advance: it only runs
//!    for a line without a trailing newline (the last line of a 4096-byte
//!    read), and the very next line undoes it again through `@old_os` (or the
//!    file ends there).
//!  * A line with a trailing newline gets the newline after the whole line has
//!    been painted, so `\e[39m\n`.
//!  * `-i` paints the background instead and closes every character with
//!    `\e[49m`.
//!  * `-a` redraws each line `duration` times in place (`\e7` once, `\e8` per
//!    frame, `@os += spread` per frame, `sleep 1/speed` after every frame,
//!    then `@os` is restored), and strips `\e[...@JKPX` from the line between
//!    frames.

const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const cli = @import("cli.zig");
const color = @import("color.zig");

const Io = std.Io;

/// One `fd.sysread(4096)` of the original.  The buffer size is part of the
/// behaviour: a chunk that ends in the middle of a line ends with a line
/// without a newline, which is where the `filtered.length/spread` step of
/// `println_plain` is visible at all.
pub const chunk_size = 4096;

/// How much output is staged before one `write`.  The original prints four
/// times per character through a 4096-byte-buffered stdout; a cmatrix stream is
/// ~226k characters per second, i.e. ~900k writes, and every one of them went
/// straight through `std.Io.Writer` to the file.  Staging a whole block means
/// one `writeAll` per 32 KiB instead of four calls per character.
pub const emit_size = 32 * 1024;

/// How long a block of input may wait for its 4096 bytes to arrive.
///
/// The Ruby original reads with `sysread(4096)`, which returns as soon as *any*
/// byte is there - but this is a filter, so it wanted to hold a whole block to
/// amortise the work.  Waiting for the block to *fill* is what made
/// `(printf 'abc'; sleep 2) | zlolcat` print nothing for two seconds: `abc`
/// never grows to 4096.  So a block is gathered for at most this long; after
/// that whatever arrived is rendered and written.
pub const gather_ms = 5;

/// `poll` is POSIX only; elsewhere a block is simply one read.
const gather_supported = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding, .other => false,
    else => true,
};

pub const Renderer = struct {
    out: *Io.Writer,
    io: Io,
    allocator: std.mem.Allocator,

    frequency: f64,
    spread: f64,
    mode: color.Mode,
    animate: bool,
    duration: u32,
    speed: f64,
    dialup: bool,
    invert: bool,
    invert_hue: bool,
    /// extension: never inject a colour, only copy the input through
    passthrough: bool,
    /// extension: do not spend an escape on a space (`--no-space-color`)
    no_space_color: bool,
    /// false = plain `cat` (stdout is not a tty and `-f` was not given)
    enabled: bool,
    stdout_is_tty: bool,

    /// `opts[:os]`: where the rainbow starts for each file
    seed: f64,
    /// Ruby's `@os`
    os: f64,
    /// Ruby's `@old_os`
    old_os: ?f64 = null,

    /// bytes of the current read block that are still to be printed
    pending: std.ArrayList(u8) = .empty,
    /// the current line after the tab expansion
    line: std.ArrayList(u8) = .empty,
    /// working copy of a line while it is animated
    frame: std.ArrayList(u8) = .empty,
    cursor_hidden: bool = false,
    /// output staged for the next write
    emit_buffer: [emit_size]u8 = undefined,
    emit_len: usize = 0,

    pub fn init(
        out: *Io.Writer,
        io: Io,
        allocator: std.mem.Allocator,
        opts: cli.Options,
        mode: color.Mode,
        seed: f64,
        enabled: bool,
        stdout_is_tty: bool,
    ) Renderer {
        return .{
            .out = out,
            .io = io,
            .allocator = allocator,
            .frequency = opts.frequency,
            .spread = opts.spread,
            .mode = mode,
            .animate = opts.animate,
            .duration = opts.duration,
            .speed = opts.speed,
            .dialup = opts.dialup,
            .invert = opts.invert,
            .invert_hue = opts.invert_hue,
            .passthrough = opts.passthrough_color,
            .no_space_color = opts.no_space_color,
            .enabled = enabled,
            .stdout_is_tty = stdout_is_tty,
            .seed = seed,
            .os = seed,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.pending.deinit(self.allocator);
        self.line.deinit(self.allocator);
        self.frame.deinit(self.allocator);
    }

    /// `print "\e[?25l" if opts[:animate]`
    pub fn start(self: *Renderer) !void {
        if (self.enabled and self.animate and !self.cursor_hidden) {
            try self.emit("\x1b[?25l");
            self.cursor_hidden = true;
        }
    }

    /// Stage `bytes`; the block goes out when it is full.  Ordering is
    /// preserved because every write of this renderer goes through here.
    fn emit(self: *Renderer, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes.len > emit_size) {
            try self.flushEmit();
            try self.out.writeAll(bytes);
            return;
        }
        if (self.emit_len + bytes.len > emit_size) try self.flushEmit();
        @memcpy(self.emit_buffer[self.emit_len..][0..bytes.len], bytes);
        self.emit_len += bytes.len;
    }

    fn flushEmit(self: *Renderer) !void {
        if (self.emit_len == 0) return;
        const staged = self.emit_buffer[0..self.emit_len];
        self.emit_len = 0;
        try self.out.writeAll(staged);
    }

    /// Hand everything generated so far to the file: the staging block *and*
    /// the writer's own buffer.
    ///
    /// `writeAll` only fills the writer's buffer, so without the `flush` the
    /// filter would sit on up to 64 KiB of output until the buffer filled or
    /// the input ended - a `printf 'abc'; sleep 2` would show nothing for two
    /// seconds, and a cmatrix screen (one endless line, no newline to key on)
    /// would arrive in bursts instead of frames.  One block of input is
    /// rendered and one `write` is issued per read, which is where the
    /// latency of a filter belongs: it is bounded by a single read, not by a
    /// buffer filling up.
    fn commit(self: *Renderer) !void {
        try self.flushEmit();
        try self.out.flush();
    }

    /// One iteration of the read loop: a whole block of bytes.
    pub fn feed(self: *Renderer, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.pending.appendSlice(self.allocator, bytes);

        if (!self.enabled) {
            try self.out.writeAll(self.pending.items);
            self.pending.clearRetainingCapacity();
            try self.commit();
            return;
        }

        // `buf.lines.each`: every complete line of the block, in order
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending.items, consumed, '\n')) |nl| {
            try self.emitLine(self.pending.items[consumed..nl], true);
            consumed = nl + 1;
        }
        if (consumed > 0) {
            const rest = self.pending.items.len - consumed;
            std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[consumed..]);
            self.pending.shrinkRetainingCapacity(rest);
        }

        // The tail of a block has no newline, so Ruby prints it right away -
        // unless the block ends inside an escape sequence or a code point, in
        // which case the original reads another block first.
        if (self.pending.items.len > 0 and !endsIncompleteSequence(self.pending.items)) {
            try self.emitLine(self.pending.items, false);
            self.pending.clearRetainingCapacity();
        }

        // One block of input is out before the next read: a filter has to keep
        // streaming (a pty that sends a line and waits must see it), and the
        // whole block still went to the writer as one piece.
        try self.commit();
    }

    /// End of input: whatever is left is a last line without a newline.
    pub fn finish(self: *Renderer) !void {
        if (self.enabled and self.pending.items.len > 0) {
            try self.emitLine(self.pending.items, false);
            self.pending.clearRetainingCapacity();
        }
        try self.commit();
    }

    /// The `ensure` block of `Lol.cat`.
    pub fn endCat(self: *Renderer) void {
        if (!self.enabled or self.passthrough or !self.stdout_is_tty) return;
        self.emit("\x1b[m\x1b[?25h\x1b[?1;5;2004l") catch return;
        self.commit() catch {};
    }

    /// Copy one file (or stdin) through the renderer.  `Lol.cat` resets `@os`
    /// to the seed for every file it is given, so each file starts with the
    /// same rainbow.
    pub fn runFile(self: *Renderer, file: Io.File) !void {
        self.os = self.seed;
        self.old_os = null;
        self.pending.clearRetainingCapacity();
        try self.start();
        defer self.endCat();

        var read_buffer: [chunk_size]u8 = undefined;
        var file_reader = file.readerStreaming(self.io, &read_buffer);
        var buf: [chunk_size]u8 = undefined;
        while (true) {
            const n = try self.readBlock(file, &file_reader, &buf);
            if (n == 0) break;
            try self.feed(buf[0..n]);
        }
        try self.finish();
    }

    /// One block of input: up to `buffer.len` bytes, gathered the way Ruby's
    /// `sysread(4096)` gathers them, except that it only waits `gather_ms` for
    /// the block to fill.  Returns 0 at end of input.
    ///
    /// 0 bytes come back only at end of input: at least one byte is read (that
    /// read may block as long as it likes, that is what a filter does), and
    /// only then is the rest of the block collected.
    fn readBlock(
        self: *Renderer,
        file: Io.File,
        file_reader: *Io.File.Reader,
        buffer: []u8,
    ) !usize {
        var slices = [1][]u8{buffer};
        var n = file_reader.interface.readVec(&slices) catch |err| switch (err) {
            error.EndOfStream => return 0,
            error.ReadFailed => return file_reader.err.?,
        };
        if (n == buffer.len or !gather_supported) return n;

        // Collect the rest of the block while the producer is in a burst, but
        // never longer than `gather_ms`: what is here by then is what is shown.
        const deadline = Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds +
            @as(i96, gather_ms) * std.time.ns_per_ms;
        while (n < buffer.len) {
            const now = Io.Clock.Timestamp.now(self.io, .awake).raw.nanoseconds;
            const remaining = deadline - now;
            if (remaining <= 0) break;
            const timeout_ms: i32 = @intCast(@max(1, @divTrunc(remaining, std.time.ns_per_ms)));
            var fds = [1]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&fds, timeout_ms) catch break;
            if (ready == 0) break; // nothing more is coming right now
            var more_slices = [1][]u8{buffer[n..]};
            const more = file_reader.interface.readVec(&more_slices) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return file_reader.err.?,
            };
            if (more == 0) break;
            n += more;
        }
        return n;
    }

    /// One line: `@os += 1`, tab expansion, the line itself, then the newline.
    fn emitLine(self: *Renderer, text: []const u8, had_newline: bool) !void {
        self.os += 1;

        // println: str.gsub! "\t", "        " - skipped entirely for the usual
        // line with no tab in it, which is most of them
        const body = try self.expandTabs(text);

        // `println_ani` returns early for an empty line: nothing at all is
        // printed, not even the colour+reset the plain path would emit.  The
        // newline still comes from `puts if chomped`.
        if (self.animate) {
            if (body.len > 0) try self.animateLine(body, had_newline);
        } else {
            try self.printlnPlain(body, had_newline);
        }

        if (had_newline) try self.emit("\n");
        if (self.dialup) self.randomPause();
    }

    /// `str.gsub! "\t", "        "`: eight spaces per tab, not a tab stop.
    fn expandTabs(self: *Renderer, text: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
        self.line.clearRetainingCapacity();
        var copied: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, copied, '\t')) |tab| {
            try self.line.appendSlice(self.allocator, text[copied..tab]);
            try self.line.appendNTimes(self.allocator, ' ', 8);
            copied = tab + 1;
        }
        try self.line.appendSlice(self.allocator, text[copied..]);
        return self.line.items;
    }

    /// `println_plain`: one colour, the character, one reset - per scan pair.
    fn printlnPlain(self: *Renderer, body: []const u8, had_newline: bool) !void {
        var index: usize = 0;
        var pos: usize = 0;
        // the line's colours, one rotation per character instead of three sines
        var rainbow = color.Rainbow.init(self.frequency, self.spread, self.invert_hue, self.os);
        while (true) {
            const prefix_start = pos;
            // a run of whole escape sequences; the check up front keeps the
            // common character out of the escape matcher
            if (pos < body.len and body[pos] == ansi.esc) {
                while (ansi.escapeLen(body, pos)) |n| pos += n;
            }
            const prefix = body[prefix_start..pos];

            if (pos < body.len) {
                const n = charLength(body, pos);
                const char = body[pos .. pos + n];
                pos += n;
                try self.writePair(&rainbow, prefix, char);
                index += 1;
                continue;
            }

            // End of the line: `(.?)` matched nothing.  Ruby's scan stops when
            // the match was empty, but after a *trailing escape* (a non-empty
            // prefix) it still tries once more and yields ("", "").
            try self.writePair(&rainbow, prefix, "");
            index += 1;
            if (pos == prefix_start) break;
        }

        // Ruby's `@os` bookkeeping: only a line without a newline moves `@os`
        // by its pair count over the spread, and the next line undoes it.
        if (!had_newline) {
            self.old_os = self.os;
            self.os += @as(f64, @floatFromInt(index)) / self.spread;
        } else if (self.old_os) |restore| {
            self.os = restore;
            self.old_os = null;
        }
    }

    /// One `(prefix, character)` pair: the prefix, then colour + character +
    /// reset, staged as one block.
    fn writePair(self: *Renderer, rainbow: *color.Rainbow, prefix: []const u8, char: []const u8) !void {
        if (prefix.len > 0) try self.emit(prefix);
        if (self.passthrough) {
            try self.emit(char);
            return;
        }

        const rgb = rainbow.next();

        // `--no-space-color`: a space paints no glyph, so its foreground colour
        // (and the reset after it) cannot be seen.  Everything else - the
        // per-character colour index above all - is untouched.
        if (self.no_space_color and !self.invert and char.len == 1 and char[0] == ' ') {
            try self.emit(char);
            return;
        }

        var pair: [32]u8 = undefined;
        var n = putEscape(&pair, rgb, self.mode, !self.invert);
        @memcpy(pair[n..][0..char.len], char);
        n += char.len;
        const reset = if (self.invert) "\x1b[49m" else "\x1b[39m";
        @memcpy(pair[n..][0..reset.len], reset);
        n += reset.len;
        try self.emit(pair[0..n]);
    }

    /// `println_ani`: `duration` frames of the same line, drawn in place.
    fn animateLine(self: *Renderer, body: []const u8, had_newline: bool) !void {
        try self.emit("\x1b7"); // save the cursor
        self.frame.clearRetainingCapacity();
        try self.frame.appendSlice(self.allocator, body);

        const real_os = self.os;
        var frame: u32 = 1;
        while (frame <= self.duration) : (frame += 1) {
            try self.emit("\x1b8"); // back to the start of the line
            self.os += self.spread;
            try self.printlnPlain(self.frame.items, had_newline);
            const keep = ansi.stripCursorSequences(self.frame.items);
            self.frame.shrinkRetainingCapacity(keep);
            try self.commit(); // a frame is on screen before the next one starts
            self.io.sleep(self.frameDuration(), .awake) catch {};
        }
        self.os = real_os;
    }

    fn frameDuration(self: *const Renderer) Io.Duration {
        const ns: i64 = @intFromFloat(1_000_000_000.0 / self.speed);
        return .fromNanoseconds(ns);
    }

    /// dialup mode: 30..700 ms pause after a line (extension, as in ur0/lolcat).
    fn randomPause(self: *Renderer) void {
        var rnd: [1]u8 = undefined;
        self.io.random(&rnd);
        const ms: i64 = 30 + @as(i64, @intCast(@as(u32, rnd[0]) * 670 / 255));
        self.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }
};

/// Length in bytes of the code point at `pos`; invalid UTF-8 counts as one
/// byte (Ruby would raise, we just pass it through).
fn charLength(bytes: []const u8, pos: usize) usize {
    // ASCII is one character: no decoder, no table lookup
    if (bytes[pos] < 0x80) return 1;
    const n = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch return 1;
    if (pos + n > bytes.len) return 1;
    _ = std.unicode.utf8Decode(bytes[pos .. pos + n]) catch return 1;
    return n;
}

/// Would Ruby's INCOMPLETE_ESCAPE (or its UTF-8 check) read another block?
fn endsIncompleteSequence(bytes: []const u8) bool {
    return ansi.endsIncomplete(bytes) or endsIncompleteUtf8(bytes);
}

fn endsIncompleteUtf8(bytes: []const u8) bool {
    var back: usize = 1;
    while (back <= 4 and back <= bytes.len) : (back += 1) {
        const b = bytes[bytes.len - back];
        if (b & 0xc0 == 0x80) continue; // continuation byte: keep looking
        const n = std.unicode.utf8ByteSequenceLength(b) catch return false;
        return n > back;
    }
    return false;
}

/// Decimal spelling of a byte into `buf`, returns its length.  `std.fmt` is
/// several dozen nanoseconds per character - it parses the format string, walks
/// the arguments and divides - and a cmatrix stream is ~226k characters per
/// second, so the escape is written digit by digit instead.
inline fn putDecimal(buf: []u8, v: u8) usize {
    if (v < 10) {
        buf[0] = '0' + v;
        return 1;
    }
    if (v < 100) {
        buf[0] = '0' + v / 10;
        buf[1] = '0' + v % 10;
        return 2;
    }
    buf[0] = '0' + v / 100;
    buf[1] = '0' + (v / 10) % 10;
    buf[2] = '0' + v % 10;
    return 3;
}

/// `Paint.color(...)`: `\e[38;2;r;g;bm` / `\e[38;5;Nm`, and the `48` variants
/// when the colour is a background.  Writes into `buf` and returns the length
/// (19 bytes at most).
fn putEscape(buf: *[32]u8, rgb: color.Rgb, mode: color.Mode, foreground: bool) usize {
    const intro: []const u8 = switch (mode) {
        .truecolor => if (foreground) "\x1b[38;2;" else "\x1b[48;2;",
        .ansi256 => if (foreground) "\x1b[38;5;" else "\x1b[48;5;",
    };
    @memcpy(buf[0..intro.len], intro);
    var n = intro.len;
    switch (mode) {
        .truecolor => {
            for ([3]u8{ rgb.r, rgb.g, rgb.b }, 0..) |channel, k| {
                if (k != 0) {
                    buf[n] = ';';
                    n += 1;
                }
                n += putDecimal(buf[n..], channel);
            }
        },
        .ansi256 => {
            n += putDecimal(buf[n..], color.quantize256(rgb));
        },
    }
    buf[n] = 'm';
    return n + 1;
}

const testing = std.testing;

/// Build the byte sequence lolcat would print, pair by pair.
const Expected = struct {
    list: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    mode: color.Mode = .truecolor,
    frequency: f64 = 0.1,

    fn deinit(self: *Expected) void {
        self.list.deinit(self.allocator);
    }

    fn add(self: *Expected, text: []const u8) !void {
        try self.list.appendSlice(self.allocator, text);
    }

    /// `prefix`, colour, `char`, reset
    fn pair(self: *Expected, prefix: []const u8, char: []const u8, i: f64) !void {
        try self.add(prefix);
        const rgb = color.rgbAt(i, self.frequency, false);
        var buf: [32]u8 = undefined;
        const escape = switch (self.mode) {
            .truecolor => try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            .ansi256 => try std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{color.quantize256(rgb)}),
        };
        try self.add(escape);
        try self.add(char);
        try self.add("\x1b[39m");
    }

    fn backgroundPair(self: *Expected, char: []const u8, i: f64) !void {
        const rgb = color.rgbAt(i, self.frequency, false);
        var buf: [32]u8 = undefined;
        const escape = switch (self.mode) {
            .truecolor => try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            .ansi256 => try std.fmt.bufPrint(&buf, "\x1b[48;5;{d}m", .{color.quantize256(rgb)}),
        };
        try self.add(escape);
        try self.add(char);
        try self.add("\x1b[49m");
    }
};

const defaults = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1 };

fn renderAll(
    allocator: std.mem.Allocator,
    opts: cli.Options,
    mode: color.Mode,
    seed: f64,
    input: []const u8,
) ![]u8 {
    var allocating: Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, allocator, opts, mode, seed, true, false);
    defer r.deinit();
    try r.feed(input);
    try r.finish();
    return allocating.toOwnedSlice();
}

test "every character is painted, spaces included, and closed with \\e[39m" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "a b\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0); // @os starts at the seed and is bumped once per line
    try e.pair("", " ", 1.0 + 1.0 / 3.0);
    try e.pair("", "b", 1.0 + 2.0 / 3.0);
    try e.pair("", "", 1.0 + 3.0 / 3.0); // Ruby's scan yields the trailing empty match
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\x1b[39m"));
    // the space is painted like the letters
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\x1b[38;2;"));
}

test "colours the input already set are overridden" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "\x1b[31mAB\x1b[0mC\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("\x1b[31m", "A", 1.0);
    try e.pair("", "B", 1.0 + 1.0 / 3.0);
    try e.pair("\x1b[0m", "C", 1.0 + 2.0 / 3.0);
    try e.pair("", "", 2.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    // the input's red is copied immediately before our own colour, so ours wins
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[31m\x1b[38;2;") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[31m"));
}

test "a tab becomes eight painted spaces" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "a\tb\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    var i: f64 = 0;
    try e.pair("", "a", 1.0);
    i = 1;
    while (i < 9) : (i += 1) try e.pair("", " ", 1.0 + i / 3.0);
    try e.pair("", "b", 1.0 + 9.0 / 3.0);
    try e.pair("", "", 1.0 + 10.0 / 3.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    try testing.expectEqual(@as(usize, 11), std.mem.count(u8, out, "\x1b[39m"));
    try testing.expect(std.mem.indexOfScalar(u8, out, '\t') == null);
}

test "@os advances by one per line, the index inside a line by 1/spread" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "ab\ncd\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.pair("", "b", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 1.0 + 2.0 / 3.0);
    try e.add("\n");
    try e.pair("", "c", 2.0); // the second line starts exactly one further
    try e.pair("", "d", 2.0 + 1.0 / 3.0);
    try e.pair("", "", 2.0 + 2.0 / 3.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
}

test "a line without a newline adds its pair count/spread and the next line undoes it" {
    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, testing.allocator, defaults, .truecolor, 0, true, false);
    defer r.deinit();

    // a block that ends in the middle of a line: "ab" is printed without a
    // newline, so Ruby bumps @os by filtered.length/spread (3/3 = 1) ...
    try r.feed("ab");
    // ... and the next block's first line restores @os through @old_os.
    try r.feed("cd\nef\n");
    const out = try allocating.toOwnedSlice();
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.pair("", "b", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 1.0 + 2.0 / 3.0);
    try e.pair("", "c", 3.0); // 2 (bumped) + 1, and no restore yet
    try e.pair("", "d", 3.0 + 1.0 / 3.0);
    try e.pair("", "", 3.0 + 2.0 / 3.0);
    try e.add("\n");
    try e.pair("", "e", 2.0); // restored: 1 + 1
    try e.pair("", "f", 2.0 + 1.0 / 3.0);
    try e.pair("", "", 2.0 + 2.0 / 3.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
}

test "an empty line still prints one colour and one reset" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "", 1.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "escape prefixes are copied verbatim and consume no colour" {
    // an OSC title (BEL is a character, as in the Ruby regex), then an SGR
    const input = "\x1b]0;title\x07y\x1b[1m\n";
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, input);
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("\x1b]0;title", "\x07", 1.0);
    try e.pair("", "y", 1.0 + 1.0 / 3.0);
    try e.pair("\x1b[1m", "", 1.0 + 2.0 / 3.0);
    try e.pair("", "", 1.0 + 3.0 / 3.0); // Ruby's scan still yields the empty tail
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]0;title"));
}

test "multi byte characters are one character, not one colour per byte" {
    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, "中文\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "中", 1.0);
    try e.pair("", "文", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 1.0 + 2.0 / 3.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "-i paints the background and closes with \\e[49m" {
    const opts = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1, .invert = true };
    const out = try renderAll(testing.allocator, opts, .truecolor, 0, "a\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.backgroundPair("a", 1.0);
    try e.backgroundPair("", 1.0 + 1.0 / 3.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b[38;"));
}

test "256 colour mode uses one escape per character too" {
    const out = try renderAll(testing.allocator, defaults, .ansi256, 0, "ab\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator, .mode = .ansi256 };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.pair("", "b", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 2.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "-a redraws a line in place, one frame per duration" {
    const opts = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1, .animate = true, .duration = 2, .speed = 1_000_000.0 };
    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, testing.allocator, opts, .truecolor, 0, true, false);
    defer r.deinit();
    try r.start();
    try r.feed("a\n");
    try r.finish();
    const out = try allocating.toOwnedSlice();
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.add("\x1b[?25l"); // cursor hidden once, up front
    try e.add("\x1b7");
    try e.add("\x1b8");
    try e.pair("", "a", 1.0 + 3.0); // @os += spread per frame
    try e.pair("", "", 4.0 + 1.0 / 3.0);
    try e.add("\x1b8");
    try e.pair("", "a", 7.0);
    try e.pair("", "", 7.0 + 1.0 / 3.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\x1b8"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b7"));
}

test "-a leaves empty lines alone (and still prints their newline)" {
    const opts = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1, .animate = true, .duration = 3, .speed = 1_000_000.0 };
    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, testing.allocator, opts, .truecolor, 0, true, false);
    defer r.deinit();
    try r.start();
    try r.feed("\n\n");
    try r.finish();
    const out = try allocating.toOwnedSlice();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[?25l\n\n", out);
}

test "the closing sequence is only sent to a terminal" {
    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();

    var tty_renderer = Renderer.init(&allocating.writer, testing.io, testing.allocator, defaults, .truecolor, 0, true, true);
    defer tty_renderer.deinit();
    tty_renderer.endCat();
    const tty_out = try allocating.toOwnedSlice();
    defer testing.allocator.free(tty_out);
    try testing.expectEqualStrings("\x1b[m\x1b[?25h\x1b[?1;5;2004l", tty_out);

    var pipe_allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer pipe_allocating.deinit();
    var pipe_renderer = Renderer.init(&pipe_allocating.writer, testing.io, testing.allocator, defaults, .truecolor, 0, true, false);
    defer pipe_renderer.deinit();
    pipe_renderer.endCat();
    const pipe_out = try pipe_allocating.toOwnedSlice();
    defer testing.allocator.free(pipe_out);
    try testing.expectEqualStrings("", pipe_out);
}

test "an incomplete escape at the end of a block waits for the rest" {
    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, testing.allocator, defaults, .truecolor, 0, true, false);
    defer r.deinit();

    // Ruby re-reads while INCOMPLETE_ESCAPE matches, so nothing is printed yet
    try r.feed("a\x1b[3");
    try testing.expectEqual(@as(usize, 0), allocating.written().len);

    try r.feed("1mB\n");
    const out = try allocating.toOwnedSlice();
    defer testing.allocator.free(out);
    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.pair("\x1b[31m", "B", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 1.0 + 2.0 / 3.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "--no-space-color drops the escapes around a space and nothing else" {
    const opts = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1, .no_space_color = true };
    const out = try renderAll(testing.allocator, opts, .truecolor, 0, "a b\tc\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.add(" "); // pair 1: a plain space, no colour in front of it
    try e.pair("", "b", 1.0 + 2.0 / 3.0);
    var k: f64 = 3; // the tab's eight spaces, none of them coloured
    while (k < 11) : (k += 1) try e.add(" ");
    try e.pair("", "c", 1.0 + 11.0 / 3.0);
    // the trailing empty pair is always painted, space or not
    try e.pair("", "", 1.0 + 12.0 / 3.0);
    try e.add("\n");

    try testing.expectEqualStrings(e.list.items, out);
    // a, b, c and the trailing empty pair - the eight tab spaces contribute none
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\x1b[38;2;"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\x1b[39m"));
    // the text a terminal shows is unchanged
    const shown = try stripEscapes(out, testing.allocator);
    defer testing.allocator.free(shown);
    try testing.expectEqualStrings("a b        c\n", shown);
}

test "--no-space-color keeps the background of a space when -i paints it" {
    const opts = cli.Options{ .seed = 0, .spread = 3.0, .frequency = 0.1, .no_space_color = true, .invert = true };
    const out = try renderAll(testing.allocator, opts, .truecolor, 0, "a b\n");
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.backgroundPair("a", 1.0);
    try e.backgroundPair(" ", 1.0 + 1.0 / 3.0); // a space has a visible background
    try e.backgroundPair("b", 1.0 + 2.0 / 3.0);
    try e.backgroundPair("", 2.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "a line much longer than the staging block comes out whole" {
    // 4000 characters are ~100 KiB of output, so the 32 KiB block is flushed
    // several times in the middle of the line
    const input = try testing.allocator.alloc(u8, 4001);
    defer testing.allocator.free(input);
    @memset(input[0..4000], 'x');
    input[4000] = '\n';

    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, input);
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    for (0..4000) |k| try e.pair("", "x", 1.0 + @as(f64, @floatFromInt(k)) / 3.0);
    try e.pair("", "", 1.0 + 4000.0 / 3.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

test "an escape prefix longer than the staging block is still copied in order" {
    // an OSC title that does not fit in the 32 KiB block: the prefix has to go
    // out on its own, before the colour pair that follows it
    const title_len = 40 * 1024;
    const input = try testing.allocator.alloc(u8, title_len + 8);
    defer testing.allocator.free(input);
    @memcpy(input[0..4], "\x1b]0;");
    @memset(input[4 .. 4 + title_len], 't');
    input[4 + title_len] = 0x07;
    input[5 + title_len] = 'x';
    input[6 + title_len] = '\n';
    const line = input[0 .. 7 + title_len];

    const out = try renderAll(testing.allocator, defaults, .truecolor, 0, line);
    defer testing.allocator.free(out);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair(line[0 .. 4 + title_len], "\x07", 1.0);
    try e.pair("", "x", 1.0 + 1.0 / 3.0);
    try e.pair("", "", 1.0 + 2.0 / 3.0);
    try e.add("\n");
    try testing.expectEqualStrings(e.list.items, out);
}

/// Everything that is not an escape sequence: what a terminal would show.
fn stripEscapes(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (bytes[pos] == ansi.esc) {
            if (ansi.escapeLen(bytes, pos)) |n| {
                pos += n;
                continue;
            }
        }
        try list.append(allocator, bytes[pos]);
        pos += 1;
    }
    return list.toOwnedSlice(allocator);
}

/// Read a file back from disk, the way a consumer on the other end of the pipe
/// would see it.
fn slurp(io: Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [chunk_size]u8 = undefined;
    var file_reader = file.readerStreaming(io, &read_buffer);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [chunk_size]u8 = undefined;
    while (true) {
        const n = file_reader.interface.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
        };
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

test "a block is flushed to the file at the end of the read, not at the end of the input" {
    // the latency a filter owes its consumer: what one `read` produced is out
    // before the next one is asked for.  The 64 KiB file writer hiding it until
    // EOF was the bug this test exists for.
    const path = "/tmp/zlolcat-flush-test.txt";
    var file = try Io.Dir.cwd().createFile(testing.io, path, .{});
    defer Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    defer file.close(testing.io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(testing.io, &write_buffer);
    var r = Renderer.init(&file_writer.interface, testing.io, testing.allocator, defaults, .truecolor, 0, true, false);
    defer r.deinit();

    // "abc" arrives on its own - a `printf 'abc'; sleep 2` with the pipe still
    // open - and must be visible without `finish()` ever running
    try r.feed("abc");

    const seen = try slurp(testing.io, testing.allocator, path);
    defer testing.allocator.free(seen);

    var e = Expected{ .allocator = testing.allocator };
    defer e.deinit();
    try e.pair("", "a", 1.0);
    try e.pair("", "b", 1.0 + 1.0 / 3.0);
    try e.pair("", "c", 1.0 + 2.0 / 3.0);
    try e.pair("", "", 2.0);
    try testing.expectEqualStrings(e.list.items, seen);
    try testing.expect(seen.len > 0);
}

test "a block is a full 4096 bytes until the tail of the input" {
    // the gathering rule: a block is filled while the input is there, and the
    // last block is short.  This is also where `readBlock` has to report end of
    // input, which the renderer relies on to stop.
    const path = "/tmp/zlolcat-block-test.txt";
    {
        const file = try Io.Dir.cwd().createFile(testing.io, path, .{});
        defer file.close(testing.io);
        const text = try testing.allocator.alloc(u8, 10_000);
        defer testing.allocator.free(text);
        @memset(text, 'x');
        var write_buffer: [chunk_size]u8 = undefined;
        var file_writer = file.writer(testing.io, &write_buffer);
        try file_writer.interface.writeAll(text);
        try file_writer.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    const file = try Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);

    var allocating: Io.Writer.Allocating = .init(testing.allocator);
    defer allocating.deinit();
    var r = Renderer.init(&allocating.writer, testing.io, testing.allocator, defaults, .truecolor, 0, true, false);
    defer r.deinit();

    var read_buffer: [chunk_size]u8 = undefined;
    var file_reader = file.readerStreaming(testing.io, &read_buffer);
    var buf: [chunk_size]u8 = undefined;
    var sizes: [8]usize = undefined;
    var n_sizes: usize = 0;
    while (n_sizes < sizes.len) {
        const n = try r.readBlock(file, &file_reader, &buf);
        sizes[n_sizes] = n;
        n_sizes += 1;
        if (n == 0) break;
    }
    try testing.expectEqual(@as(usize, 4), n_sizes);
    try testing.expectEqual(@as(usize, chunk_size), sizes[0]);
    try testing.expectEqual(@as(usize, chunk_size), sizes[1]);
    try testing.expectEqual(@as(usize, 10_000 - 2 * chunk_size), sizes[2]);
    try testing.expectEqual(@as(usize, 0), sizes[3]);
}
