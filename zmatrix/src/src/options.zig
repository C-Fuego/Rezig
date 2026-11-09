//! 命令行解析（手写 getopt 风格，不引第三方依赖）。
//! 取值语义与 cmatrix 的 getopt 串 `abBcfhlLnrosmxkVM:u:C:t:` 对齐。
const std = @import("std");
const charset = @import("charset.zig");
const color = @import("color.zig");

/// 粗体档位。cmatrix 里 bold 是个 int：
///   0 = 不加粗（默认）；-1 = 仅头部加粗（-n 的实际效果）；
///   1 = 头部加粗 + 尾部隔字加粗（-b）；2 = 全部加粗（-B）。
pub const Bold = enum(u8) {
    none = 0,
    head = 1,
    dither = 2,
    all = 3,
};

pub const Config = struct {
    delay: u8 = 4,
    async_scroll: bool = false,
    oldstyle: bool = false,
    bold: Bold = .none,
    color: color.Name = .green,
    rainbow: bool = false,
    screensaver: bool = false,
    mutate: bool = false,
    charset: charset.Kind = .ascii,
    custom_chars: []const u21 = &.{},
    message: ?[]const u8 = null,
    message_chars: []const u21 = &.{},
    x_mode: bool = false,
    lambda: bool = false,
    /// 非 cmatrix 扩展：256 色渐隐色阶。
    fade: bool = false,
};

pub const Result = struct {
    cfg: Config = .{},
    help: bool = false,
    version: bool = false,
};

pub const ParseError = error{
    BadArgument,
    MissingValue,
    BadValue,
    OutOfMemory,
};

/// argv 不含程序名。支持 -ab 聚合，以及 -u4 / -u 4 两种取值写法。
pub fn parse(gpa: std.mem.Allocator, argv: []const []const u8) ParseError!Result {
    var res = Result{};
    var ai: usize = 0;
    while (ai < argv.len) : (ai += 1) {
        const arg = argv[ai];
        if (arg.len == 0 or arg[0] != '-') return error.BadArgument;
        if (std.mem.eql(u8, arg, "--help")) {
            res.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            res.version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fade")) {
            res.cfg.fade = true;
            continue;
        }
        if (arg.len == 1) return error.BadArgument;

        var i: usize = 1;
        while (i < arg.len) : (i += 1) {
            const flag = arg[i];
            switch (flag) {
                'a' => res.cfg.async_scroll = true,
                // cmatrix: if (bold != 2) bold = 1;
                'b' => if (res.cfg.bold != .all) {
                    res.cfg.bold = .dither;
                },
                'B' => res.cfg.bold = .all,
                'n' => res.cfg.bold = .head,
                'c' => res.cfg.charset = .katakana,
                'f' => {}, // cmatrix 的 -f 只改 $TERM，纯 ANSI 输出下不需要
                'k' => res.cfg.mutate = true,
                'm' => res.cfg.lambda = true,
                'o' => res.cfg.oldstyle = true,
                'r' => res.cfg.rainbow = true,
                's' => res.cfg.screensaver = true,
                'x' => res.cfg.x_mode = true,
                'h' => res.help = true,
                'V' => res.version = true,
                'u', 'C', 'l', 'M' => {
                    var val: []const u8 = undefined;
                    if (i + 1 < arg.len) {
                        val = arg[i + 1 ..];
                        i = arg.len; // 值已吃掉剩余字符
                    } else {
                        ai += 1;
                        if (ai >= argv.len) return error.MissingValue;
                        val = argv[ai];
                    }
                    switch (flag) {
                        'u' => {
                            const v = std.fmt.parseInt(u8, val, 10) catch return error.BadValue;
                            if (v > 10) return error.BadValue;
                            res.cfg.delay = v;
                        },
                        'C' => res.cfg.color = color.parseName(val) orelse return error.BadValue,
                        'l' => {
                            res.cfg.custom_chars = charset.parseCodepoints(gpa, val) catch
                                return error.OutOfMemory;
                            res.cfg.charset = .custom;
                        },
                        'M' => {
                            res.cfg.message = gpa.dupe(u8, val) catch return error.OutOfMemory;
                            res.cfg.message_chars = charset.parseCodepoints(gpa, val) catch
                                return error.OutOfMemory;
                        },
                        else => unreachable,
                    }
                },
                else => return error.BadArgument,
            }
        }
    }
    return res;
}

// ------------------------------------------------------------------ tests

test "parse clustered flags and attached value" {
    const argv = [_][]const u8{ "-ack", "-u7", "-C", "blue" };
    const res = try parse(std.testing.allocator, &argv);
    defer if (res.cfg.custom_chars.len != 0) std.testing.allocator.free(res.cfg.custom_chars);
    try std.testing.expect(res.cfg.async_scroll);
    try std.testing.expect(res.cfg.mutate);
    try std.testing.expectEqual(charset.Kind.katakana, res.cfg.charset);
    try std.testing.expectEqual(@as(u8, 7), res.cfg.delay);
    try std.testing.expectEqual(color.Name.blue, res.cfg.color);
}

test "bold flags follow cmatrix precedence" {
    // 默认：完全不加粗
    const d = try parse(std.testing.allocator, &.{});
    try std.testing.expectEqual(Bold.none, d.cfg.bold);

    const b = try parse(std.testing.allocator, &.{"-b"});
    try std.testing.expectEqual(Bold.dither, b.cfg.bold);

    const bb = try parse(std.testing.allocator, &.{ "-b", "-B" });
    try std.testing.expectEqual(Bold.all, bb.cfg.bold);

    // -B 之后再 -b：cmatrix 里 bold 已是 2，-b 不会降级
    const bbb = try parse(std.testing.allocator, &.{ "-B", "-b" });
    try std.testing.expectEqual(Bold.all, bbb.cfg.bold);

    const n = try parse(std.testing.allocator, &.{"-n"});
    try std.testing.expectEqual(Bold.head, n.cfg.bold);
}

test "parse -l custom chars and -M message" {
    const argv = [_][]const u8{ "-l", "01あ", "-M", "hi" };
    const res = try parse(std.testing.allocator, &argv);
    defer std.testing.allocator.free(res.cfg.custom_chars);
    defer std.testing.allocator.free(res.cfg.message_chars);
    defer std.testing.allocator.free(res.cfg.message.?);
    try std.testing.expectEqual(charset.Kind.custom, res.cfg.charset);
    try std.testing.expectEqual(@as(usize, 3), res.cfg.custom_chars.len);
    try std.testing.expectEqual(@as(u21, 0x3042), res.cfg.custom_chars[2]);
    try std.testing.expectEqual(@as(usize, 2), res.cfg.message_chars.len);
}

test "parse -m lambda, -f compat and --fade" {
    const argv = [_][]const u8{ "-mf", "--fade" };
    const res = try parse(std.testing.allocator, &argv);
    try std.testing.expect(res.cfg.lambda);
    try std.testing.expect(res.cfg.fade);
}

test "reject bad arguments" {
    const argv1 = [_][]const u8{"-Z"};
    try std.testing.expectError(error.BadArgument, parse(std.testing.allocator, &argv1));
    const argv2 = [_][]const u8{ "-u", "11" };
    try std.testing.expectError(error.BadValue, parse(std.testing.allocator, &argv2));
    const argv3 = [_][]const u8{"-C"};
    try std.testing.expectError(error.MissingValue, parse(std.testing.allocator, &argv3));
}
