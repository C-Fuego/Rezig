//! FIGfont (`.flf`) and TOIlet font (`.tlf`) parsing, glyph lookup, font
//! search paths and font-directory listing.
//!
//! The parser follows figlet 2.2.5's `readfont()` / `readfontchar()`:
//!   * header `flf2a$ height baseline maxlen oldlayout commentlines
//!     [printdir] [fulllayout] [codetagcount]`;
//!   * `commentlines` comment lines are skipped;
//!   * 95 printable ASCII glyphs, then the seven German glyphs in the order
//!     A-diaeresis, O-diaeresis, U-diaeresis, a-diaeresis, o-diaeresis,
//!     u-diaeresis, sharp-s;
//!   * each glyph line has its trailing whitespace removed and then the
//!     trailing run of one endmark character removed (normally one `@`, two on
//!     the last row);
//!   * optional code-tagged glyphs follow, each introduced by a decimal,
//!     octal (`0755`) or hex (`0x4E2D`) character code.
//!
//! `.tlf` files use exactly the same structure but glyph rows are UTF-8 text,
//! so a glyph's width is a count of codepoints. A hardblank is a codepoint,
//! not a byte.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const compressed = @import("compressed.zig");

// Horizontal layout bits, identical to figlet's smushmode. They are defined
// here because they describe a font's header; render.zig applies them.
pub const SM_EQUAL = 1;
pub const SM_LOWLINE = 2;
pub const SM_HIERARCHY = 4;
pub const SM_PAIR = 8;
pub const SM_BIGX = 16;
pub const SM_HARDBLANK = 32;
pub const SM_KERN = 64;
pub const SM_SMUSH = 128;

pub const Format = enum { flf, tlf };

pub const Direction = enum {
    ltr,
    rtl,

    pub fn defaultJustify(self: Direction) Justify {
        return if (self == .rtl) .right else .left;
    }
};

pub const Justify = enum { left, center, right };

pub const Glyph = struct {
    /// One entry per font row. Rows may be shorter than `width`; the missing
    /// cells are blanks. Hardblanks are preserved as codepoints.
    rows: []const []const u21,
    width: usize,

    pub fn cell(self: Glyph, y: usize, x: usize) u21 {
        if (y >= self.rows.len) return ' ';
        const row = self.rows[y];
        return if (x < row.len) row[x] else ' ';
    }
};

pub const Header = struct {
    format: Format,
    hardblank: u21,
    height: usize,
    baseline: usize,
    max_length: usize,
    old_layout: i32,
    comment_lines: usize,
    print_dir: Direction = .ltr,
    full_layout: ?u32 = null,
    codetag_count: usize = 0,

    /// figlet's interpretation of the two layout fields.
    ///
    /// When Full_Layout is present figlet uses it verbatim (the horizontal
    /// bits are the low byte). Otherwise:
    ///   old == 0  -> kerning
    ///   old <  0  -> full width
    ///   old >  0  -> controlled smushing with (old & 31) | SM_SMUSH.
    ///
    /// The `& 31` is not a typo: figlet 2.2.5 drops the hardblank-smushing
    /// bit (32) when Full_Layout is missing. textfig reproduces that quirk so
    /// that output matches the original.
    pub fn defaultSmush(self: Header) u32 {
        if (self.full_layout) |fl| return fl & 0xff;
        if (self.old_layout == 0) return SM_KERN;
        if (self.old_layout < 0) return 0;
        return (@as(u32, @intCast(self.old_layout)) & 31) | SM_SMUSH;
    }
};

pub const Extra = struct {
    code: u21,
    glyph: Glyph,
};

pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        var w = Io.Writer.fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = w.end;
    }

    pub fn text(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Error = error{
    OutOfMemory,
    NotAFigFont,
    InvalidHeader,
    InvalidLayout,
    TruncatedFont,
    InvalidUtf8,
    CharacterCodeOutOfRange,
};

pub const LoadError = Error || error{
    FontNotFound,
    FontTooLarge,
    ReadFailed,
};

pub const max_font_bytes = 64 * 1024 * 1024;

fn isFigletSpace(c: u21) bool {
    return c == 0x20 or (c >= 0x09 and c <= 0x0d);
}

/// Decode one raw font row and strip its endmarks.
fn decodeRow(
    a: Allocator,
    raw: []const u8,
    format: Format,
    line_no: usize,
    diag: *Diag,
) Error![]const u21 {
    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(a);

    if (format == .flf) {
        // .flf glyph data is a byte stream; every byte is one cell (Latin-1).
        try cps.ensureTotalCapacity(a, raw.len);
        for (raw) |b| cps.appendAssumeCapacity(@as(u21, b));
    } else {
        var i: usize = 0;
        while (i < raw.len) {
            const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
                diag.set("font line {d}: invalid UTF-8 (byte 0x{x})", .{ line_no, raw[i] });
                return error.InvalidUtf8;
            };
            if (i + n > raw.len) {
                diag.set("font line {d}: truncated UTF-8 sequence", .{line_no});
                return error.InvalidUtf8;
            }
            const cp = std.unicode.utf8Decode(raw[i..][0..n]) catch {
                diag.set("font line {d}: invalid UTF-8 sequence", .{line_no});
                return error.InvalidUtf8;
            };
            try cps.append(a, cp);
            i += n;
        }
    }

    var n = cps.items.len;
    while (n > 0 and isFigletSpace(cps.items[n - 1])) n -= 1;
    if (n > 0) {
        const endmark = cps.items[n - 1];
        while (n > 0 and cps.items[n - 1] == endmark) n -= 1;
    }

    const out = try a.alloc(u21, n);
    @memcpy(out, cps.items[0..n]);
    return out;
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

fn parseIntField(comptime T: type, tok: []const u8, name: []const u8, diag: *Diag) Error!T {
    return std.fmt.parseInt(T, tok, 10) catch {
        diag.set("invalid {s} in font header: \"{s}\"", .{ name, tok });
        return error.InvalidHeader;
    };
}

/// Parse the first line of a FIGfont. Public so that the CLI tests and font
/// introspection tools can validate a header without a full font file.
pub fn parseHeader(line_in: []const u8, diag: *Diag) Error!Header {
    var line = line_in;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    const format: Format = blk: {
        if (std.mem.startsWith(u8, line, "flf2a")) break :blk .flf;
        if (std.mem.startsWith(u8, line, "tlf2a")) break :blk .tlf;
        diag.set("not a FIGlet/TOIlet font: missing flf2a/tlf2a signature", .{});
        return error.NotAFigFont;
    };
    if (line.len < 6) {
        diag.set("font header too short", .{});
        return error.InvalidHeader;
    }

    const hb_len = std.unicode.utf8ByteSequenceLength(line[5]) catch {
        diag.set("font header: invalid hardblank byte 0x{x}", .{line[5]});
        return error.InvalidHeader;
    };
    if (5 + hb_len > line.len) {
        diag.set("font header: truncated hardblank", .{});
        return error.InvalidHeader;
    }
    if (format == .flf and hb_len != 1) {
        diag.set("font header: .flf hardblank must be a single byte", .{});
        return error.InvalidHeader;
    }
    const hardblank = std.unicode.utf8Decode(line[5..][0..hb_len]) catch {
        diag.set("font header: invalid hardblank UTF-8", .{});
        return error.InvalidHeader;
    };
    // The FIGfont standard forbids a space hardblank, but the widely shipped
    // term.flf uses one (and figlet/libcaca accept it), so only newline, CR
    // and NUL are rejected.
    if (hardblank == '\n' or hardblank == '\r' or hardblank == 0) {
        diag.set("font header: illegal hardblank U+{X}", .{hardblank});
        return error.InvalidHeader;
    }

    var it = std.mem.tokenizeAny(u8, line[5 + hb_len ..], " \t");
    const height = try parseIntField(usize, it.next() orelse {
        diag.set("font header: missing height", .{});
        return error.InvalidHeader;
    }, "height", diag);
    const baseline = try parseIntField(usize, it.next() orelse {
        diag.set("font header: missing baseline", .{});
        return error.InvalidHeader;
    }, "baseline", diag);
    const max_length = try parseIntField(usize, it.next() orelse {
        diag.set("font header: missing max length", .{});
        return error.InvalidHeader;
    }, "max length", diag);
    const old_layout_raw = try parseIntField(i64, it.next() orelse {
        diag.set("font header: missing old layout", .{});
        return error.InvalidHeader;
    }, "old layout", diag);
    const comment_lines = try parseIntField(usize, it.next() orelse {
        diag.set("font header: missing comment line count", .{});
        return error.InvalidHeader;
    }, "comment line count", diag);

    if (height < 1 or height > 4096) {
        diag.set("font header: height {d} out of range (1..4096)", .{height});
        return error.InvalidHeader;
    }
    if (baseline < 1 or baseline > height) {
        diag.set("font header: baseline {d} out of range (1..{d})", .{ baseline, height });
        return error.InvalidHeader;
    }
    if (max_length < 1) {
        diag.set("font header: max length must be positive", .{});
        return error.InvalidHeader;
    }
    if (old_layout_raw < -1 or old_layout_raw > 63) {
        diag.set("font header: old layout {d} out of range (-1..63)", .{old_layout_raw});
        return error.InvalidLayout;
    }
    const old_layout: i32 = @intCast(old_layout_raw);

    var print_dir: Direction = .ltr;
    if (it.next()) |tok| {
        const pd = try parseIntField(i32, tok, "print direction", diag);
        print_dir = switch (pd) {
            0 => .ltr,
            1 => .rtl,
            else => {
                diag.set("font header: print direction {d} must be 0 or 1", .{pd});
                return error.InvalidHeader;
            },
        };
    }

    var full_layout: ?u32 = null;
    if (it.next()) |tok| {
        const fl = try parseIntField(u32, tok, "full layout", diag);
        if (fl > 32767) {
            diag.set("font header: full layout {d} out of range (0..32767)", .{fl});
            return error.InvalidLayout;
        }
        full_layout = fl;
    }

    var codetag_count: usize = 0;
    if (it.next()) |tok| {
        codetag_count = try parseIntField(usize, tok, "codetag count", diag);
    }

    return .{
        .format = format,
        .hardblank = hardblank,
        .height = height,
        .baseline = baseline,
        .max_length = max_length,
        .old_layout = old_layout,
        .comment_lines = comment_lines,
        .print_dir = print_dir,
        .full_layout = full_layout,
        .codetag_count = codetag_count,
    };
}

const german_codes = [_]u21{ 196, 214, 220, 228, 246, 252, 223 };

fn glyphCodeForIndex(i: usize) u21 {
    if (i < 95) return @intCast(32 + i);
    return german_codes[i - 95];
}

fn readGlyph(
    it: *LineIter,
    a: Allocator,
    height: usize,
    format: Format,
    what: []const u8,
    diag: *Diag,
) Error!Glyph {
    const rows = try a.alloc([]const u21, height);
    var width: usize = 0;
    for (0..height) |y| {
        const line = it.next() orelse {
            diag.set("font data truncated: {s}: expected {d} rows, found {d}", .{ what, height, y });
            return error.TruncatedFont;
        };
        rows[y] = try decodeRow(a, line, format, it.line_no, diag);
        width = @max(width, rows[y].len);
    }
    return .{ .rows = rows, .width = width };
}

fn parseCharCode(raw: []const u8) ?i64 {
    const t = std.mem.trim(u8, raw, " \t\r");
    if (t.len == 0) return null;
    var s = t;
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
    const signed = if (neg) -v else v;
    return signed;
}

pub const Font = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    format: Format,
    is_term: bool = false,
    hardblank: u21,
    height: usize,
    baseline: usize,
    max_length: usize,
    old_layout: i32,
    full_layout: ?u32,
    print_dir: Direction,
    codetag_count: usize,
    font_smush: u32,
    glyphs: []Glyph,
    extras: []Extra,
    missing_rows: []const []const u21,
    term_cell: [1]u21 = .{' '},
    term_row_holder: [1][]const u21 = .{&.{}},

    /// Parse a complete font from memory. The returned Font owns all of its
    /// memory through an internal arena; call `deinit` exactly once.
    pub fn parse(gpa: Allocator, bytes: []const u8, display_name: []const u8, diag: *Diag) Error!Font {
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
            diag.set(
                "font \"{s}\" is a compressed container; load it through font.load() so zlib can decompress it",
                .{display_name},
            );
            return error.NotAFigFont;
        }
        if (bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b) {
            diag.set("font \"{s}\" is a gzip container; load it through font.load() so zlib can decompress it", .{display_name});
            return error.NotAFigFont;
        }

        var f: Font = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .name = &.{},
            .format = .flf,
            .hardblank = '$',
            .height = 1,
            .baseline = 1,
            .max_length = 1,
            .old_layout = -1,
            .full_layout = null,
            .print_dir = .ltr,
            .codetag_count = 0,
            .font_smush = 0,
            .glyphs = &.{},
            .extras = &.{},
            .missing_rows = &.{},
        };
        errdefer f.arena.deinit();
        const a = f.arena.allocator();

        var lines = LineIter{ .data = bytes };
        const first = lines.next() orelse {
            diag.set("font \"{s}\" is empty", .{display_name});
            return error.NotAFigFont;
        };
        const h = try parseHeader(first, diag);

        f.name = try a.dupe(u8, display_name);
        f.format = h.format;
        f.hardblank = h.hardblank;
        f.height = h.height;
        f.baseline = h.baseline;
        f.max_length = h.max_length;
        f.old_layout = h.old_layout;
        f.full_layout = h.full_layout;
        f.print_dir = h.print_dir;
        f.codetag_count = h.codetag_count;
        f.font_smush = h.defaultSmush();

        for (0..h.comment_lines) |_| {
            if (lines.next() == null) {
                diag.set("font \"{s}\" ends inside its {d} comment lines", .{ display_name, h.comment_lines });
                return error.TruncatedFont;
            }
        }

        const glyphs = try a.alloc(Glyph, 102);
        for (0..102) |i| {
            const code = glyphCodeForIndex(i);
            var what_buf: [64]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "glyph U+{X:0>4}", .{code}) catch "glyph";
            glyphs[i] = try readGlyph(&lines, a, h.height, h.format, what, diag);
        }
        f.glyphs = glyphs;

        var extras: std.ArrayList(Extra) = .empty;
        while (true) {
            const peeked = lines.peek() orelse break;
            const trimmed = std.mem.trim(u8, peeked, " \t\r");
            if (trimmed.len == 0) {
                _ = lines.next();
                continue;
            }
            const code_i = parseCharCode(trimmed) orelse break;
            _ = lines.next();

            if (code_i < 0) {
                // Negative character codes are legal in FIGfonts but cannot be
                // produced by the input decoder. figlet reads and stores them;
                // textfig skips them (documented in README).
                for (0..h.height) |_| {
                    if (lines.next() == null) {
                        diag.set("font \"{s}\": truncated negative-code glyph", .{display_name});
                        return error.TruncatedFont;
                    }
                }
                continue;
            }
            if (code_i > 0x10FFFF) {
                diag.set("font \"{s}\": character code {d} is out of Unicode range", .{ display_name, code_i });
                return error.CharacterCodeOutOfRange;
            }
            const code: u21 = @intCast(code_i);
            var what_buf: [64]u8 = undefined;
            const what = std.fmt.bufPrint(&what_buf, "glyph U+{X:0>4}", .{code}) catch "codetagged glyph";
            const g = try readGlyph(&lines, a, h.height, h.format, what, diag);
            try extras.append(a, .{ .code = code, .glyph = g });
        }
        f.extras = try extras.toOwnedSlice(a);

        const missing = try a.alloc([]const u21, h.height);
        for (missing) |*row| row.* = &.{};
        f.missing_rows = missing;

        return f;
    }

    /// Built-in fallback font, TOIlet's `term`: one row, one column per input
    /// codepoint, no smushing. Useful when no font files are installed.
    pub fn builtinTerm(gpa: Allocator) Error!Font {
        var f: Font = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .name = "term",
            .format = .flf,
            .is_term = true,
            .hardblank = 0x7f,
            .height = 1,
            .baseline = 1,
            .max_length = 1,
            .old_layout = -1,
            .full_layout = null,
            .print_dir = .ltr,
            .codetag_count = 0,
            .font_smush = 0,
            .glyphs = &.{},
            .extras = &.{},
            .missing_rows = &.{},
        };
        errdefer f.arena.deinit();
        const a = f.arena.allocator();
        f.name = try a.dupe(u8, "term");
        f.glyphs = try a.alloc(Glyph, 0);
        f.extras = try a.alloc(Extra, 0);
        f.missing_rows = try a.alloc([]const u21, 0);
        return f;
    }

    pub fn deinit(self: *Font) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Look up a codepoint. Unknown characters yield a zero-width glyph, as in
    /// figlet (they occupy no space and produce no output).
    pub fn glyph(self: *Font, code: u21) Glyph {
        if (self.is_term) {
            self.term_cell[0] = code;
            self.term_row_holder[0] = self.term_cell[0..1];
            return .{ .rows = self.term_row_holder[0..1], .width = 1 };
        }
        if (code >= 32 and code <= 126) return self.glyphs[@intCast(code - 32)];
        for (german_codes, 0..) |gc, i| {
            if (code == gc) return self.glyphs[95 + i];
        }
        var i = self.extras.len;
        while (i > 0) {
            i -= 1;
            if (self.extras[i].code == code) return self.extras[i].glyph;
        }
        return .{ .rows = self.missing_rows, .width = 0 };
    }

    /// True when the font actually provides a glyph for this codepoint.
    pub fn hasGlyph(self: *Font, code: u21) bool {
        return self.glyph(code).width != 0;
    }
};

