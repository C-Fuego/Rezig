//! The escape-sequence matcher of the Ruby original, byte for byte.
//!
//! lolcat does not "parse" ANSI: it splits every line with one regular
//! expression (`lib/lolcat/lol.rb`):
//!
//!     ANSI_ESCAPE = /((?:\e(?:[ -\/]+.|[\]PX^_][^\a\e]*|\[[0-?]*.|.))*)(.?)/m
//!
//! Each match is `(escape prefix, character)`: the prefix is a run of *whole*
//! escape sequences and is printed verbatim, the character (anything else, one
//! code point: a letter, a space, a tab that survived the tab expansion, a
//! carriage return, the BEL of an OSC, ...) is painted.  The second group is
//! optional, so a line that ends with an escape sequence produces one extra
//! match with an empty character - and Ruby's `scan` also yields the final
//! empty match at the end of the string, so every line ends with one more
//! colour+reset pair than it has characters.
//!
//!     INCOMPLETE_ESCAPE = /\e(?:[ -\/]*|[\]PX^_][^\a\e]*|\[[0-?]*)$/
//!
//! is the second expression: it says "the read buffer ends in the middle of an
//! escape sequence", which makes the original read another block before it
//! prints anything.

const std = @import("std");

/// ESC, spelled out so the rest reads like the regex.
pub const esc = 0x1b;

/// Length in bytes of the escape sequence starting at `bytes[pos]`, or null
/// when there is none.
///
/// One alternative of the regex is a bare `.` (ESC followed by anything), which
/// is also what the two longer alternatives fall back to when the buffer ends
/// too early; that fallback is why the truncated cases return 2.
pub fn escapeLen(bytes: []const u8, pos: usize) ?usize {
    if (pos >= bytes.len or bytes[pos] != esc) return null;
    if (pos + 1 >= bytes.len) return null; // a lone ESC cannot start a prefix
    const intro = bytes[pos + 1];

    // [ -\/]+.  -- nF sequence: one or more intermediates, then any byte
    if (intro >= 0x20 and intro <= 0x2f) {
        var i = pos + 1;
        while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) : (i += 1) {}
        if (i >= bytes.len) return 2; // truncated: `\e` + one intermediate
        return i + 1 - pos;
    }

    // [\]PX^_][^\a\e]*  -- OSC, DCS, SOS, PM, APC: runs to BEL/ESC or to the end
    if (intro == ']' or intro == 'P' or intro == 'X' or intro == '^' or intro == '_') {
        var i = pos + 2;
        while (i < bytes.len and bytes[i] != 0x07 and bytes[i] != esc) : (i += 1) {}
        return i - pos;
    }

    // \[[0-?]*.  -- CSI: parameters, then the final byte
    if (intro == '[') {
        var i = pos + 2;
        while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
        if (i >= bytes.len) return 2; // truncated: `\e[` is `\e` + `.`
        return i + 1 - pos;
    }

    // .  -- any other two-byte escape (ESC c, ESC 7, ESC \, ...)
    return 2;
}

/// Does `bytes` end inside an escape sequence?  This is INCOMPLETE_ESCAPE: the
/// original keeps reading until it is false.
pub fn endsIncomplete(bytes: []const u8) bool {
    const start = std.mem.lastIndexOfScalar(u8, bytes, esc) orelse return false;
    const tail = bytes[start..];
    if (tail.len == 1) return true; // \e[ -\/]*$ with zero intermediates
    const intro = tail[1];

    if (intro >= 0x20 and intro <= 0x2f) {
        for (tail[1..]) |b| {
            if (b < 0x20 or b > 0x2f) return false;
        }
        return true;
    }
    if (intro == ']' or intro == 'P' or intro == 'X' or intro == '^' or intro == '_') {
        // [^\a\e]*$: no BEL, and no ESC because we started at the last one
        for (tail[2..]) |b| {
            if (b == 0x07) return false;
        }
        return true;
    }
    if (intro == '[') {
        for (tail[2..]) |b| {
            if (b < 0x30 or b > 0x3f) return false;
        }
        return true;
    }
    return false;
}

/// `str.gsub!(/\e\[[0-?]*[@JKPX]/, "")` from `println_ani`: between two
/// animation frames the original strips cursor movement and erase sequences
/// from the line so that they do not pile up.
fn cursorSeqLen(bytes: []const u8, pos: usize) ?usize {
    if (pos + 1 >= bytes.len or bytes[pos] != esc or bytes[pos + 1] != '[') return null;
    var i = pos + 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) : (i += 1) {}
    if (i >= bytes.len) return null;
    return switch (bytes[i]) {
        '@', 'J', 'K', 'P', 'X' => i + 1 - pos,
        else => null,
    };
}

/// Remove every `\e[...@JKPX` sequence in place.  Returns the new length.
pub fn stripCursorSequences(bytes: []u8) usize {
    var read: usize = 0;
    var write: usize = 0;
    while (read < bytes.len) {
        if (cursorSeqLen(bytes, read)) |n| {
            read += n;
            continue;
        }
        bytes[write] = bytes[read];
        write += 1;
        read += 1;
    }
    return write;
}

const testing = std.testing;

