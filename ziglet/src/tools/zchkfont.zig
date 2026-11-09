//! zchkfont - check FIGlet font files for format errors.
//!
//! The checks follow the original chkfont program: header fields, comment
//! lines, the 95 ASCII + 7 German FIGcharacters, per-character row widths and
//! endmarks, and the optional code-tagged characters. Every diagnostic names
//! the line it refers to. Compressed containers are not inspected.

const std = @import("std");
const Io = std.Io;
const textfig = @import("textfig");
const font = textfig.font;

pub const name = "zchkfont";

pub const version_text =
    \\zchkfont 1.0.0 - check FIGlet font files for format errors
    \\
;

pub const help_text =
    \\Usage: zchkfont fontfile ...
    \\
    \\zchkfont checks FIGlet/TOIlet font files for format errors. It reads the
    \\header, the 95 ASCII and 7 German FIGcharacters and any code-tagged
    \\characters, and reports inconsistent row widths, wrong or missing
    \\endmarks, truncation and suspicious header values. Font files are never
    \\modified.
    \\
    \\A successful file is summarised as:
    \\  font.flf: OK - 2238 lines, height 6, 331 characters, direction left-to-right
    \\
    \\Every error includes its line number. Any error makes zchkfont exit 1;
    \\warnings do not change the exit status. "-" reads a font from standard
    \\input. Gzip and zip containers must be decompressed first.
    \\
    \\  -h, --help         Display this help and exit.
    \\  -v, --version      Display version information and exit.
    \\
;

const Options = struct {
    help: bool = false,
    version: bool = false,
    files: std.ArrayList([]const u8) = .empty,
};

const Error = error{ InvalidArgs, OutOfMemory };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn invalid(errw: *Io.Writer, comptime fmt: []const u8, args: anytype) Error {
    errw.print("{s}: " ++ fmt ++ "\n", .{name} ++ args) catch {};
    return error.InvalidArgs;
}

fn parse(a: std.mem.Allocator, argv: []const [:0]const u8, errw: *Io.Writer) Error!Options {
    var opts = Options{};
    var only_operands = false;
    var i: usize = 1;

    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (only_operands) {
            try opts.files.append(a, arg);
            continue;
        }
        if (eq(arg, "--")) {
            only_operands = true;
            continue;
        }
        if (arg.len > 2 and std.mem.startsWith(u8, arg, "--")) {
            if (eq(arg, "--help")) {
                opts.help = true;
            } else if (eq(arg, "--version")) {
                opts.version = true;
            } else {
                return invalid(errw, "invalid option '{s}'", .{arg});
            }
            continue;
        }
        if (arg.len >= 2 and arg[0] == '-') {
            if (eq(arg, "-h")) {
                opts.help = true;
            } else if (eq(arg, "-v")) {
                opts.version = true;
            } else {
                return invalid(errw, "invalid option '{s}'", .{arg});
            }
            continue;
        }
        try opts.files.append(a, arg);
    }

    return opts;
}

const LineIter = struct {
    data: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        const nl = std.mem.indexOfScalarPos(u8, self.data, start, '\n');
        const end = nl orelse self.data.len;
        self.pos = if (nl) |p| p + 1 else self.data.len;
        self.line_no += 1;
        var line = self.data[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }

    fn peek(self: *LineIter) ?[]const u8 {
        const save_pos = self.pos;
        const save_line = self.line_no;
        const line = self.next();
        self.pos = save_pos;
        self.line_no = save_line;
        return line;
    }
};

fn headerFieldCount(line: []const u8) usize {
    if (line.len < 6) return 0;
    const hb_len = std.unicode.utf8ByteSequenceLength(line[5]) catch 1;
    const start = @min(5 + @as(usize, hb_len), line.len);
    var it = std.mem.tokenizeAny(u8, line[start..], " \t");
    var count: usize = 0;
    while (it.next() != null) count += 1;
    return count;
}

