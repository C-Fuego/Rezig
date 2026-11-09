//! 命令行解析：严格按 tty-clock 原版 getopt 串 "iuvsScbtrhBxnDC:f:d:T:a:"
//! 的语义（含 -C4 / -C 4 两种取值写法、合并短选项、非选项参数忽略）。
const std = @import("std");

pub const Config = struct {
    /// -s 显示秒
    second: bool = false,
    /// -S 屏保模式（任意键退出）
    screensaver: bool = false,
    /// -t 12 小时制
    twelve: bool = false,
    /// -c 居中
    center: bool = false,
    /// -r 反弹
    rebound: bool = false,
    /// -D 隐藏日期（默认显示）
    date: bool = true,
    /// -u UTC
    utc: bool = false,
    /// -x 边框
    box: bool = false,
    /// -n 按键不退出
    noquit: bool = false,
    /// -f 日期格式（默认 %F，与原版一致）
    format: []const u8 = "%F",
    /// -C 颜色 0-7（默认 2 = 绿，与原版 COLOR_GREEN 一致）
    color: u8 = 2,
    /// -b 粗体（原版实际是 A_BLINK + 日期加粗）
    bold: bool = false,
    /// -d 重绘间隔（秒），默认 1
    delay: u32 = 1,
    /// -B 冒号闪烁
    blink: bool = false,
    /// -a 额外纳秒延迟
    nsdelay: u32 = 0,
    /// -T 输出到指定 tty
    tty: ?[]const u8 = null,
};

pub const Action = enum { run, help, version, info, usage_error };

pub const Result = struct {
    cfg: Config = .{},
    action: Action = .run,
};

/// tty-clock 的 atoi/atol 近似：取开头的可选符号 + 数字，没有数字算 0。
fn cAtoi(s: []const u8) i64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var value: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        value = value * 10 + (s[i] - '0');
        if (value > 1 << 40) break;
    }
    return if (neg) -value else value;
}

/// 颜色名（原版只认 0-7；名字是 zclock 的扩展，帮助里注明）。
pub fn colorByName(name: []const u8) ?u8 {
    const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };
    for (names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(name, n)) return @intCast(i);
    }
    return null;
}

/// 返回 null 表示"保持原值"（原版：-C 只在 0-7 范围内才赋值）。
fn parseColor(arg: []const u8) ?u8 {
    if (arg.len == 1 and arg[0] >= '0' and arg[0] <= '7') return arg[0] - '0';
    if (colorByName(arg)) |c| return c;
    // atoi 语义：非数字开头算 0
    const v = cAtoi(arg);
    if (v >= 0 and v < 8) return @intCast(v);
    return null;
}

/// argv 不含程序名。返回值里的切片指向 argv 自身，不需要分配。
pub fn parse(argv: []const []const u8) Result {
    var res = Result{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (arg.len < 2 or arg[0] != '-') continue; // 非选项参数：getopt 会跳过
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.startsWith(u8, arg, "--")) {
            // 原版用 getopt（不支持长选项），这里把 --help/--version/--info 当等价短选项
            if (std.mem.eql(u8, arg, "--help")) {
                res.action = .help;
                return res;
            }
            if (std.mem.eql(u8, arg, "--version")) {
                res.action = .version;
                return res;
            }
            if (std.mem.eql(u8, arg, "--info")) {
                res.action = .info;
                return res;
            }
            res.action = .usage_error;
            return res;
        }

        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const flag = arg[j];
            var value: ?[]const u8 = null;
            switch (flag) {
                'C', 'f', 'd', 'T', 'a' => {
                    if (j + 1 < arg.len) {
                        value = arg[j + 1 ..];
                        j = arg.len; // 吃掉剩余字符
                    } else if (i + 1 < argv.len) {
                        i += 1;
                        value = argv[i];
                    } else {
                        res.action = .usage_error;
                        return res;
                    }
                },
                else => {},
            }
            switch (flag) {
                'h' => {
                    res.action = .help;
                    return res;
                },
                'v' => {
                    res.action = .version;
                    return res;
                },
                'i' => {
                    res.action = .info;
                    return res;
                },
                'u' => res.cfg.utc = true,
                's' => res.cfg.second = true,
                'S' => res.cfg.screensaver = true,
                'c' => res.cfg.center = true,
                'b' => res.cfg.bold = true,
                't' => res.cfg.twelve = true,
                'r' => res.cfg.rebound = true,
                'D' => res.cfg.date = false,
                'B' => res.cfg.blink = true,
                'x' => res.cfg.box = true,
                'n' => res.cfg.noquit = true,
                'C' => if (parseColor(value.?)) |c| {
                    res.cfg.color = c;
                },
                'f' => res.cfg.format = if (value.?.len > 99) value.?[0..99] else value.?,
                'd' => {
                    const v = cAtoi(value.?);
                    if (v >= 0 and v < 100) res.cfg.delay = @intCast(v);
                },
                'a' => {
                    const v = cAtoi(value.?);
                    if (v >= 0 and v < 1_000_000_000) res.cfg.nsdelay = @intCast(v);
                },
                'T' => res.cfg.tty = value.?,
                else => {
                    // getopt 对未知选项打印 invalid option，然后原版在 default 分支打 usage 并退出
                    res.action = .usage_error;
                    return res;
                },
            }
        }
    }
    return res;
}