pub const SearchConfig = struct {
    explicit_dir: ?[]const u8 = null,
    env_fontdir: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

fn joinPath(a: Allocator, parts: []const []const u8) Error![]const u8 {
    return std.fs.path.join(a, parts) catch return error.OutOfMemory;
}

/// Ordered font search path:
///   -d/--font-dir, else $FIGLET_FONTDIR, else $XDG_DATA_HOME/figlet,
///   else ~/.local/share/figlet, else /usr/share/figlet; then `.` (figlet and
///   TOIlet both fall back to the current directory).
pub fn searchDirs(a: Allocator, cfg: SearchConfig) Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;

    if (cfg.explicit_dir) |d| {
        if (d.len != 0) try list.append(a, d);
    }
    if (list.items.len == 0) {
        if (cfg.env_fontdir) |d| {
            if (d.len != 0) try list.append(a, d);
        }
    }
    if (list.items.len == 0) {
        if (cfg.xdg_data_home) |xdg| {
            if (xdg.len != 0) try list.append(a, try joinPath(a, &.{ xdg, "figlet" }));
        } else if (cfg.home) |home| {
            if (home.len != 0) {
                try list.append(a, try joinPath(a, &.{ home, ".local", "share", "figlet" }));
            }
        }
    }
    if (list.items.len == 0) try list.append(a, "/usr/share/figlet");

    // 系统里没装 figlet 时，我们自己的包也会带一份字体（zfiglet/ztoilet 各装各的），
    // 所以把它们加进备选目录，主目录找不到再往下找。
    for ([_][]const u8{ "/usr/share/figlet", "/usr/share/ziglet/fonts", "/usr/share/ztoilet/fonts" }) |d| {
        var seen = false;
        for (list.items) |e| if (std.mem.eql(u8, d, e)) {
            seen = true;
        };
        if (!seen) try list.append(a, d);
    }

    // The primary directory is what -I2 reports and what is searched first.
    // Also search the current directory, like both originals.
    var has_dot = false;
    for (list.items) |d| if (std.mem.eql(u8, d, ".")) {
        has_dot = true;
    };
    if (!has_dot) try list.append(a, ".");

    var out: std.ArrayList([]const u8) = .empty;
    for (list.items) |d| {
        var dup = false;
        for (out.items) |e| if (std.mem.eql(u8, d, e)) {
            dup = true;
        };
        if (!dup) try out.append(a, d);
    }
    return out.toOwnedSlice(a);
}