fn plausibleHardblank(c: u21) bool {
    return c == '!' or c == '@' or c == '#' or c == '$' or
        c == '%' or c == '&' or c == '*' or c == 0x7f;
}

fn parseCode(token: []const u8) ?i64 {
    if (token.len == 0) return null;
    var s = token;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        s = s[1..];
        if (s.len == 0) return null;
    }
    var base: u8 = 10;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        base = 16;
        s = s[2..];
    } else if (s.len >= 2 and s[0] == '0') {
        base = 8;
        s = s[1..];
    }
    if (s.len == 0) return null;
    const v = std.fmt.parseInt(i64, s, base) catch return null;
    return if (neg) -v else v;
}

fn directionName(d: font.Direction) []const u8 {
    return switch (d) {
        .ltr => "left-to-right",
        .rtl => "right-to-left",
    };
}

const Checker = struct {
    out: *Io.Writer,
    path: []const u8,
    lines: LineIter,
    header: ?font.Header = null,
    errors: usize = 0,
    warnings: usize = 0,
    suppressed: usize = 0,
    char_count: usize = 0,
    extra_count: usize = 0,

    blank_endmark_warned: bool = false,
    incon_endmark_warned: bool = false,
    endmark_count_warned: bool = false,
    big_code_warned: bool = false,
    deutsch_code_warned: bool = false,
    ascii_code_warned: bool = false,
    non_increasing_warned: bool = false,

    const max_reports = 20;

    fn errAt(self: *Checker, line_no: usize, comptime fmt: []const u8, args: anytype) void {
        const index = self.errors + self.warnings;
        self.errors += 1;
        if (index >= max_reports) {
            self.suppressed += 1;
            return;
        }
        self.out.print("{s}: line {d}: error: " ++ fmt ++ "\n", .{ self.path, line_no } ++ args) catch {};
    }

    fn warnAt(self: *Checker, line_no: usize, comptime fmt: []const u8, args: anytype) void {
        const index = self.errors + self.warnings;
        self.warnings += 1;
        if (index >= max_reports) {
            self.suppressed += 1;
            return;
        }
        self.out.print("{s}: line {d}: warning: " ++ fmt ++ "\n", .{ self.path, line_no } ++ args) catch {};
    }

    fn err(self: *Checker, comptime fmt: []const u8, args: anytype) void {
        self.errAt(self.lines.line_no, fmt, args);
    }

    fn warn(self: *Checker, comptime fmt: []const u8, args: anytype) void {
        self.warnAt(self.lines.line_no, fmt, args);
    }

    fn check(self: *Checker) void {
        const first = self.lines.next() orelse {
            self.errAt(1, "empty file", .{});
            return;
        };

        var diag: font.Diag = .{};
        const h = font.parseHeader(first, &diag) catch {
            self.errAt(1, "{s}", .{diag.text()});
            return;
        };
        self.header = h;

        if (h.max_length > 255) {
            self.errAt(1, "max length {d} exceeds 255", .{h.max_length});
        }
        if (!plausibleHardblank(h.hardblank)) {
            self.warnAt(1, "unusual hardblank U+{X}", .{h.hardblank});
        }
        if (h.full_layout) |layout| {
            if (h.old_layout == -1 and (layout & 192) != 0) {
                self.errAt(1, "full layout {d} is inconsistent with old layout -1", .{layout});
            }
            if (h.old_layout == 0 and (layout & 192) != 64 and (layout & 255) != 128) {
                self.errAt(1, "full layout {d} is inconsistent with old layout 0", .{layout});
            }
            if (h.old_layout > 0 and
                ((layout & 128) == 0 or @as(u32, @intCast(h.old_layout)) != (layout & 63)))
            {
                self.errAt(1, "full layout {d} is inconsistent with old layout {d}", .{ layout, h.old_layout });
            }
        }

        var ci: usize = 0;
        while (ci < h.comment_lines) : (ci += 1) {
            if (self.lines.next() == null) {
                self.err("file ends inside its {d} comment lines (found {d})", .{ h.comment_lines, ci });
                return;
            }
        }

        for (0..102) |gi| {
            var what_buf: [32]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "character {d}", .{gi + 1}) catch "character";
            self.char_count += 1;
            if (!self.readGlyph(what)) return;
        }

        const has_codetag_count = headerFieldCount(first) >= 8;
        var codetag_count: usize = 0;
        var old_ord: i64 = 0;

        while (self.lines.peek()) |peeked| {
            const trimmed = std.mem.trim(u8, peeked, " \t\r");
            if (trimmed.len == 0) {
                _ = self.lines.next();
                continue;
            }

            // The code line is consumed before its glyph rows so diagnostics
            // for the code itself can point at the right line.
            var end: usize = 0;
            while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') end += 1;
            const code = parseCode(trimmed[0..end]);
            if (code == null) {
                _ = self.lines.next();
                self.warn("extra text after the font: \"{s}\"", .{trimmed});
                break;
            }
            _ = self.lines.next();
            const code_line = self.lines.line_no;
            const the_ord = code.?;
            codetag_count += 1;
            self.extra_count += 1;

            if (the_ord == -1) {
                self.errAt(code_line, "code tag -1 is unusable", .{});
                break;
            }
            if (the_ord > 65535 and !self.big_code_warned) {
                self.warnAt(code_line, "code tag {d} is above 65535", .{the_ord});
                self.big_code_warned = true;
            }
            if (the_ord > 0x10FFFF) {
                self.errAt(code_line, "code tag {d} is outside the Unicode range", .{the_ord});
            }
            if (the_ord >= -255 and the_ord <= -249 and !self.deutsch_code_warned) {
                self.warnAt(code_line, "code tag {d} is in the old Deutsch area", .{the_ord});
                self.deutsch_code_warned = true;
            }
            if (the_ord > 31 and the_ord < 127) {
                if (!self.ascii_code_warned) {
                    self.warnAt(code_line, "code tag {d} is in the ASCII range", .{the_ord});
                    self.ascii_code_warned = true;
                }
            } else if (the_ord <= old_ord and the_ord >= 0 and old_ord >= 0 and !self.non_increasing_warned) {
                self.warnAt(code_line, "code tag {d} does not increase (previous was {d})", .{ the_ord, old_ord });
                self.non_increasing_warned = true;
            }
            old_ord = the_ord;

            var what_buf: [64]u8 = undefined;
            const what = if (the_ord >= 0 and the_ord <= 0x10FFFF)
                std.fmt.bufPrint(&what_buf, "glyph U+{X:0>4}", .{@as(u21, @intCast(the_ord))}) catch "code-tagged glyph"
            else
                std.fmt.bufPrint(&what_buf, "code-tagged glyph {d}", .{the_ord}) catch "code-tagged glyph";
            self.char_count += 1;
            if (!self.readGlyph(what)) return;
        }

        if (has_codetag_count and codetag_count != h.codetag_count) {
            // Missing code-tagged characters break the advertised character
            // set; extra ones (several shipped fonts, including standard.flf,
            // carry a stale count) are harmless metadata drift.
            if (codetag_count < h.codetag_count) {
                self.errAt(1, "Codetag_Cnt value {d} promises that many code-tagged characters, found {d}", .{
                    h.codetag_count,
                    codetag_count,
                });
            } else {
                self.warnAt(1, "Codetag_Cnt value {d} does not match {d} code-tagged characters", .{
                    h.codetag_count,
                    codetag_count,
                });
            }
        }
    }

    fn readGlyph(self: *Checker, what: []const u8) bool {
        const h = self.header.?;
        var expected_width: ?usize = null;
        var expected_endmark: ?u8 = null;
        var y: usize = 0;

        while (y < h.height) : (y += 1) {
            const line = self.lines.next() orelse {
                self.err("unexpected end of file in {s}: expected {d} rows, found {d}", .{
                    what,
                    h.height,
                    y,
                });
                return false;
            };

            if (line.len > h.max_length) {
                self.err("line length {d} exceeds max length {d}", .{ line.len, h.max_length });
            }

            var content_len = line.len;
            var endmark: u8 = 0;
            var trailing: usize = 0;
            if (line.len > 0) {
                endmark = line[line.len - 1];
                while (content_len > 0 and line[content_len - 1] == endmark) {
                    content_len -= 1;
                    trailing += 1;
                }
            }

            if (y == 0) {
                expected_width = content_len;
                expected_endmark = endmark;
                if (endmark == ' ' and !self.blank_endmark_warned) {
                    self.warn("blank endmark", .{});
                    self.blank_endmark_warned = true;
                }
            } else {
                if (endmark != expected_endmark.? and !self.incon_endmark_warned) {
                    self.warn("inconsistent endmark (0x{X}); the first row used 0x{X}", .{
                        endmark,
                        expected_endmark.?,
                    });
                    self.incon_endmark_warned = true;
                }
                if (content_len != expected_width.?) {
                    self.err("inconsistent character width (expected {d} cells, found {d})", .{
                        expected_width.?,
                        content_len,
                    });
                }
            }

            if (h.height > 1) {
                const want: usize = if (y == h.height - 1) 2 else 1;
                if (trailing != want and !self.endmark_count_warned) {
                    self.warn("endchar count convention violated ({d} endmark(s), expected {d})", .{
                        trailing,
                        want,
                    });
                    self.endmark_count_warned = true;
                }
            }
        }

        return true;
    }

    fn report(self: *Checker) !void {
        const direction = if (self.header) |h| directionName(h.print_dir) else "unknown";
        if (self.errors == 0) {
            if (self.header) |h| {
                try self.out.print(
                    "{s}: OK - {d} lines, height {d}, {d} characters",
                    .{ self.path, self.lines.line_no, h.height, self.char_count },
                );
                if (self.extra_count > 0) {
                    try self.out.print(" ({d} code-tagged)", .{self.extra_count});
                }
                try self.out.print(", direction {s}", .{direction});
                if (self.warnings > 0) {
                    try self.out.print(" ({d} warning(s))", .{self.warnings});
                }
                try self.out.writeByte('\n');
            } else {
                try self.out.print("{s}: OK - {d} lines\n", .{ self.path, self.lines.line_no });
            }
            return;
        }

        try self.out.print("{s}: FAILED - {d} error(s), {d} warning(s); {d} lines", .{
            self.path,
            self.errors,
            self.warnings,
            self.lines.line_no,
        });
        if (self.header) |h| {
            try self.out.print(", height {d}, {d} characters, direction {s}", .{
                h.height,
                self.char_count,
                direction,
            });
        }
        if (self.suppressed > 0) {
            try self.out.print(" ({d} more problem(s) not shown)", .{self.suppressed});
        }
        try self.out.writeByte('\n');
    }
};

fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

fn isZip(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
}

fn checkBytes(out: *Io.Writer, path: []const u8, bytes: []const u8) !bool {
    if (isGzip(bytes)) {
        try out.print("{s}: error: gzip-compressed font; decompress it before checking\n", .{path});
        return false;
    }
    if (isZip(bytes)) {
        try out.print("{s}: error: zip-compressed font; decompress it before checking\n", .{path});
        return false;
    }

    var checker = Checker{ .out = out, .path = path, .lines = .{ .data = bytes } };
    checker.check();
    try checker.report();
    return checker.errors == 0;
}

fn checkPath(
    io: Io,
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    errw: *Io.Writer,
    path: []const u8,
) !bool {
    if (eq(path, "-")) {
        var buf: [64 * 1024]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(io, &buf);
        const bytes = reader.interface.allocRemaining(gpa, .limited(font.max_font_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try errw.print("zchkfont: cannot read standard input: {t}\n", .{err});
                return false;
            },
        };
        defer gpa.free(bytes);
        return checkBytes(out, "(stdin)", bytes);
    }

    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(font.max_font_bytes)) catch |err| {
        try errw.print("zchkfont: cannot read \"{s}\": {t}\n", .{ path, err });
        return false;
    };
    defer gpa.free(bytes);
    return checkBytes(out, path, bytes);
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.WriteFailed => std.process.exit(1),
        error.Reported => std.process.exit(1),
        else => {
            std.debug.print("zchkfont: {t}\n", .{err});
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var out_buf: [64 * 1024]u8 = undefined;
    var out_file = Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;

    var err_buf: [16 * 1024]u8 = undefined;
    var err_file = Io.File.stderr().writer(io, &err_buf);
    const errw = &err_file.interface;

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const opts = parse(arena, argv, errw) catch |err| switch (err) {
        error.InvalidArgs => {
            try errw.writeAll("Try 'zchkfont --help' for more information.\n");
            try errw.flush();
            return error.Reported;
        },
        else => return err,
    };

    if (opts.help) {
        try out.writeAll(help_text);
        try out.flush();
        return;
    }
    if (opts.version) {
        try out.writeAll(version_text);
        try out.flush();
        return;
    }

    if (opts.files.items.len == 0) {
        try errw.print("{s}: no font file given\nUsage: zchkfont fontfile ...\n", .{name});
        try errw.flush();
        return error.Reported;
    }

    var any_failed = false;
    for (opts.files.items) |path| {
        const ok = checkPath(io, gpa, out, errw, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        if (!ok) any_failed = true;
    }

    try errw.flush();
    try out.flush();
    if (any_failed) return error.Reported;
}

const testing = std.testing;

fn buildMinimalFont(
    a: std.mem.Allocator,
    height: usize,
    row_count: usize,
    bad_row: ?usize,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "flf2a$ {d} {d} 10 0 0\n", .{ height, height });
    try bytes.appendSlice(a, header);
    for (0..row_count) |i| {
        if (bad_row != null and i == bad_row.?) {
            try bytes.appendSlice(a, "x@@\n");
        } else {
            try bytes.appendSlice(a, "@@\n");
        }
    }
    return bytes.toOwnedSlice(a);
}

