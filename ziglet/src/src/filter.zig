//! TOIlet's post-processing filter chain: crop, rainbow, metal, flip, flop,
//! 180, left, right, border. `-F` values may separate filters with `:` (as in
//! TOIlet) or `,` (a a shared convenience); several -F options apply in
//! order of appearance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("canvas.zig").Canvas;
const color = @import("color.zig");

pub const Kind = enum {
    crop,
    rainbow,
    metal,
    flip,
    flop,
    rot180,
    left,
    right,
    border,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .crop => "crop",
            .rainbow => "rainbow",
            .metal => "metal",
            .flip => "flip",
            .flop => "flop",
            .rot180 => "180",
            .left => "left",
            .right => "right",
            .border => "border",
        };
    }

    pub fn description(self: Kind) []const u8 {
        return switch (self) {
            .crop => "crop unused blanks",
            .rainbow => "add a rainbow colour effect",
            .metal => "add a metallic colour effect",
            .flip => "flip horizontally",
            .flop => "flip vertically",
            .rot180 => "rotate 180 degrees",
            .left => "rotate 90 degrees counterclockwise",
            .right => "rotate 90 degrees clockwise",
            .border => "surround text with a border",
        };
    }
};

pub const ParseError = error{ UnknownFilter, OutOfMemory };

pub fn parseOne(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "crop")) return .crop;
    if (std.mem.eql(u8, name, "rainbow") or std.mem.eql(u8, name, "gay")) return .rainbow;
    if (std.mem.eql(u8, name, "metal")) return .metal;
    if (std.mem.eql(u8, name, "flip")) return .flip;
    if (std.mem.eql(u8, name, "flop")) return .flop;
    if (std.mem.eql(u8, name, "180") or std.mem.eql(u8, name, "rotate")) return .rot180;
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "border")) return .border;
    return null;
}

pub fn parseChain(a: Allocator, text: []const u8) ParseError![]Kind {
    var out: std.ArrayList(Kind) = .empty;
    var it = std.mem.tokenizeAny(u8, text, ":,");
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        const kind = parseOne(name) orelse {
            out.deinit(a);
            return error.UnknownFilter;
        };
        out.append(a, kind) catch |err| {
            out.deinit(a);
            return err;
        };
    }
    return out.toOwnedSlice(a);
}

pub fn listText() []const u8 {
    return "Available filters:\n" ++
        "\"crop\": crop unused blanks\n" ++
        "\"rainbow\": add a rainbow colour effect\n" ++
        "\"metal\": add a metallic colour effect\n" ++
        "\"flip\": flip horizontally\n" ++
        "\"flop\": flip vertically\n" ++
        "\"180\": rotate 180 degrees\n" ++
        "\"left\": rotate 90 degrees counterclockwise\n" ++
        "\"right\": rotate 90 degrees clockwise\n" ++
        "\"border\": surround text with a border\n";
}

pub fn apply(kind: Kind, cv: *Canvas, phase: usize) !void {
    switch (kind) {
        .crop => try cv.crop(),
        .flip => cv.flip(),
        .flop => cv.flop(),
        .rot180 => try cv.rotate180(),
        .left => try cv.rotateLeft(),
        .right => try cv.rotateRight(),
        .border => try cv.border(),
        .rainbow => {
            for (0..cv.height) |y| {
                for (0..cv.width) |x| {
                    var cell = cv.at(x, y);
                    if (cell.ch == ' ') continue;
                    const idx = (x / 2 + y + phase) % 6;
                    cell.fg = color.ansi16[color.rainbow_palette[idx]];
                    cv.set(x, y, cell);
                }
            }
        },
        .metal => {
            for (0..cv.height) |y| {
                for (0..cv.width) |x| {
                    var cell = cv.at(x, y);
                    if (cell.ch == ' ') continue;
                    const idx = ((phase + y + x / 8) / 2) % 4;
                    cell.fg = color.ansi16[color.metal_palette[idx]];
                    cv.set(x, y, cell);
                }
            }
        },
    }
}

const testing = std.testing;

test "filter chain parsing accepts colon and comma separators" {
    const a = testing.allocator;
    const chain = try parseChain(a, "flip,rainbow:metal");
    defer a.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqual(Kind.flip, chain[0]);
    try testing.expectEqual(Kind.rainbow, chain[1]);
    try testing.expectEqual(Kind.metal, chain[2]);

    const alias = try parseChain(a, "rotate");
    defer a.free(alias);
    try testing.expectEqual(Kind.rot180, alias[0]);

    const gay = try parseChain(a, "gay");
    defer a.free(gay);
    try testing.expectEqual(Kind.rainbow, gay[0]);

    try testing.expectError(error.UnknownFilter, parseChain(a, "flip,nope"));
}

test "rainbow and metal colour non-blank cells only" {
    var cv = try Canvas.init(testing.allocator, 3, 1);
    defer cv.deinit();
    cv.set(0, 0, .{ .ch = 'a' });
    cv.set(1, 0, .{ .ch = ' ' });
    cv.set(2, 0, .{ .ch = 'b' });

    try apply(.rainbow, &cv, 0);
    try testing.expect(cv.at(0, 0).fg != null);
    try testing.expect(cv.at(1, 0).fg == null);
    try testing.expect(cv.at(2, 0).fg != null);
    // x/2 means columns 0 and 1 share a colour; column 2 advances.
    try testing.expect(cv.at(0, 0).fg.?.eql(color.ansi16[13]));
    try testing.expect(cv.at(2, 0).fg.?.eql(color.ansi16[12]));

    try apply(.metal, &cv, 0);
    try testing.expect(cv.at(0, 0).fg.?.eql(color.ansi16[9]));
}
