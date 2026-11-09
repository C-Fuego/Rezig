//! 自己解析 TZif（RFC 8536）来拿"本地时间偏移"，因为没有 libc 就没有
//! localtime/gmtime。只做一件事：给定 unix 秒，返回当前生效的 utoff/abbr/isdst。
//!
//! 支持的 TZ 取值：
//!   - 不设 TZ            → 读 /etc/localtime（通常是 zoneinfo 的符号链接）
//!   - TZ=/usr/share/...  → 直接按路径读
//!   - TZ=Asia/Shanghai   → 读 /usr/share/zoneinfo/Asia/Shanghai
//!   - TZ=:Asia/Shanghai  → 同上（去掉冒号）
//! 不支持：POSIX TZ 规则串（形如 CET-1CEST,M3.5.0,M10.5.0/3）。
//! 名字/路径都找不到时退回 /etc/localtime；连它也读不出来就用 UTC。
const std = @import("std");
const term = @import("term.zig");

pub const Info = struct {
    offset: i32 = 0,
    isdst: bool = false,
    abbr: []const u8 = "UTC",
};

pub const Zone = struct {
    data: []const u8,
    time_size: usize,
    timecnt: usize,
    typecnt: usize,
    charcnt: usize,
    trans_off: usize,
    idx_off: usize,
    ttinfo_off: usize,
    abbrev_off: usize,

    fn readBE(data: []const u8, off: usize, comptime T: type) ?T {
        const n = @sizeOf(T);
        if (off + n > data.len) return null;
        var v: T = 0;
        for (0..n) |i| {
            v = (v << 8) | @as(T, data[off + i]);
        }
        return v;
    }

    fn transTime(self: Zone, i: usize) i64 {
        const off = self.trans_off + i * self.time_size;
        if (self.time_size == 8) {
            const raw = readBE(self.data, off, u64) orelse return 0;
            return @bitCast(raw);
        }
        const raw = readBE(self.data, off, u32) orelse return 0;
        return @as(i64, @as(i32, @bitCast(raw)));
    }

    fn typeIndex(self: Zone, i: usize) usize {
        const off = self.idx_off + i;
        if (off >= self.data.len) return 0;
        return self.data[off];
    }

    fn ttinfo(self: Zone, index: usize) Info {
        const idx = if (index < self.typecnt) index else 0;
        const off = self.ttinfo_off + idx * 6;
        const raw = readBE(self.data, off, u32) orelse return .{};
        const utoff: i32 = @bitCast(raw);
        const isdst = off + 4 < self.data.len and self.data[off + 4] != 0;
        const ai = if (off + 5 < self.data.len) self.data[off + 5] else 0;
        var abbr: []const u8 = "UTC";
        const start = self.abbrev_off + ai;
        if (start < self.abbrev_off + self.charcnt and start < self.data.len) {
            const rest = self.data[start..];
            const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
            if (end > 0) abbr = rest[0..end];
        }
        return .{ .offset = utoff, .isdst = isdst, .abbr = abbr };
    }

    /// 二分找最后一个 transition <= t。
    pub fn infoAt(self: Zone, t: i64) Info {
        var lo: usize = 0;
        var hi: usize = self.timecnt;
        var found: ?usize = null;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.transTime(mid) <= t) {
                found = mid;
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (found) |i| return self.ttinfo(self.typeIndex(i));
        // t 早于所有 transition：用第一个非 DST 类型，否则类型 0
        var i: usize = 0;
        while (i < self.typecnt) : (i += 1) {
            const info = self.ttinfo(i);
            if (!info.isdst) return info;
        }
        return self.ttinfo(0);
    }
};

const Header = struct {
    version: u8,
    isutcnt: usize,
    isstdcnt: usize,
    leapcnt: usize,
    timecnt: usize,
    typecnt: usize,
    charcnt: usize,
};

