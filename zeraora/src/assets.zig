const std = @import("std");
const embed = @import("embed");

const header_len = 12;
const record_len = 20;

/// Fetches one file out of sprites.bin, decompressing it into `allocator`.
/// Returns null when the path is not in the pack.
pub fn get(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const pack = embed.sprites;
    if (pack.len < header_len or !std.mem.eql(u8, pack[0..4], "ZRSP")) return error.InvalidSpritePack;

    const count = readU32(pack, 4);
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const record = header_len + mid * record_len;
        switch (std.mem.order(u8, pathOf(pack, record), path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return try inflate(io, allocator, pack, record),
        }
    }
    return null;
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn pathOf(pack: []const u8, record: usize) []const u8 {
    const table_off = header_len + @as(usize, readU32(pack, 4)) * record_len;
    const offset = readU32(pack, record);
    const len = readU32(pack, record + 4);
    return pack[table_off + offset ..][0..len];
}

fn inflate(io: std.Io, allocator: std.mem.Allocator, pack: []const u8, record: usize) ![]const u8 {
    _ = io;
    const blob_off = header_len + @as(usize, readU32(pack, 4)) * record_len + readU32(pack, 8);
    const offset = readU32(pack, record + 8);
    const compressed_len = readU32(pack, record + 12);
    const raw_len = readU32(pack, record + 16);

    const art = try allocator.alloc(u8, raw_len);
    errdefer allocator.free(art);

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var input = std.Io.Reader.fixed(pack[blob_off + offset ..][0..compressed_len]);
    var decompress = std.compress.flate.Decompress.init(&input, .gzip, &window);
    try decompress.reader.readSliceAll(art);
    return art;
}

test "sprite pack lookups" {
    const art = try get(std.testing.io, std.testing.allocator, "colorscripts/regular/pikachu");
    defer if (art) |bytes| std.testing.allocator.free(bytes);
    try std.testing.expect(art != null);
    try std.testing.expect(art.?.len > 100);
    try std.testing.expect(try get(std.testing.io, std.testing.allocator, "nope") == null);
}