test "zchkfont accepts a complete minimal font and reports its stats" {
    const a = testing.allocator;
    const bytes = try buildMinimalFont(a, 1, 102, null);
    defer a.free(bytes);

    var buf: [64 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try testing.expect(try checkBytes(&w, "minimal.flf", bytes));

    const text = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, text, "OK - 103 lines, height 1, 102 characters") != null);
    try testing.expect(std.mem.indexOf(u8, text, "direction left-to-right") != null);
}

test "zchkfont rejects an inconsistent row width and names the line" {
    const a = testing.allocator;
    // Height 2, and the second row of the first character is wider than its
    // first row: line 1 is the header, so the bad row is line 3.
    const bytes = try buildMinimalFont(a, 2, 204, 1);
    defer a.free(bytes);

    var buf: [64 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try testing.expect(!try checkBytes(&w, "bad.flf", bytes));

    const text = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, text, "line 3: error: inconsistent character width") != null);
    try testing.expect(std.mem.indexOf(u8, text, "FAILED - 1 error(s)") != null);
}

test "zchkfont reports a truncated character block" {
    const a = testing.allocator;
    const bytes = try buildMinimalFont(a, 1, 101, null);
    defer a.free(bytes);

    var buf: [64 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    try testing.expect(!try checkBytes(&w, "short.flf", bytes));

    const text = buf[0..w.end];
    try testing.expect(std.mem.indexOf(u8, text, "unexpected end of file in character 102") != null);
    try testing.expect(std.mem.indexOf(u8, text, "expected 1 rows, found 0") != null);
}