fn parseHeader(data: []const u8, off: usize) ?Header {
    if (off + 44 > data.len) return null;
    if (!std.mem.eql(u8, data[off .. off + 4], "TZif")) return null;
    const rd = struct {
        fn be32(d: []const u8, o: usize) usize {
            return (@as(usize, d[o]) << 24) | (@as(usize, d[o + 1]) << 16) |
                (@as(usize, d[o + 2]) << 8) | @as(usize, d[o + 3]);
        }
    };
    return .{
        .version = data[off + 4],
        .isutcnt = rd.be32(data, off + 20),
        .isstdcnt = rd.be32(data, off + 24),
        .leapcnt = rd.be32(data, off + 28),
        .timecnt = rd.be32(data, off + 32),
        .typecnt = rd.be32(data, off + 36),
        .charcnt = rd.be32(data, off + 40),
    };
}

fn blockSize(h: Header, time_size: usize) usize {
    return h.timecnt * time_size + h.timecnt + h.typecnt * 6 + h.charcnt +
        h.leapcnt * (time_size + 4) + h.isstdcnt + h.isutcnt;
}

pub fn parse(data: []const u8) ?Zone {
    const h1 = parseHeader(data, 0) orelse return null;
    if (h1.version >= '2') {
        const off2 = 44 + blockSize(h1, 4);
        const h2 = parseHeader(data, off2) orelse return null;
        return make(data, h2, off2 + 44, 8);
    }
    return make(data, h1, 44, 4);
}

fn make(data: []const u8, h: Header, base: usize, time_size: usize) ?Zone {
    if (h.typecnt == 0 or h.typecnt > 256) return null;
    const trans_off = base;
    const idx_off = trans_off + h.timecnt * time_size;
    const ttinfo_off = idx_off + h.timecnt;
    const abbrev_off = ttinfo_off + h.typecnt * 6;
    const end = abbrev_off + h.charcnt;
    if (end > data.len) return null;
    return .{
        .data = data,
        .time_size = time_size,
        .timecnt = h.timecnt,
        .typecnt = h.typecnt,
        .charcnt = h.charcnt,
        .trans_off = trans_off,
        .idx_off = idx_off,
        .ttinfo_off = ttinfo_off,
        .abbrev_off = abbrev_off,
    };
}

/// 按 TZ / /etc/localtime 找时区文件并解析；失败返回 null（调用方退回 UTC）。
pub fn loadLocal(alloc: std.mem.Allocator, tz_env: ?[]const u8) ?Zone {
    if (tz_env) |raw| {
        const spec = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        if (spec.len > 0) {
            if (spec[0] == '/') {
                if (loadPath(alloc, spec)) |z| return z;
            } else {
                const full = std.fmt.allocPrint(alloc, "/usr/share/zoneinfo/{s}", .{spec}) catch return null;
                if (loadPath(alloc, full)) |z| return z;
            }
        }
    }
    return loadPath(alloc, "/etc/localtime");
}

fn loadPath(alloc: std.mem.Allocator, path: []const u8) ?Zone {
    const zpath = allocSentinelPath(alloc, path) orelse return null;
    const data = term.readFileAlloc(alloc, zpath, 1024 * 1024) orelse return null;
    return parse(data);
}

fn allocSentinelPath(alloc: std.mem.Allocator, path: []const u8) ?[:0]u8 {
    const buf = alloc.allocSentinel(u8, path.len, 0) catch return null;
    @memcpy(buf[0..path.len], path);
    return buf;
}

// ------------------------------------------------------------------- tests

