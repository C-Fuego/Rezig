//! Output formats: utf8 (UTF-8 + ANSI colours), ansi (16-colour ANSI), irc
//! (mIRC colour codes) and html (a single UTF-8 HTML document).

const std = @import("std");
const Io = std.Io;
const Canvas = @import("canvas.zig").Canvas;
const color = @import("color.zig");
const Rgb = color.Rgb;

pub const Format = enum {
    utf8,
    ansi,
    irc,
    html,

    pub fn parse(text: []const u8) ?Format {
        if (std.mem.eql(u8, text, "utf8")) return .utf8;
        if (std.mem.eql(u8, text, "ansi")) return .ansi;
        if (std.mem.eql(u8, text, "irc")) return .irc;
        if (std.mem.eql(u8, text, "html")) return .html;
        return null;
    }
};

pub const ColorMode = enum { ansi256, truecolor };

pub const Exporter = struct {
    out: *Io.Writer,
    format: Format,
    color_mode: ColorMode = .ansi256,
    colors_enabled: bool = true,
    html_started: bool = false,

    pub fn emit(self: *Exporter, cv: *const Canvas) !void {
        switch (self.format) {
            .utf8 => try self.emitAnsi(cv, false),
            .ansi => try self.emitAnsi(cv, true),
            .irc => try self.emitIrc(cv),
            .html => try self.emitHtml(cv),
        }
    }

    pub fn finish(self: *Exporter) !void {
        if (self.format == .html and self.html_started) {
            try self.out.writeAll("</pre>\n</body>\n</html>\n");
        }
        try self.out.flush();
    }

    fn emitAnsi(self: *Exporter, cv: *const Canvas, force16: bool) !void {
        for (0..cv.height) |y| {
            var current: ?Rgb = null;
            for (0..cv.width) |x| {
                const cell = cv.at(x, y);
                const fg: ?Rgb = if (self.colors_enabled and cell.ch != ' ') cell.fg else null;
                if (!optRgbEql(fg, current)) {
                    if (fg) |c| {
                        if (force16) {
                            try self.writeSgr16(c);
                        } else switch (self.color_mode) {
                            .ansi256 => try self.out.print("\x1b[38;5;{d}m", .{color.quantize256(c)}),
                            .truecolor => try self.out.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
                        }
                    } else if (current != null) {
                        try self.out.writeAll("\x1b[0m");
                    }
                    current = fg;
                }
                try self.writeChar(cell.ch);
            }
            if (current != null) try self.out.writeAll("\x1b[0m");
            try self.out.writeByte('\n');
        }
    }

    fn writeSgr16(self: *Exporter, c: Rgb) !void {
        const idx = color.nearest16(c);
        if (idx < 8) {
            try self.out.print("\x1b[{d}m", .{30 + @as(u16, idx)});
        } else {
            try self.out.print("\x1b[{d}m", .{90 + @as(u16, idx - 8)});
        }
    }

    fn emitIrc(self: *Exporter, cv: *const Canvas) !void {
        for (0..cv.height) |y| {
            var current: ?u8 = null;
            for (0..cv.width) |x| {
                const cell = cv.at(x, y);
                const idx: ?u8 = if (self.colors_enabled and cell.ch != ' ' and cell.fg != null)
                    color.mircIndex(cell.fg.?)
                else
                    null;
                if (idx != current) {
                    if (idx) |i| {
                        try self.out.print("\x03{d:0>2}", .{i});
                    } else if (current != null) {
                        try self.out.writeByte(0x0f);
                    }
                    current = idx;
                }
                try self.writeChar(cell.ch);
            }
            if (current != null) try self.out.writeByte(0x0f);
            try self.out.writeByte('\n');
        }
    }

    fn emitHtml(self: *Exporter, cv: *const Canvas) !void {
        if (!self.html_started) {
            self.html_started = true;
            try self.out.writeAll(
                "<!DOCTYPE html>\n" ++
                    "<html>\n<head>\n<meta charset=\"utf-8\">\n<title>ztoilet</title>\n</head>\n" ++
                    "<body>\n<pre style=\"font-family: monospace; line-height: 1.1;\">\n",
            );
        }
        for (0..cv.height) |y| {
            var current: ?Rgb = null;
            var open = false;
            for (0..cv.width) |x| {
                const cell = cv.at(x, y);
                const fg: ?Rgb = if (self.colors_enabled and cell.ch != ' ') cell.fg else null;
                if (!optRgbEql(fg, current)) {
                    if (open) {
                        try self.out.writeAll("</span>");
                        open = false;
                    }
                    if (fg) |c| {
                        const h = c.hex();
                        try self.out.print("<span style=\"color:#{s}\">", .{h[0..]});
                        open = true;
                    }
                    current = fg;
                }
                try self.writeHtmlChar(cell.ch);
            }
            if (open) try self.out.writeAll("</span>");
            try self.out.writeByte('\n');
        }
    }

    fn writeChar(self: *Exporter, ch: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch {
            try self.out.writeByte('?');
            return;
        };
        try self.out.writeAll(buf[0..n]);
    }

    fn writeHtmlChar(self: *Exporter, ch: u21) !void {
        switch (ch) {
            '&' => try self.out.writeAll("&amp;"),
            '<' => try self.out.writeAll("&lt;"),
            '>' => try self.out.writeAll("&gt;"),
            '"' => try self.out.writeAll("&quot;"),
            else => try self.writeChar(ch),
        }
    }
};