pub fn primaryDir(dirs: []const []const u8) []const u8 {
    return if (dirs.len > 0) dirs[0] else "/usr/share/figlet";
}

fn hasSuffix(haystack: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, haystack, suffix);
}

const font_variants = [_][]const u8{
    "",     ".flf",    ".flf.gz",  ".flf.zip",
    ".tlf", ".tlf.gz", ".tlf.zip",
};
const exact_variant = [_][]const u8{""};

fn hasAnySuffix(name: []const u8) bool {
    return hasSuffix(name, ".flf") or hasSuffix(name, ".tlf") or
        hasSuffix(name, ".gz") or hasSuffix(name, ".zip");
}

/// Load a font by name (suffix optional) from the search path. `term` is
/// always available as the built-in fallback.
///
/// Candidate order for a bare name (per directory):
///   name, name.flf, name.flf.gz, name.flf.zip,
///   name.tlf, name.tlf.gz, name.tlf.zip
/// Names that already carry a font/compression suffix are tried verbatim.
pub fn load(io: Io, gpa: Allocator, dirs: []const []const u8, name_in: []const u8, diag: *Diag) LoadError!Font {
    const name = std.mem.trim(u8, name_in, " \t");
    const variants: []const []const u8 = if (hasAnySuffix(name)) &exact_variant else &font_variants;

    if (std.fs.path.isAbsolute(name) or std.mem.indexOfScalar(u8, name, '/') != null) {
        for (variants) |variant| {
            const path = std.fmt.allocPrint(gpa, "{s}{s}", .{ name, variant }) catch return error.OutOfMemory;
            defer gpa.free(path);
            if (try loadOne(io, gpa, path, diag, name)) |f| return f;
        }
        if (hasAnySuffix(name)) {
            diag.set("font \"{s}\": no such file", .{name});
        } else {
            diag.set("font \"{s}\": no such file (tried plain, .flf, .flf.gz, .flf.zip, .tlf, .tlf.gz, .tlf.zip)", .{name});
        }
        return error.FontNotFound;
    }

    for (dirs) |dir| {
        for (variants) |variant| {
            const path = std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ dir, name, variant }) catch
                return error.OutOfMemory;
            defer gpa.free(path);
            if (try loadOne(io, gpa, path, diag, name)) |f| return f;
        }
    }

    // TOIlet's built-in fallback: only used when no `term.flf` file was found.
    if (std.mem.eql(u8, name, "term")) return Font.builtinTerm(gpa);

    diag.set(
        "font \"{s}\" not found in {s} (use -f term for the built-in fallback font)",
        .{ name, fontDirList(dirs) },
    );
    return error.FontNotFound;
}