/// 手工拼一个 TZif v1 头 + 两条 transition 的最小文件，验证解析逻辑。
fn buildTestTzif(buf: *[256]u8) []const u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "TZif");
    buf[4] = '2';
    // 计数：isutcnt=0 isstdcnt=0 leapcnt=0 timecnt=2 typecnt=2 charcnt=8
    const counts = [_]u32{ 0, 0, 0, 2, 2, 8 };
    var off: usize = 20;
    for (counts) |c| {
        buf[off] = @intCast((c >> 24) & 0xff);
        buf[off + 1] = @intCast((c >> 16) & 0xff);
        buf[off + 2] = @intCast((c >> 8) & 0xff);
        buf[off + 3] = @intCast(c & 0xff);
        off += 4;
    }
    // v1 数据块（会被跳过）：timecnt*4 + timecnt + typecnt*6 + charcnt
    off = 44;
    // 简单起见 v1 块也填上内容
    const v1_size = 2 * 4 + 2 + 2 * 6 + 8;
    off += v1_size;
    // 第二个头
    @memcpy(buf[off .. off + 4], "TZif");
    buf[off + 4] = '2';
    var hoff: usize = off + 20;
    for (counts) |c| {
        buf[hoff] = @intCast((c >> 24) & 0xff);
        buf[hoff + 1] = @intCast((c >> 16) & 0xff);
        buf[hoff + 2] = @intCast((c >> 8) & 0xff);
        buf[hoff + 3] = @intCast(c & 0xff);
        hoff += 4;
    }
    off += 44;
    // transitions（8 字节，大端）：0 和 1000
    const t0: u64 = 0;
    const t1: u64 = 1000;
    inline for (0..8) |i| buf[off + i] = @intCast((t0 >> @intCast(8 * (7 - i))) & 0xff);
    off += 8;
    inline for (0..8) |i| buf[off + i] = @intCast((t1 >> @intCast(8 * (7 - i))) & 0xff);
    off += 8;
    // 类型索引
    buf[off] = 0;
    buf[off + 1] = 1;
    off += 2;
    // ttinfo：类型 0 = +3600 标准 "AAA"，类型 1 = +7200 DST "BBB"
    const putTt = struct {
        fn f(b: []u8, o: usize, utoff: i32, isdst: u8, ai: u8) void {
            const u: u32 = @bitCast(utoff);
            b[o] = @intCast((u >> 24) & 0xff);
            b[o + 1] = @intCast((u >> 16) & 0xff);
            b[o + 2] = @intCast((u >> 8) & 0xff);
            b[o + 3] = @intCast(u & 0xff);
            b[o + 4] = isdst;
            b[o + 5] = ai;
        }
    };
    putTt.f(buf, off, 3600, 0, 0);
    off += 6;
    putTt.f(buf, off, 7200, 1, 4);
    off += 6;
    // 缩略名区："AAA\0BBB\0"
    @memcpy(buf[off .. off + 8], "AAA\x00BBB\x00");
    off += 8;
    return buf[0..off];
}

test "TZif parsing picks the right utoff/abbr" {
    var raw: [256]u8 = undefined;
    const data = buildTestTzif(&raw);
    const zone = parse(data) orelse return error.ParseFailed;
    const before = zone.infoAt(-5);
    try std.testing.expectEqual(@as(i32, 3600), before.offset);
    try std.testing.expect(!before.isdst);
    try std.testing.expectEqualStrings("AAA", before.abbr);

    const after = zone.infoAt(1000);
    try std.testing.expectEqual(@as(i32, 7200), after.offset);
    try std.testing.expect(after.isdst);
    try std.testing.expectEqualStrings("BBB", after.abbr);

    try std.testing.expectEqual(@as(i32, 7200), zone.infoAt(10_000_000).offset);
}

test "parse rejects non-TZif input" {
    try std.testing.expect(parse("not a zoneinfo file at all........") == null);
    try std.testing.expect(parse("") == null);
}

test "system zoneinfo (if present) resolves a sane offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (loadLocal(arena.allocator(), null)) |zone| {
        const info = zone.infoAt(1794096000); // 2026-11-08T00:00:00Z
        try std.testing.expect(info.offset > -14 * 3600 and info.offset < 14 * 3600);
        try std.testing.expect(info.abbr.len > 0);
    }
}
