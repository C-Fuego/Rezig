//! 时间计算：unix 秒 → 公历（无 libc 的 localtime），12/24 小时制，
//! 以及 tty-clock 用到的 strftime 子集。全部纯函数，方便单测。
const std = @import("std");
const linux = std.os.linux;

pub const Civil = struct {
    year: i32 = 1970,
    month: u8 = 1,
    day: u8 = 1,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// 0 = 周日 … 6 = 周六（与 struct tm 的 tm_wday 一致）
    weekday: u8 = 4,
    /// 1-366（tm_yday + 1）
    yday: u16 = 1,
    isdst: bool = false,
};

/// CLOCK_REALTIME → unix 秒。std.time.timestamp 在 0.17 已删除。
pub fn nowUnix() i64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @intCast(ts.sec);
}

pub const Ymd = struct { year: i32, month: u8, day: u8 };

/// Howard Hinnant 的 days_from_civil：1970-01-01 记为 0。
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // 3 月当作一年的开始
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(z_in: i64) Ymd {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(y + @as(i64, if (m <= 2) 1 else 0)),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// unix 秒 + 时区偏移（秒） → 公历时间。
pub fn civilFromUnix(unix: i64, offset: i32) Civil {
    const local = unix + @as(i64, offset);
    const days = @divFloor(local, 86400);
    const secs_of_day = local - days * 86400;
    const ymd = civilFromDays(days);
    const doy = days - daysFromCivil(ymd.year, 1, 1) + 1;
    // 1970-01-01 是周四
    const wd = @mod(days + 4, 7);
    return .{
        .year = ymd.year,
        .month = ymd.month,
        .day = ymd.day,
        .hour = @intCast(@divTrunc(secs_of_day, 3600)),
        .minute = @intCast(@divTrunc(@mod(secs_of_day, 3600), 60)),
        .second = @intCast(@mod(secs_of_day, 60)),
        .weekday = @intCast(wd),
        .yday = @intCast(doy),
    };
}

/// 12 小时制的小时数：0 → 12，13 → 1，12 → 12。
pub fn hour12(hour: u8) u8 {
    const h = if (hour > 12) hour - 12 else hour;
    return if (h == 0) 12 else h;
}

pub const AMSIGN = " [AM]";
pub const PMSIGN = " [PM]";

pub fn meridiem(hour: u8) []const u8 {
    return if (hour >= 12) PMSIGN else AMSIGN;
}

/// 拆成两位数字（tty-clock 里 date.hour[2] / minute[2] / second[2]）。
pub fn twoDigits(value: u8) [2]u8 {
    return .{ value / 10, value % 10 };
}

// ------------------------------------------------------------ strftime 子集

pub const FormatContext = struct {
    tzname: []const u8 = "UTC",
    offset: i32 = 0,
    unix: i64 = 0,
    /// 12 小时制下的 AM/PM 文本
    am: []const u8 = "AM",
    pm: []const u8 = "PM",
};

const weekday_long = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const weekday_short = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_long = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const month_short = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const Appender = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Appender, s: []const u8) void {
        if (self.len >= self.buf.len) return;
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn num(self: *Appender, value: i64, width: usize, pad: u8) void {
        var tmp: [24]u8 = undefined;
        const neg = value < 0;
        var v: u64 = if (neg) @intCast(-value) else @intCast(value);
        var i: usize = tmp.len;
        if (v == 0) {
            i -= 1;
            tmp[i] = '0';
        }
        while (v != 0) {
            i -= 1;
            tmp[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
        var digits: usize = tmp.len - i;
        if (neg) {
            i -= 1;
            tmp[i] = '-';
            digits += 1;
        }
        while (digits < width) : (digits += 1) {
            i -= 1;
            tmp[i] = pad;
        }
        self.put(tmp[i..]);
    }
};

/// 支持：%a %A %b %B %c %C %d %D %e %F %H %I %j %k %l %m %M %n %p %P %r %R %s
/// %S %t %T %u %w %x %X %y %Y %z %Z %% （忽略 %E / %O 修饰符与宽度标志）。
/// 不支持 locale 翻译（原版只有 setlocale(LC_TIME,"")，C locale 下才是英文）。
pub fn strftime(buf: []u8, fmt: []const u8, c: Civil, ctx: FormatContext) []const u8 {
    var w = Appender{ .buf = buf };
    var i: usize = 0;
    while (i < fmt.len) {
        const ch = fmt[i];
        if (ch != '%') {
            w.put(fmt[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        // 跳过 %E / %O 之类的修饰符
        var spec = fmt[i];
        if ((spec == 'E' or spec == 'O') and i + 1 < fmt.len) {
            i += 1;
            spec = fmt[i];
        }
        i += 1;
        const wd = @min(@as(usize, c.weekday), 6);
        const mo = @min(@as(usize, c.month), 12) -| 1;
        switch (spec) {
            'a' => w.put(weekday_short[wd]),
            'A' => w.put(weekday_long[wd]),
            'b', 'h' => w.put(month_short[mo]),
            'B' => w.put(month_long[mo]),
            'c' => {
                w.put(weekday_short[wd]);
                w.put(" ");
                w.put(month_short[mo]);
                w.put(" ");
                w.num(@intCast(c.day), 2, ' ');
                w.put(" ");
                w.num(@intCast(c.hour), 2, '0');
                w.put(":");
                w.num(@intCast(c.minute), 2, '0');
                w.put(":");
                w.num(@intCast(c.second), 2, '0');
                w.put(" ");
                w.num(@intCast(c.year), 4, '0');
            },
            'C' => w.num(@divFloor(@as(i64, c.year), 100), 2, '0'),
            'd' => w.num(@intCast(c.day), 2, '0'),
            'D' => {
                w.num(@intCast(c.month), 2, '0');
                w.put("/");
                w.num(@intCast(c.day), 2, '0');
                w.put("/");
                w.num(@mod(@as(i64, c.year), 100), 2, '0');
            },
            'e' => w.num(@intCast(c.day), 2, ' '),
            'F' => {
                w.num(@intCast(c.year), 4, '0');
                w.put("-");
                w.num(@intCast(c.month), 2, '0');
                w.put("-");
                w.num(@intCast(c.day), 2, '0');
            },
            'H' => w.num(@intCast(c.hour), 2, '0'),
            'k' => w.num(@intCast(c.hour), 2, ' '),
            'I' => w.num(@intCast(hour12(c.hour)), 2, '0'),
            'l' => w.num(@intCast(hour12(c.hour)), 2, ' '),
            'j' => w.num(@intCast(c.yday), 3, '0'),
            'm' => w.num(@intCast(c.month), 2, '0'),
            'M' => w.num(@intCast(c.minute), 2, '0'),
            'n' => w.put("\n"),
            'p' => w.put(if (c.hour >= 12) ctx.pm else ctx.am),
            'P' => w.put(if (c.hour >= 12) "pm" else "am"),
            'r' => {
                w.num(@intCast(hour12(c.hour)), 2, '0');
                w.put(":");
                w.num(@intCast(c.minute), 2, '0');
                w.put(":");
                w.num(@intCast(c.second), 2, '0');
                w.put(" ");
                w.put(if (c.hour >= 12) ctx.pm else ctx.am);
            },
            'R' => {
                w.num(@intCast(c.hour), 2, '0');
                w.put(":");
                w.num(@intCast(c.minute), 2, '0');
            },
            's' => w.num(ctx.unix, 1, '0'),
            'S' => w.num(@intCast(c.second), 2, '0'),
            't' => w.put("\t"),
            'T', 'X' => {
                w.num(@intCast(c.hour), 2, '0');
                w.put(":");
                w.num(@intCast(c.minute), 2, '0');
                w.put(":");
                w.num(@intCast(c.second), 2, '0');
            },
            'u' => w.num(@intCast(if (c.weekday == 0) 7 else c.weekday), 1, '0'),
            'w' => w.num(@intCast(c.weekday), 1, '0'),
            'x' => {
                w.num(@intCast(c.month), 2, '0');
                w.put("/");
                w.num(@intCast(c.day), 2, '0');
                w.put("/");
                w.num(@mod(@as(i64, c.year), 100), 2, '0');
            },
            'y' => w.num(@mod(@as(i64, c.year), 100), 2, '0'),
            'Y' => w.num(@intCast(c.year), 4, '0'),
            'z' => {
                const off: i64 = ctx.offset;
                const sign: u8 = if (off < 0) '-' else '+';
                const abs: u64 = @intCast(if (off < 0) -off else off);
                w.put(&[_]u8{sign});
                w.num(@intCast(abs / 3600), 2, '0');
                w.num(@intCast((abs % 3600) / 60), 2, '0');
            },
            'Z' => w.put(ctx.tzname),
            '%' => w.put("%"),
            else => {
                // 未知转换：原样输出
                w.put("%");
                w.put(&[_]u8{spec});
            },
        }
    }
    return buf[0..w.len];
}

// ------------------------------------------------------------------- tests

test "daysFromCivil round-trips known dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 19723), daysFromCivil(2024, 1, 1));
    try std.testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    var d: i64 = 0;
    while (d < 40000) : (d += 997) {
        const ymd = civilFromDays(d);
        try std.testing.expectEqual(d, daysFromCivil(ymd.year, ymd.month, ymd.day));
    }
}

test "civilFromUnix handles UTC, +08:00 and leap days" {
    // 2026-11-08T00:00:00Z（本机运行时刻）
    const t: i64 = 1794096000;
    const utc = civilFromUnix(t, 0);
    try std.testing.expectEqual(@as(i32, 2026), utc.year);
    try std.testing.expectEqual(@as(u8, 11), utc.month);
    try std.testing.expectEqual(@as(u8, 8), utc.day);
    try std.testing.expectEqual(@as(u8, 0), utc.hour);
    try std.testing.expectEqual(@as(u8, 0), utc.minute);
    try std.testing.expectEqual(@as(u8, 0), utc.second);

    // 同样的瞬间在 UTC+8 是 08:00，日期不变
    const east8 = civilFromUnix(t, 8 * 3600);
    try std.testing.expectEqual(@as(u8, 8), east8.hour);
    try std.testing.expectEqual(@as(u8, 8), east8.day);

    // 往前 9 小时到 UTC+8 仍是 11-07
    const prev = civilFromUnix(t - 9 * 3600, 8 * 3600);
    try std.testing.expectEqual(@as(u8, 7), prev.day);
    try std.testing.expectEqual(@as(u8, 23), prev.hour);

    // 闰日：2024-02-29T00:00:00Z
    const leap = civilFromUnix(1709164800, 0);
    try std.testing.expectEqual(@as(i32, 2024), leap.year);
    try std.testing.expectEqual(@as(u8, 2), leap.month);
    try std.testing.expectEqual(@as(u8, 29), leap.day);
    try std.testing.expectEqual(@as(u16, 60), leap.yday);
    try std.testing.expectEqual(@as(u8, 4), leap.weekday); // 周四
}

test "12h conversion follows tty-clock rules" {
    try std.testing.expectEqual(@as(u8, 12), hour12(0)); // 00:xx → 12 AM
    try std.testing.expectEqual(@as(u8, 1), hour12(1));
    try std.testing.expectEqual(@as(u8, 11), hour12(11));
    try std.testing.expectEqual(@as(u8, 12), hour12(12)); // 12 → 12 PM
    try std.testing.expectEqual(@as(u8, 1), hour12(13));
    try std.testing.expectEqual(@as(u8, 11), hour12(23));

    try std.testing.expectEqualStrings(" [AM]", meridiem(0));
    try std.testing.expectEqualStrings(" [AM]", meridiem(11));
    try std.testing.expectEqualStrings(" [PM]", meridiem(12));
    try std.testing.expectEqualStrings(" [PM]", meridiem(23));

    try std.testing.expectEqual([2]u8{ 0, 7 }, twoDigits(7));
    try std.testing.expectEqual([2]u8{ 5, 9 }, twoDigits(59));
}

test "strftime default %F and custom formats" {
    var buf: [128]u8 = undefined;
    const c = Civil{ .year = 2026, .month = 11, .day = 8, .hour = 20, .minute = 5, .second = 9, .weekday = 0, .yday = 312 };
    const ctx = FormatContext{ .tzname = "CST", .offset = 8 * 3600, .unix = 1794096000 };

    try std.testing.expectEqualStrings("2026-11-08", strftime(&buf, "%F", c, ctx));
    try std.testing.expectEqualStrings("Sunday, 08 November", strftime(&buf, "%A, %d %B", c, ctx));
    try std.testing.expectEqualStrings("20:05:09", strftime(&buf, "%T", c, ctx));
    try std.testing.expectEqualStrings("08:05:09 PM", strftime(&buf, "%r", c, ctx));
    try std.testing.expectEqualStrings("11/08/26", strftime(&buf, "%D", c, ctx)); // %m/%d/%y
    try std.testing.expectEqualStrings("+0800 CST", strftime(&buf, "%z %Z", c, ctx));
    try std.testing.expectEqualStrings("100% 312", strftime(&buf, "100%% %j", c, ctx));
    // 字面的 h / M 不需要转义；不认识的 %- 原样输出
    try std.testing.expectEqualStrings("20h %-Mm", strftime(&buf, "%Hh %-Mm", c, ctx));
    try std.testing.expectEqualStrings(" 8 Nov 2026 08 PM", strftime(&buf, "%e %h %Y %I %p", c, ctx));
    // 未知转换原样输出
    try std.testing.expectEqualStrings("%Q", strftime(&buf, "%Q", c, ctx));
}