/// Shared mutable buffer for error messages listing directories. The error
/// path only, so a static buffer is acceptable; tests run single-threaded.
var dir_list_buf: [512]u8 = undefined;

fn fontDirList(dirs: []const []const u8) []const u8 {
    var w = Io.Writer.fixed(&dir_list_buf);
    for (dirs, 0..) |d, i| {
        if (i != 0) w.writeAll(":") catch {};
        w.writeAll(d) catch {};
    }
    return dir_list_buf[0..w.end];
}

/// If `path` names a readable font file, parse and return it; otherwise return
/// null so the caller can try the next candidate. Parse errors are fatal (an
/// existing but broken font must not silently fall through).
fn loadOne(
    io: Io,
    gpa: Allocator,
    path: []const u8,
    diag: *Diag,
    display_name: []const u8,
) LoadError!?Font {
    const bytes = (try readFontBytes(io, gpa, path, diag)) orelse return null;
    defer gpa.free(bytes);
    return try Font.parse(gpa, bytes, display_name, diag);
}

/// Read a font container and return the plain FIGfont bytes. Handles .gz via
/// gzFile streaming, .zip (and files whose content is a zip, like TOIlet's
/// stored .tlf fonts) via the central directory, and plain files otherwise.
fn readFontBytes(io: Io, gpa: Allocator, path: []const u8, diag: *Diag) LoadError!?[]u8 {
    if (hasSuffix(path, ".gz")) return readGzip(io, gpa, path, diag);

    const raw = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_font_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        error.StreamTooLong => {
            diag.set("font file \"{s}\" is larger than {d} MiB", .{ path, max_font_bytes / (1024 * 1024) });
            return error.FontTooLarge;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var msg_diag: Diag = .{};
            msg_diag.set("cannot read font file \"{s}\": {t}", .{ path, err });
            diag.set("{s}", .{msg_diag.text()});
            return error.ReadFailed;
        },
    };

    if (compressed.isZip(raw)) {
        if (compressed.unzipBytes(gpa, raw, max_font_bytes)) |out| {
            gpa.free(raw);
            return out;
        } else |err| {
            gpa.free(raw);
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooLarge => {
                    diag.set("font file \"{s}\": decompressed size exceeds {d} MiB", .{ path, max_font_bytes / (1024 * 1024) });
                    return error.FontTooLarge;
                },
                error.UnsupportedZip => {
                    diag.set("font file \"{s}\": unsupported zip feature (compression method, encryption, ZIP64 or multi-disk)", .{path});
                    return error.NotAFigFont;
                },
                else => {
                    diag.set("font file \"{s}\": corrupt zip archive", .{path});
                    return error.NotAFigFont;
                },
            }
        }
    }

    if (compressed.isGzip(raw)) {
        // A gzip stream without a .gz name: use the same gzFile path.
        gpa.free(raw);
        return readGzip(io, gpa, path, diag);
    }

    if (hasSuffix(path, ".zip")) {
        diag.set("font file \"{s}\" is not a zip archive", .{path});
        gpa.free(raw);
        return error.NotAFigFont;
    }

    return raw;
}

