//! FIGlet control files (`.flc`) and TOIlet-style `.tlc` files.
//!
//! Grammar (figfont.txt, "CONTROL FILES"):
//!
//!     t inchar outchar
//!     t inchar1-inchar2 outchar1-outchar2
//!     number number
//!     f
//!     h | b | u | j | g...
//!     # comment
//!
//! `f` starts a new transformation stage. Within one stage only the first
//! matching mapping is applied; stages run in file order, which is what
//! figlet's freeze-command list does.
//!
//! `.tlc` is textfig's alias for the same grammar applied to `.tlf` fonts.
//! Upstream TOIlet/libcaca has no control-file support at all, so there is no
//! competing format to follow; this is documented in README.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("font.zig").Diag;

pub const Error = error{
    OutOfMemory,
    InvalidControlFile,
};

pub const Map = struct {
    lo: u21,
    hi: u21,
    offset: i64,
};

pub const Stage = struct {
    maps: []Map,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    stages: []Stage,

    pub fn parse(gpa: Allocator, bytes: []const u8, name: []const u8, diag: *Diag) Error!Program {
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) {
            diag.set("control file \"{s}\" is a compressed archive; decompress it first", .{name});
            return error.InvalidControlFile;
        }
        var p: Program = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .name = &.{},
            .stages = &.{},
        };
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        p.name = try a.dupe(u8, name);

        var stages: std.ArrayList(Stage) = .empty;
        var current: std.ArrayList(Map) = .empty;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            switch (line[0]) {
                't', 'T' => {
                    var pos: usize = 1;
                    skipWs(line, &pos);
                    const lo_i = try readTchar(line, &pos, line_no, diag);
                    var hi_i = lo_i;
                    if (pos < line.len and line[pos] == '-') {
                        pos += 1;
                        hi_i = try readTchar(line, &pos, line_no, diag);
                    }
                    skipWs(line, &pos);
                    const out_i = try readTchar(line, &pos, line_no, diag);
                    try appendMap(a, &current, lo_i, hi_i, out_i, line_no, diag);
                },
                '0'...'9', '-' => {
                    var pos: usize = 0;
                    const lo_i = try readNum(line, &pos, line_no, diag);
                    skipWs(line, &pos);
                    const out_i = try readNum(line, &pos, line_no, diag);
                    try appendMap(a, &current, lo_i, lo_i, out_i, line_no, diag);
                },
                'f', 'F' => {
                    if (current.items.len > 0) {
                        try stages.append(a, .{ .maps = try a.dupe(Map, current.items) });
                        current.clearRetainingCapacity();
                    }
                },
                // Input-mode and ISO-2022 commands: figlet switches to DBCS,
                // UTF-8, HZ or Shift-JIS input. textfig always decodes UTF-8;
                // these commands are accepted and ignored.
                'b', 'B', 'u', 'U', 'h', 'H', 'j', 'J', 'g', 'G' => {},
                else => {},
            }
        }
        if (current.items.len > 0) {
            try stages.append(a, .{ .maps = try a.dupe(Map, current.items) });
        }
        p.stages = try stages.toOwnedSlice(a);
        return p;
    }

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Transform one input codepoint through every stage.
    pub fn apply(self: *const Program, c_in: u21) u21 {
        var c: i64 = c_in;
        for (self.stages) |stage| {
            for (stage.maps) |m| {
                if (c >= m.lo and c <= m.hi) {
                    c = std.math.add(i64, c, m.offset) catch
                        (if (m.offset > 0) @as(i64, 0x10FFFF) else 0);
                    if (c < 0) c = 0;
                    if (c > 0x10FFFF) c = 0x10FFFF;
                    break; // first applicable mapping in this stage only
                }
            }
        }
        return @intCast(c);
    }

    /// Number of maps, for diagnostics and tests.
    pub fn mapCount(self: *const Program) usize {
        var n: usize = 0;
        for (self.stages) |s| n += s.maps.len;
        return n;
    }
};

fn skipWs(line: []const u8, pos: *usize) void {
    while (pos.* < line.len and (line[pos.*] == ' ' or line[pos.*] == '\t')) pos.* += 1;
}

fn appendMap(
    a: Allocator,
    current: *std.ArrayList(Map),
    lo_i: i64,
    hi_i: i64,
    out_i: i64,
    line_no: usize,
    diag: *Diag,
) Error!void {
    // Control-file codes outside Unicode cannot be produced by the decoder;
    // skip them instead of failing (figlet tolerates wildly out-of-range
    // numbers here as well).
    if (lo_i < 0 or hi_i < 0 or lo_i > 0x10FFFF or hi_i > 0x10FFFF) return;
    if (hi_i < lo_i) {
        diag.set("control file line {d}: reversed range {d}-{d}", .{ line_no, lo_i, hi_i });
        return error.InvalidControlFile;
    }
    try current.append(a, .{
        .lo = @intCast(lo_i),
        .hi = @intCast(hi_i),
        .offset = std.math.sub(i64, out_i, lo_i) catch return error.InvalidControlFile,
    });
}

