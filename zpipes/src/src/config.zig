const std = @import("std");
const posix = std.posix;
const term = @import("term.zig");
const palette = @import("palette.zig");
const pipe = @import("pipe.zig");

/// 默认只用 heavy 一种（pipes.sh 的 `-t 0`、pipes-rs 的 `KindSet::from_one(Heavy)`）。
/// 以前这里塞了全部 7 种，直接跑 `zpipes` 会同时冒出粗线、细线、圆角、双线、
/// 半方块、锯齿和圆点——看起来像"各种形态的线条"，而不是一条管道。
const default_kinds = [8]pipe.Kind{
    .heavy, .heavy, .heavy, .heavy, .heavy, .heavy, .heavy, .heavy,
};

pub const Config = struct {
    help: bool = false,
    version: bool = false,
    license: bool = false,

    colors: palette.Colors = .{},
    rainbow: u8 = 0,
    inherit_style: bool = false,
    kinds: [8]pipe.Kind = default_kinds,
    kind_count: usize = 1,

    fps: u32 = 50,
    fps_set: bool = false,
    fps_from_cli: bool = false,
    delay_ms: u32 = 20,
    delay_set: bool = false,
    delay_from_cli: bool = false,

    speed: u32 = 1,
    cpf: u32 = 1,
    pipe_count: usize = 1,
    max_length: u32 = 0,
    max_total_length: u32 = 0,
    turn_chance: f32 = 0.15,
    reset_threshold: f32 = 0.5,
};

pub fn configFail(path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "invalid value";
    term.print(posix.STDERR_FILENO, "zpipes: {s}:{d}: {s}\n", .{ path, line, msg }) catch {};
    return error.InvalidConfig;
}

fn keyIs(key: []const u8, normalized: []const u8) bool {
    if (key.len != normalized.len) return false;
    for (key, normalized) |a, b| {
        const na: u8 = if (a == '-') '_' else a;
        if (na != b) return false;
    }
    return true;
}

fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |ch, i| {
        if (quote == 0) {
            if (ch == '"' or ch == '\'') {
                quote = ch;
            } else if (ch == '#') {
                return line[0..i];
            }
        } else if (ch == quote) {
            quote = 0;
        }
    }
    return line;
}

fn unquote(path: []const u8, line: usize, value: []const u8) error{InvalidConfig}![]const u8 {
    if (value.len == 0) return value;
    if (value[0] == '"' or value[0] == '\'') {
        if (value.len < 2 or value[value.len - 1] != value[0]) {
            return configFail(path, line, "unterminated string", .{});
        }
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseU32Value(path: []const u8, line: usize, key: []const u8, value: []const u8, min: u32, max: u32) error{InvalidConfig}!u32 {
    const n = std.fmt.parseInt(u32, value, 10) catch
        return configFail(path, line, "invalid integer for '{s}': '{s}'", .{ key, value });
    if (n < min or n > max) {
        return configFail(path, line, "value for '{s}' must be between {d} and {d}", .{ key, min, max });
    }
    return n;
}

fn parseFractionValue(path: []const u8, line: usize, key: []const u8, value: []const u8, min: f32) error{InvalidConfig}!f32 {
    const v = std.fmt.parseFloat(f32, value) catch
        return configFail(path, line, "invalid number for '{s}': '{s}'", .{ key, value });
    if (!(v >= min and v <= 1.0)) {
        return configFail(path, line, "value for '{s}' must be between {d} and 1.0", .{ key, min });
    }
    return v;
}

fn parseBoolValue(path: []const u8, line: usize, key: []const u8, value: []const u8) error{InvalidConfig}!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return configFail(path, line, "value for '{s}' must be true or false", .{key});
}

fn applyColorList(path: []const u8, line: usize, cfg: *Config, value: []const u8) error{InvalidConfig}!void {
    cfg.colors.explicit_len = 0;
    cfg.colors.next_explicit = 0;
    cfg.colors.addExplicit(value) catch
        return configFail(path, line, "color must be comma-separated numbers 1-255", .{});
}

fn applyKindList(path: []const u8, line: usize, cfg: *Config, value: []const u8) error{InvalidConfig}!void {
    cfg.kind_count = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) return configFail(path, line, "kind list contains an empty name", .{});
        const k = pipe.parseKind(part) orelse
            return configFail(path, line, "unknown pipe kind '{s}'", .{part});

        var duplicate = false;
        for (cfg.kinds[0..cfg.kind_count]) |existing| {
            if (existing == k) duplicate = true;
        }
        if (!duplicate) {
            if (cfg.kind_count >= cfg.kinds.len) {
                return configFail(path, line, "too many pipe kinds", .{});
            }
            cfg.kinds[cfg.kind_count] = k;
            cfg.kind_count += 1;
        }
    }
    if (cfg.kind_count == 0) return configFail(path, line, "kind list is empty", .{});
}