fn readGzip(io: Io, gpa: Allocator, path: []const u8, diag: *Diag) LoadError!?[]u8 {
    // Distinguish "not there" (try the next candidate) from a real error.
    var probe = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return null,
        else => {
            diag.set("cannot open gzip font file \"{s}\": {t}", .{ path, err });
            return error.ReadFailed;
        },
    };
    probe.close(io);

    const out = compressed.gunzipFile(gpa, path, max_font_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OpenFailed => {
            diag.set("cannot open gzip font file \"{s}\"", .{path});
            return error.ReadFailed;
        },
        error.TooLarge => {
            diag.set("font file \"{s}\": decompressed size exceeds {d} MiB", .{ path, max_font_bytes / (1024 * 1024) });
            return error.FontTooLarge;
        },
        error.InvalidGzip => {
            diag.set("font file \"{s}\": gzip decompression failed", .{path});
            return error.NotAFigFont;
        },
        else => {
            diag.set("font file \"{s}\": gzip decompression failed", .{path});
            return error.NotAFigFont;
        },
    };
    return out;
}

pub fn listFonts(io: Io, gpa: Allocator, dirs: []const []const u8, writer: *Io.Writer) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    try names.append(gpa, try gpa.dupe(u8, "term"));

    for (dirs) |dir| {
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const n = entry.name;
            const b = fontBaseName(n) orelse continue;
            if (b.len == 0) continue;
            try names.append(gpa, try gpa.dupe(u8, b));
        }
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var last: ?[]const u8 = null;
    var count: usize = 0;
    for (names.items) |n| {
        if (last != null and std.mem.eql(u8, n, last.?)) continue;
        last = n;
        try writer.print("{s}\n", .{n});
        count += 1;
    }
    try writer.flush();
}

