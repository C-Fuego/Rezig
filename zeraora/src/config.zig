const std = @import("std");
const app = @import("app.zig");

pub const Config = struct {
    /// One of en, fr, de, ja, zh_hans, zh_hant.
    language: []const u8 = "en",
    /// Probability that the random command picks a shiny.
    shiny_rate: f64 = 1.0 / 128.0,
};

const default_file_contents =
    \\language = "en"
    \\shiny_rate = 0.0078125
    \\
;

/// Reads $XDG_CONFIG_HOME/zeraora/config.toml, creating it with the defaults
/// when missing.
pub fn load(ctx: *app.Ctx) app.Fail!Config {
    const dir = configDir(ctx) orelse {
        return ctx.die("Configuration error: Failed to get config directory", .{});
    };
    const path = std.fmt.allocPrint(ctx.arena, "{s}/config.toml", .{dir}) catch {
        return ctx.die("Configuration error: Failed to load configuration file", .{});
    };

    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            writeDefault(ctx, dir, path) catch {
                return ctx.die("Configuration error: Failed to write config file", .{});
            };
            return .{};
        },
        else => return ctx.die("Configuration error: Failed to load configuration file", .{}),
    };

    return parse(text);
}

fn configDir(ctx: *app.Ctx) ?[]const u8 {
    const environ = ctx.environ;
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return std.fmt.allocPrint(ctx.arena, "{s}/zeraora", .{xdg}) catch null;
    }
    if (environ.get("HOME")) |home| {
        if (home.len != 0) return std.fmt.allocPrint(ctx.arena, "{s}/.config/zeraora", .{home}) catch null;
    }
    return null;
}

fn writeDefault(ctx: *app.Ctx, dir: []const u8, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);
    var file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    try std.Io.File.writeStreamingAll(file, ctx.io, default_file_contents);
}

fn parse(text: []const u8) Config {
    var cfg = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "language")) {
            const unquoted = stripQuotes(value);
            if (unquoted.len != 0) cfg.language = unquoted;
        } else if (std.mem.eql(u8, key, "shiny_rate")) {
            if (std.fmt.parseFloat(f64, value)) |rate| {
                cfg.shiny_rate = rate;
            } else |_| {}
        }
    }
    return cfg;
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        if ((first == '"' or first == '\'') and value[value.len - 1] == first) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

test "config parsing" {
    const cfg = parse("# comment\nlanguage = 'ja'\nshiny_rate = 0.5\n");
    try std.testing.expectEqualStrings("ja", cfg.language);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.shiny_rate);

    const defaults = parse("");
    try std.testing.expectEqualStrings("en", defaults.language);
    try std.testing.expectEqual(@as(f64, 1.0 / 128.0), defaults.shiny_rate);
}