const testing = std.testing;

test "defaults match tty-clock" {
    const r = parse(&.{});
    try testing.expectEqual(Action.run, r.action);
    try testing.expectEqual(false, r.cfg.second);
    try testing.expectEqual(true, r.cfg.date);
    try testing.expectEqual(@as(u8, 2), r.cfg.color);
    try testing.expectEqual(@as(u32, 1), r.cfg.delay);
    try testing.expectEqual(@as(u32, 0), r.cfg.nsdelay);
    try testing.expectEqualStrings("%F", r.cfg.format);
}

test "boolean flags and combined short options" {
    const r = parse(&.{ "-sScbtrnx", "-D" });
    try testing.expectEqual(Action.run, r.action);
    try testing.expect(r.cfg.second);
    try testing.expect(r.cfg.screensaver);
    try testing.expect(r.cfg.center);
    try testing.expect(r.cfg.bold);
    try testing.expect(r.cfg.twelve);
    try testing.expect(r.cfg.rebound);
    try testing.expect(r.cfg.noquit);
    try testing.expect(r.cfg.box);
    try testing.expect(!r.cfg.date);
}

test "options with values: -C4, -C 4, names, -f, -d, -a, -T" {
    const a = parse(&.{ "-C4" });
    try testing.expectEqual(@as(u8, 4), a.cfg.color);
    const b = parse(&.{ "-C", "6" });
    try testing.expectEqual(@as(u8, 6), b.cfg.color);
    const c = parse(&.{ "-Cred" });
    try testing.expectEqual(@as(u8, 1), c.cfg.color);
    // atoi 语义：没有数字 → 0 → 黑色（原版同样如此，不改默认绿）
    const d = parse(&.{ "-Cno-such-color" });
    try testing.expectEqual(@as(u8, 0), d.cfg.color);
    // 越界值不改写已有选择（原版：atoi 不在 0-7 就忽略）
    const g = parse(&.{ "-C5", "-C9" });
    try testing.expectEqual(@as(u8, 5), g.cfg.color);
    const e = parse(&.{ "-f", "%A %d %B", "-d", "5", "-a", "100000000" });
    try testing.expectEqualStrings("%A %d %B", e.cfg.format);
    try testing.expectEqual(@as(u32, 5), e.cfg.delay);
    try testing.expectEqual(@as(u32, 100_000_000), e.cfg.nsdelay);
    const f = parse(&.{ "-T", "/dev/tty9" });
    try testing.expectEqualStrings("/dev/tty9", f.cfg.tty.?);
}

test "out of range delays are ignored, help/version/info stop parsing" {
    const r = parse(&.{ "-d", "100", "-a", "2000000000" });
    try testing.expectEqual(@as(u32, 1), r.cfg.delay);
    try testing.expectEqual(@as(u32, 0), r.cfg.nsdelay);

    try testing.expectEqual(Action.help, parse(&.{"-h"}).action);
    try testing.expectEqual(Action.help, parse(&.{"--help"}).action);
    try testing.expectEqual(Action.version, parse(&.{"-v"}).action);
    try testing.expectEqual(Action.info, parse(&.{"-i"}).action);
    try testing.expectEqual(Action.usage_error, parse(&.{"-Z"}).action);
    try testing.expectEqual(Action.usage_error, parse(&.{"-C"}).action);
}
