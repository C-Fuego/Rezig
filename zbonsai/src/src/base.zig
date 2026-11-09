//! The two ASCII plant pots cbonsai knows about, plus base type 0 ("no pot").
//!
//! The art is copied verbatim from cbonsai's `drawBase()`; only the three rows
//! of the pot use the "text" colour (colour 8) while the rim uses the leaf and
//! wood colours from `-k`.
const std = @import("std");
const canvas = @import("canvas.zig");

pub const text_color: u8 = 8;

pub const Role = enum(u8) {
    text,
    leaf_dark,
    wood_dark,
    leaf_light,
    wood_light,
};

pub const Chunk = struct {
    text: []const u8,
    role: Role,
    bold: bool = false,
};

const row1_rim = [_]Chunk{
    .{ .text = ":", .role = .text, .bold = true },
    .{ .text = "___________", .role = .leaf_light, .bold = true },
    .{ .text = "./~~~\\.", .role = .wood_light, .bold = true },
    .{ .text = "___________", .role = .leaf_light, .bold = true },
    .{ .text = ":", .role = .text, .bold = true },
};

const base1 = [_][]const Chunk{
    &row1_rim,
    &[_]Chunk{.{ .text = " \\                           / ", .role = .text, .bold = true }},
    &[_]Chunk{.{ .text = "  \\_________________________/ ", .role = .text, .bold = true }},
    &[_]Chunk{.{ .text = "  (_)                     (_)", .role = .text, .bold = true }},
};

const base2 = [_][]const Chunk{
    &[_]Chunk{
        .{ .text = "(", .role = .text },
        .{ .text = "---", .role = .leaf_light },
        .{ .text = "./~~~\\.", .role = .wood_light },
        .{ .text = "---", .role = .leaf_light },
        .{ .text = ")", .role = .text },
    },
    &[_]Chunk{.{ .text = " (           ) ", .role = .text }},
    &[_]Chunk{.{ .text = "  (_________)  ", .role = .text }},
};

pub const Size = struct {
    width: i32 = 0,
    height: i32 = 0,
};

/// Base dimensions used by cbonsai: 31x4 for `-b 1`, 15x3 for `-b 2`, nothing
/// otherwise.
pub fn dimensions(base_type: u8) Size {
    return switch (base_type) {
        1 => .{ .width = 31, .height = 4 },
        2 => .{ .width = 15, .height = 3 },
        else => .{},
    };
}

fn colorFor(role: Role, colors: [4]u8) u8 {
    return switch (role) {
        .text => text_color,
        .leaf_dark => colors[0],
        .wood_dark => colors[1],
        .leaf_light => colors[2],
        .wood_light => colors[3],
    };
}

pub fn draw(c: *canvas.Canvas, base_type: u8, ox: i32, oy: i32, colors: [4]u8) void {
    const rows: []const []const Chunk = switch (base_type) {
        1 => &base1,
        2 => &base2,
        else => return,
    };
    for (rows, 0..) |chunks, y| {
        var x = ox;
        for (chunks) |chunk| {
            c.putAscii(oy + @as(i32, @intCast(y)), x, chunk.text, colorFor(chunk.role, colors), chunk.bold);
            x += @intCast(chunk.text.len);
        }
    }
}

test "base art sizes match cbonsai" {
    for (base1, 0..) |row, y| {
        if (y == 0) continue;
        // Rows below the rim are at most 31 columns wide.
        var width: usize = 0;
        for (row) |chunk| width += chunk.text.len;
        try std.testing.expect(width <= 31);
    }
    try std.testing.expectEqual(@as(i32, 31), dimensions(1).width);
    try std.testing.expectEqual(@as(i32, 4), dimensions(1).height);
    try std.testing.expectEqual(@as(i32, 15), dimensions(2).width);
    try std.testing.expectEqual(@as(i32, 0), dimensions(0).width);
}

test "drawing the pot stays inside a 40x10 canvas" {
    const gpa = std.testing.allocator;
    var c = try canvas.Canvas.init(gpa, 10, 40);
    defer c.deinit();
    draw(&c, 1, 4, 6, .{ 2, 3, 10, 11 });
    // Rim character of the pot lands at (6, 4): ":" then 11 underscores
    // (leaf_light) then "./~~~\." (wood_light) starting in column 16.
    try std.testing.expectEqualSlices(u8, ":", c.at(6, 4).?.text());
    try std.testing.expectEqual(@as(u8, 10), c.at(6, 5).?.color);
    try std.testing.expectEqualSlices(u8, "~", c.at(6, 18).?.text());
    try std.testing.expectEqual(@as(u8, 11), c.at(6, 18).?.color);
    // Second row of the pot starts with " \" so the backslash is at column 5.
    try std.testing.expectEqualSlices(u8, "\\", c.at(7, 5).?.text());
}