/// Strip an optional .gz/.zip container suffix, then .flf/.tlf.
fn fontBaseName(name_in: []const u8) ?[]const u8 {
    var name = name_in;
    if (hasSuffix(name, ".gz")) {
        name = name[0 .. name.len - 3];
    } else if (hasSuffix(name, ".zip")) {
        name = name[0 .. name.len - 4];
    }
    if (hasSuffix(name, ".flf") or hasSuffix(name, ".tlf")) {
        return name[0 .. name.len - 4];
    }
    return null;
}

test "header parsing: all optional fields" {
    var diag: Diag = .{};
    const h = try parseHeader("flf2a$ 6 5 20 15 3 0 143 229", &diag);
    try std.testing.expectEqual(Format.flf, h.format);
    try std.testing.expectEqual(@as(u21, '$'), h.hardblank);
    try std.testing.expectEqual(@as(usize, 6), h.height);
    try std.testing.expectEqual(@as(usize, 5), h.baseline);
    try std.testing.expectEqual(@as(usize, 20), h.max_length);
    try std.testing.expectEqual(@as(i32, 15), h.old_layout);
    try std.testing.expectEqual(@as(usize, 3), h.comment_lines);
    try std.testing.expectEqual(Direction.ltr, h.print_dir);
    try std.testing.expectEqual(@as(?u32, 143), h.full_layout);
    try std.testing.expectEqual(@as(usize, 229), h.codetag_count);
    try std.testing.expectEqual(@as(u32, 143), h.defaultSmush());
}