fn readNum(line: []const u8, pos: *usize, line_no: usize, diag: *Diag) Error!i64 {
    skipWs(line, pos);
    var sign: i64 = 1;
    if (pos.* < line.len and line[pos.*] == '-') {
        sign = -1;
        pos.* += 1;
    }
    var base: u8 = 10;
    if (pos.* < line.len and line[pos.*] == '0') {
        pos.* += 1;
        if (pos.* < line.len and (line[pos.*] == 'x' or line[pos.*] == 'X')) {
            base = 16;
            pos.* += 1;
        } else {
            base = 8;
        }
    }
    var acc: i64 = 0;
    var any = false;
    while (pos.* < line.len) {
        const d = std.fmt.charToDigit(line[pos.*], base) catch break;
        acc = std.math.mul(i64, acc, base) catch {
            diag.set("control file line {d}: character code too large", .{line_no});
            return error.InvalidControlFile;
        };
        acc = std.math.add(i64, acc, d) catch {
            diag.set("control file line {d}: character code too large", .{line_no});
            return error.InvalidControlFile;
        };
        pos.* += 1;
        any = true;
    }
    if (!any) {
        diag.set("control file line {d}: expected a character code", .{line_no});
        return error.InvalidControlFile;
    }
    return acc * sign;
}

fn readTchar(line: []const u8, pos: *usize, line_no: usize, diag: *Diag) Error!i64 {
    skipWs(line, pos);
    if (pos.* >= line.len) {
        diag.set("control file line {d}: missing character", .{line_no});
        return error.InvalidControlFile;
    }
    if (line[pos.*] == '\\') {
        pos.* += 1;
        if (pos.* >= line.len) {
            diag.set("control file line {d}: dangling backslash", .{line_no});
            return error.InvalidControlFile;
        }
        const next = line[pos.*];
        switch (next) {
            'a' => {
                pos.* += 1;
                return 7;
            },
            'b' => {
                pos.* += 1;
                return 8;
            },
            'e' => {
                pos.* += 1;
                return 27;
            },
            'f' => {
                pos.* += 1;
                return 12;
            },
            'n' => {
                pos.* += 1;
                return 10;
            },
            'r' => {
                pos.* += 1;
                return 13;
            },
            't' => {
                pos.* += 1;
                return 9;
            },
            'v' => {
                pos.* += 1;
                return 11;
            },
            else => {
                if (next == '-' or (next >= '0' and next <= '9') or next == 'x' or next == 'X') {
                    return readNum(line, pos, line_no, diag);
                }
                // "\\ ", "\\\\" and any other escaped literal.
                const n = std.unicode.utf8ByteSequenceLength(next) catch {
                    pos.* += 1;
                    return next;
                };
                if (pos.* + n > line.len) {
                    diag.set("control file line {d}: truncated UTF-8 character", .{line_no});
                    return error.InvalidControlFile;
                }
                const cp = std.unicode.utf8Decode(line[pos.*..][0..n]) catch {
                    pos.* += 1;
                    return next;
                };
                pos.* += n;
                return cp;
            },
        }
    }
    // Literal character, UTF-8 aware.
    const n = std.unicode.utf8ByteSequenceLength(line[pos.*]) catch {
        const b = line[pos.*];
        pos.* += 1;
        return b;
    };
    if (pos.* + n > line.len) {
        diag.set("control file line {d}: truncated UTF-8 character", .{line_no});
        return error.InvalidControlFile;
    }
    const cp = std.unicode.utf8Decode(line[pos.*..][0..n]) catch {
        const b = line[pos.*];
        pos.* += 1;
        return b;
    };
    pos.* += n;
    return cp;
}

const testing = std.testing;

test "control file: t commands, ranges and stages" {
    var diag: Diag = .{};
    const src =
        "flc2a\n" ++
        "t # $\n" ++
        "t A-Z a-z\n" ++
        "f\n" ++
        "t a x\n";
    var p = try Program.parse(testing.allocator, src, "test.flc", &diag);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.stages.len);
    try testing.expectEqual(@as(u21, '$'), p.apply('#'));
    // stage 1 maps A->a, stage 2 maps a->x
    try testing.expectEqual(@as(u21, 'x'), p.apply('A'));
    try testing.expectEqual(@as(u21, 'x'), p.apply('a'));
    try testing.expectEqual(@as(u21, 'Z' + 32), p.apply('Z'));
}

test "control file: numeric and escaped character specifications" {
    var diag: Diag = .{};
    const src =
        "65 97\n" ++
        "t \\66 \\0x62\n" ++
        "t \\0x100 \\0x101\n";
    var p = try Program.parse(testing.allocator, src, "num.flc", &diag);
    defer p.deinit();
    try testing.expectEqual(@as(u21, 'a'), p.apply('A'));
    try testing.expectEqual(@as(u21, 'b'), p.apply('B'));
    try testing.expectEqual(@as(u21, 0x101), p.apply(0x100));
}

test "control file: .tlc is the same grammar and keeps its name" {
    var diag: Diag = .{};
    var p = try Program.parse(testing.allocator, "t A B\n", "map.tlc", &diag);
    defer p.deinit();
    try testing.expectEqualStrings("map.tlc", p.name);
    try testing.expectEqual(@as(u21, 'B'), p.apply('A'));
}

test "control file: malformed ranges are rejected" {
    var diag: Diag = .{};
    try testing.expectError(
        error.InvalidControlFile,
        Program.parse(testing.allocator, "t Z-A z-a\n", "bad.flc", &diag),
    );
}