fn optRgbEql(a: ?Rgb, b: ?Rgb) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

const testing = std.testing;

fn oneCellCanvas(fg: ?Rgb) !Canvas {
    var cv = try Canvas.init(testing.allocator, 1, 1);
    cv.set(0, 0, .{ .ch = 'A', .fg = fg });
    return cv;
}

test "utf8 export emits ANSI truecolor and resets" {
    var cv = try oneCellCanvas(.{ .r = 255, .g = 0, .b = 0 });
    defer cv.deinit();
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ex = Exporter{ .out = &w, .format = .utf8, .color_mode = .truecolor };
    try ex.emit(&cv);
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mA\x1b[0m\n", buf[0..w.end]);
}

test "ansi export uses 16-colour SGR" {
    var cv = try oneCellCanvas(color.ansi16[12]); // light red
    defer cv.deinit();
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ex = Exporter{ .out = &w, .format = .ansi };
    try ex.emit(&cv);
    // light red is ANSI colour 12 -> bright SGR 90 + (12 - 8) = 94
    try testing.expectEqualStrings("\x1b[94mA\x1b[0m\n", buf[0..w.end]);
}

test "irc export emits mIRC foreground codes" {
    var cv = try oneCellCanvas(color.ansi16[12]); // light red -> IRC 4
    defer cv.deinit();
    var buf: [512]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ex = Exporter{ .out = &w, .format = .irc };
    try ex.emit(&cv);
    try testing.expectEqualStrings("\x0304A\x0f\n", buf[0..w.end]);
}

test "html export produces one document with colour spans and escaping" {
    var cv = try Canvas.init(testing.allocator, 2, 1);
    defer cv.deinit();
    cv.set(0, 0, .{ .ch = '<', .fg = .{ .r = 255, .g = 0x88, .b = 0 } });
    cv.set(1, 0, .{ .ch = '&' });
    var buf: [2048]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var ex = Exporter{ .out = &w, .format = .html };
    try ex.emit(&cv);
    try ex.finish();
    const text = buf[0..w.end];
    try testing.expect(std.mem.startsWith(u8, text, "<!DOCTYPE html>"));
    try testing.expect(std.mem.indexOf(u8, text, "<span style=\"color:#ff8800\">&lt;</span>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "&amp;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "</pre>") != null);
}