/// Split `line` the way `line.scan(ANSI_ESCAPE)` does, into (prefix, char)
/// slices, and hand them to `sink`.
pub fn scan(
    line: []const u8,
    context: anytype,
    sink: anytype,
) !void {
    var pos: usize = 0;
    while (true) {
        const prefix_start = pos;
        while (escapeLen(line, pos)) |n| pos += n;
        const prefix = line[prefix_start..pos];

        if (pos < line.len) {
            const n = charLen(line, pos);
            try sink(context, prefix, line[pos .. pos + n]);
            pos += n;
            continue;
        }
        try sink(context, prefix, "");
        // an empty match ends the scan; after a trailing escape Ruby's scan
        // still yields the final ("", "")
        if (pos == prefix_start) break;
    }
}

/// Length of the code point at `pos` (Ruby's `.` in a UTF-8 string).  Invalid
/// UTF-8 is one byte, where Ruby would raise.
fn charLen(bytes: []const u8, pos: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch return 1;
    if (pos + n > bytes.len) return 1;
    _ = std.unicode.utf8Decode(bytes[pos .. pos + n]) catch return 1;
    return n;
}

test "CSI, OSC, nF and two byte escapes" {
    try testing.expectEqual(@as(?usize, 5), escapeLen("\x1b[31m", 0));
    try testing.expectEqual(@as(?usize, 9), escapeLen("\x1b[38;5;1m", 0));
    try testing.expectEqual(@as(?usize, 6), escapeLen("\x1b]0;hi\x07rest", 0)); // terminates before BEL
    try testing.expectEqual(@as(?usize, 2), escapeLen("\x1b7x", 0));
    try testing.expectEqual(@as(?usize, 3), escapeLen("\x1b(0x", 0));
    try testing.expectEqual(@as(?usize, null), escapeLen("abc", 0));
}

test "a run of escapes is a single prefix" {
    const line = "\x1b[1m\x1b[31mX";
    var pos: usize = 0;
    while (escapeLen(line, pos)) |n| pos += n;
    try testing.expectEqualStrings("\x1b[1m\x1b[31m", line[0..pos]);
}

test "truncated escapes fall back to ESC plus one byte" {
    try testing.expectEqual(@as(?usize, 2), escapeLen("\x1b[", 0));
    try testing.expectEqual(@as(?usize, 2), escapeLen("\x1b(", 0)); // no final byte yet
    try testing.expectEqual(@as(?usize, null), escapeLen("\x1b", 0));
}

test "incomplete escapes at the end of a read" {
    try testing.expect(endsIncomplete("\x1b"));
    try testing.expect(endsIncomplete("abc\x1b[3"));
    try testing.expect(endsIncomplete("\x1b]0;title"));
    try testing.expect(endsIncomplete("\x1b("));
    try testing.expect(!endsIncomplete("abc\x1b[31m"));
    try testing.expect(!endsIncomplete("\x1b]0;title\x07"));
    try testing.expect(!endsIncomplete("plain text"));
    // a complete sequence followed by nothing incomplete is fine
    try testing.expect(!endsIncomplete("\x1b]8;;url\x1b\\"));
}

test "scan yields Ruby's (prefix, char) pairs, including the empty tail" {
    const Collector = struct {
        prefixes: [8][]const u8 = undefined,
        chars: [8][]const u8 = undefined,
        n: usize = 0,

        fn push(self: *@This(), prefix: []const u8, char: []const u8) !void {
            self.prefixes[self.n] = prefix;
            self.chars[self.n] = char;
            self.n += 1;
        }
    };

    var c = Collector{};
    try scan("ab", &c, Collector.push);
    try testing.expectEqual(@as(usize, 3), c.n); // a, b, ""
    try testing.expectEqualStrings("a", c.chars[0]);
    try testing.expectEqualStrings("b", c.chars[1]);
    try testing.expectEqualStrings("", c.chars[2]);

    c = Collector{};
    try scan("\x1b[31mA", &c, Collector.push);
    try testing.expectEqual(@as(usize, 2), c.n); // (esc, A), ("", "")
    try testing.expectEqualStrings("\x1b[31m", c.prefixes[0]);
    try testing.expectEqualStrings("A", c.chars[0]);
    try testing.expectEqualStrings("", c.chars[1]);

    // a line that ends with an escape gets ("esc", "") *and* the final ("", "")
    c = Collector{};
    try scan("A\x1b[0m", &c, Collector.push);
    try testing.expectEqual(@as(usize, 3), c.n);
    try testing.expectEqualStrings("A", c.chars[0]);
    try testing.expectEqualStrings("", c.chars[1]);
    try testing.expectEqualStrings("\x1b[0m", c.prefixes[1]);
    try testing.expectEqualStrings("", c.chars[2]);

    // an empty line still yields one (empty) pair
    c = Collector{};
    try scan("", &c, Collector.push);
    try testing.expectEqual(@as(usize, 1), c.n);

    // one code point per pair, not one byte
    c = Collector{};
    try scan("中", &c, Collector.push);
    try testing.expectEqual(@as(usize, 2), c.n);
    try testing.expectEqualStrings("中", c.chars[0]);
}

test "cursor and erase sequences are stripped between frames" {
    var buf: [64]u8 = undefined;
    const text = "a\x1b[2Kb\x1b[1Jc\x1b[0Pd\x1b[3Xe\x1b[1@f";
    @memcpy(buf[0..text.len], text);
    const n = stripCursorSequences(buf[0..text.len]);
    try testing.expectEqualStrings("abcdef", buf[0..n]);
    // cursor *movement* (H, A, B, ...) is not in the Ruby class and stays
    var other: [16]u8 = undefined;
    const keep = "a\x1b[1;2Hb";
    @memcpy(other[0..keep.len], keep);
    try testing.expectEqualStrings(keep, other[0..stripCursorSequences(other[0..keep.len])]);
}