/// 只支持 key = value、# 注释；[section] 行被忽略。
pub fn parseToml(cfg: *Config, text: []const u8, path: []const u8) error{InvalidConfig}!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    var fps_line: ?usize = null;
    var delay_line: ?usize = null;

    while (lines.next()) |raw_line| {
        line_no += 1;
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = stripComment(line);
        line = std.mem.trim(u8, line, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                return configFail(path, line_no, "invalid section header", .{});
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            return configFail(path, line_no, "expected key = value", .{});
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return configFail(path, line_no, "empty key", .{});
        const value = try unquote(path, line_no, raw_value);

        if (keyIs(key, "color_mode")) {
            cfg.colors.color_mode = palette.parseColorMode(value) catch
                return configFail(path, line_no, "color_mode must be ansi, rgb or none", .{});
        } else if (keyIs(key, "theme")) {
            cfg.colors.theme = palette.parseTheme(value) catch
                return configFail(path, line_no, "theme must be default, darker, pastel or matrix", .{});
        } else if (keyIs(key, "palette")) {
            cfg.colors.palette = palette.parseMode(value) catch
                return configFail(path, line_no, "palette must be 8, 16, 88 or 256", .{});
        } else if (keyIs(key, "color")) {
            try applyColorList(path, line_no, cfg, value);
        } else if (keyIs(key, "rainbow")) {
            cfg.rainbow = @intCast(try parseU32Value(path, line_no, key, value, 0, 255));
        } else if (keyIs(key, "bold")) {
            cfg.colors.bold = try parseBoolValue(path, line_no, key, value);
        } else if (keyIs(key, "inherit_style")) {
            cfg.inherit_style = try parseBoolValue(path, line_no, key, value);
        } else if (keyIs(key, "kind")) {
            try applyKindList(path, line_no, cfg, value);
        } else if (keyIs(key, "fps")) {
            if (delay_line) |dl| {
                return configFail(path, line_no, "fps and delay are mutually exclusive (delay set on line {d})", .{dl});
            }
            cfg.fps = try parseU32Value(path, line_no, key, value, 0, 1000);
            cfg.fps_set = true;
            fps_line = line_no;
        } else if (keyIs(key, "delay") or keyIs(key, "delay_ms")) {
            if (fps_line) |fl| {
                return configFail(path, line_no, "fps and delay are mutually exclusive (fps set on line {d})", .{fl});
            }
            cfg.delay_ms = try parseU32Value(path, line_no, key, value, 0, 60_000);
            cfg.delay_set = true;
            delay_line = line_no;
        } else if (keyIs(key, "speed")) {
            cfg.speed = try parseU32Value(path, line_no, key, value, 1, 100);
        } else if (keyIs(key, "cpf")) {
            cfg.cpf = try parseU32Value(path, line_no, key, value, 1, 100);
        } else if (keyIs(key, "pipe_count")) {
            cfg.pipe_count = @intCast(try parseU32Value(path, line_no, key, value, 1, 512));
        } else if (keyIs(key, "max_length")) {
            cfg.max_length = try parseU32Value(path, line_no, key, value, 0, 1_000_000);
        } else if (keyIs(key, "max_total_length")) {
            cfg.max_total_length = try parseU32Value(path, line_no, key, value, 0, 1_000_000);
        } else if (keyIs(key, "turn")) {
            cfg.turn_chance = try parseFractionValue(path, line_no, key, value, 0.0);
        } else if (keyIs(key, "reset")) {
            cfg.reset_threshold = try parseFractionValue(path, line_no, key, value, 0.1);
        } else {
            return configFail(path, line_no, "unknown key '{s}'", .{key});
        }
    }
}

test "TOML 解析 key = value、注释、section 和类型" {
    var cfg = Config{};
    const text =
        \\# sample config
        \\fps = 0
        \\speed = 2
        \\cpf = 3
        \\pipe_count = 4
        \\max_length = 9
        \\max_total_length = 20
        \\turn = 0.25
        \\reset = 0.5
        \\[colors]
        \\color_mode = "rgb"
        \\theme = "pastel"
        \\palette = 256
        \\rainbow = 7
        \\bold = true
        \\inherit_style = true
        \\color = "2,4,6"
        \\kind = "heavy,dots"
    ;
    try parseToml(&cfg, text, "memory.toml");

    try std.testing.expectEqual(@as(u32, 0), cfg.fps);
    try std.testing.expect(cfg.fps_set);
    try std.testing.expectEqual(@as(u32, 2), cfg.speed);
    try std.testing.expectEqual(@as(u32, 3), cfg.cpf);
    try std.testing.expectEqual(@as(usize, 4), cfg.pipe_count);
    try std.testing.expectEqual(@as(u32, 9), cfg.max_length);
    try std.testing.expectEqual(@as(u32, 20), cfg.max_total_length);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cfg.turn_chance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cfg.reset_threshold, 0.001);
    try std.testing.expectEqual(palette.ColorMode.rgb, cfg.colors.color_mode);
    try std.testing.expectEqual(palette.Theme.pastel, cfg.colors.theme);
    try std.testing.expectEqual(palette.Mode.c256, cfg.colors.palette);
    try std.testing.expectEqual(@as(u8, 7), cfg.rainbow);
    try std.testing.expect(cfg.colors.bold);
    try std.testing.expect(cfg.inherit_style);
    try std.testing.expectEqual(@as(usize, 3), cfg.colors.explicit_len);
    try std.testing.expectEqual(@as(usize, 2), cfg.kind_count);
    try std.testing.expectEqual(pipe.Kind.heavy, cfg.kinds[0]);
    try std.testing.expectEqual(pipe.Kind.dots, cfg.kinds[1]);
}

test "TOML 中 fps 与 delay 冲突、非法值都报错" {
    var cfg = Config{};
    try std.testing.expectError(error.InvalidConfig, parseToml(&cfg, "fps = 20\ndelay = 10\n", "bad.toml"));

    var cfg2 = Config{};
    try std.testing.expectError(error.InvalidConfig, parseToml(&cfg2, "speed = 0\n", "bad.toml"));
}