test "header parsing: tlf, rtl, missing layout fields" {
    var diag: Diag = .{};
    const h = try parseHeader("tlf2a$ 8 7 16 -1 4 1", &diag);
    try std.testing.expectEqual(Format.tlf, h.format);
    try std.testing.expectEqual(Direction.rtl, h.print_dir);
    try std.testing.expectEqual(@as(?u32, null), h.full_layout);
    try std.testing.expectEqual(@as(u32, 0), h.defaultSmush());

    const k = try parseHeader("flf2a@ 3 3 8 0 0", &diag);
    try std.testing.expectEqual(@as(u32, SM_KERN), k.defaultSmush());
}

test "header parsing: rejects bad input with a readable diagnostic" {
    var diag: Diag = .{};
    try std.testing.expectError(error.NotAFigFont, parseHeader("hello world", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "flf2a") != null);

    var d2: Diag = .{};
    try std.testing.expectError(error.InvalidHeader, parseHeader("flf2a$ 0 1 2 0 0", &d2));
    try std.testing.expect(std.mem.indexOf(u8, d2.text(), "height") != null);

    var d3: Diag = .{};
    try std.testing.expectError(error.InvalidLayout, parseHeader("flf2a$ 3 2 4 99 0", &d3));
}

test "endmark stripping keeps meaningful blanks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diag = .{};

    // Single endmark, trailing spaces before it are part of the glyph.
    const r1 = try decodeRow(a, " _ @", .flf, 1, &diag);
    try std.testing.expectEqualSlices(u21, &.{ ' ', '_', ' ' }, r1);

    // Last row with two endmarks.
    const r2 = try decodeRow(a, "|_|@@", .flf, 2, &diag);
    try std.testing.expectEqualSlices(u21, &.{ '|', '_', '|' }, r2);

    // Whitespace *after* the endmark is ignored, but the endmark itself can
    // appear several times.
    const r3 = try decodeRow(a, "ab@@  \t", .flf, 3, &diag);
    try std.testing.expectEqualSlices(u21, &.{ 'a', 'b' }, r3);

    // A UTF-8 row: width is codepoints, not bytes.
    const r4 = try decodeRow(a, "中文@@", .tlf, 4, &diag);
    try std.testing.expectEqualSlices(u21, &.{ 0x4e2d, 0x6587 }, r4);

    // Empty row (just endmarks) is legal.
    const r5 = try decodeRow(a, "@", .flf, 5, &diag);
    try std.testing.expectEqual(@as(usize, 0), r5.len);
}

test "full font parse: mandatory glyphs, german order, codetags" {
    var diag: Diag = .{};
    var f = try Font.parse(std.testing.allocator, @embedFile("testdata/tiny.flf"), "tiny", &diag);
    defer f.deinit();

    try std.testing.expectEqual(@as(usize, 3), f.height);
    try std.testing.expectEqual(Direction.ltr, f.print_dir);
    try std.testing.expectEqual(@as(u32, 0), f.font_smush); // full width

    const g_h = f.glyph('H');
    try std.testing.expectEqual(@as(usize, 3), g_h.width);
    try std.testing.expectEqual(@as(u21, 'H'), g_h.cell(1, 1));

    // German glyphs are the 7 slots after ASCII; the generator draws '?'.
    const g_de = f.glyph(0x00e4);
    try std.testing.expectEqual(@as(usize, 3), g_de.width);

    try std.testing.expectEqual(@as(usize, 0), f.extras.len);

    var tdiag: Diag = .{};
    var t = try Font.parse(std.testing.allocator, @embedFile("testdata/tiny.tlf"), "tiny.tlf", &tdiag);
    defer t.deinit();
    try std.testing.expectEqual(Format.tlf, t.format);
    try std.testing.expectEqual(@as(usize, 2), t.extras.len);
    const g_cn = t.glyph(0x4e2d);
    try std.testing.expectEqual(@as(u21, 0x4e2d), g_cn.cell(1, 1));
    const g_wen = t.glyph(0x6587);
    try std.testing.expectEqual(@as(u21, 0x6587), g_wen.cell(1, 1));
}

test "missing glyph data is a clean error" {
    const truncated =
        "flf2a$ 2 1 4 -1 0\n" ++
        " $@\n";
    var diag: Diag = .{};
    try std.testing.expectError(error.TruncatedFont, Font.parse(std.testing.allocator, truncated, "broken", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.text(), "truncated") != null);
}
