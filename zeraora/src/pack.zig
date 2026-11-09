//! Build-time packer: turns assets/ into the two blobs the binary embeds.
//!
//! Both outputs are written to the current directory (the build root) and are
//! skipped when they are already newer than their sources.
//!
//!   db.bin       pokedex, fixed size records plus a string pool
//!   sprites.bin  every colorscript, gzipped

const std = @import("std");
const flate = std.compress.flate;

const db_path = "db.bin";
const pack_path = "sprites.bin";
const json_path = "assets/pokemon.json";
const assets_dir = "assets";

const form_slots = 8;
const languages = [_][]const u8{ "en", "fr", "de", "ja", "zh_hans", "zh_hant" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    try packDatabase(io, arena);
    try packSprites(io, arena);
}

/// True when `path` is missing or older than `newest_source`.
fn isStale(io: std.Io, path: []const u8, newest_source: i96) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return true;
    return stat.mtime.nanoseconds < newest_source;
}

fn write(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try std.Io.File.writeStreamingAll(file, io, bytes);
}

/// Record layout, all little endian, offsets relative to the string pool:
///   slug_off u32, slug_len u32, gen u32, form_count u32, then
///   form_slots * (off u32, len u32), then
///   languages * (name off u32, name len u32), then
///   languages * (desc off u32, desc len u32).
fn packDatabase(io: std.Io, arena: std.mem.Allocator) !void {
    const source = try std.Io.Dir.cwd().statFile(io, json_path, .{});
    if (!isStale(io, db_path, source.mtime.nanoseconds)) return;

    const json = try std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(32 << 20));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    const list = root.array.items;

    var pool: std.ArrayList(u8) = .empty;
    var records: std.ArrayList(u8) = .empty;

    for (list) |item| {
        const object = item.object;
        const slug = object.get("slug").?.string;
        try appendU32(arena, &records, try poolAppend(arena, &pool, slug));
        try appendU32(arena, &records, @intCast(slug.len));
        try appendU32(arena, &records, @intCast(object.get("gen").?.integer));

        const forms = object.get("forms").?.array.items;
        if (forms.len > form_slots) {
            std.debug.print("pack: {s} has more than {d} forms\n", .{ slug, form_slots });
            return error.TooManyForms;
        }
        try appendU32(arena, &records, @intCast(forms.len));
        for (forms) |form| {
            const name = form.string;
            try appendU32(arena, &records, try poolAppend(arena, &pool, name));
            try appendU32(arena, &records, @intCast(name.len));
        }
        for (0..form_slots - forms.len) |_| {
            try appendU32(arena, &records, 0);
            try appendU32(arena, &records, 0);
        }

        const names = object.get("name").?.object;
        const descs = object.get("desc").?.object;
        for (languages) |language| try appendString(arena, &records, &pool, names.get(language));
        for (languages) |language| try appendString(arena, &records, &pool, descs.get(language));
    }

    const record_size = 16 + form_slots * 8 + languages.len * 8 * 2;

    var blob: std.ArrayList(u8) = .empty;
    try blob.appendSlice(arena, "ZRDB");
    try appendU32(arena, &blob, @intCast(list.len));
    try appendU32(arena, &blob, @intCast(record_size));
    try blob.appendSlice(arena, records.items);
    try blob.appendSlice(arena, pool.items);

    try write(io, db_path, blob.items);
    std.debug.print("pack: {d} pokemon -> {d} KiB\n", .{ list.len, blob.items.len / 1024 });
}

///   magic "ZRSP" u32, count u32, path table length u32,
///   count * (path_off u32, path_len u32, blob_off u32, blob_len u32, raw_len u32),
///   path table, then one gzip stream per sprite.
fn packSprites(io: std.Io, arena: std.mem.Allocator) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, assets_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    var newest: i96 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, "pokemon.json")) continue;
        try paths.append(arena, try arena.dupe(u8, entry.path));
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
        newest = @max(newest, stat.mtime.nanoseconds);
    }

    if (!isStale(io, pack_path, newest)) return;

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.lessThan);

    var path_table: std.ArrayList(u8) = .empty;
    var blobs: std.ArrayList(u8) = .empty;
    var records: std.ArrayList(u8) = .empty;
    var window: [flate.max_window_len]u8 = undefined;
    var raw_total: usize = 0;

    for (paths.items) |path| {
        const raw = try dir.readFileAlloc(io, path, arena, .limited(1 << 20));
        raw_total += raw.len;

        var output = try std.Io.Writer.Allocating.initCapacity(arena, raw.len / 2 + 64);
        var compress = try flate.Compress.init(&output.writer, &window, .gzip, .level_4);
        try compress.writer.writeAll(raw);
        try compress.finish();
        const compressed = output.written();

        try appendU32(arena, &records, @intCast(path_table.items.len));
        try appendU32(arena, &records, @intCast(path.len));
        try appendU32(arena, &records, @intCast(blobs.items.len));
        try appendU32(arena, &records, @intCast(compressed.len));
        try appendU32(arena, &records, @intCast(raw.len));

        try path_table.appendSlice(arena, path);
        try blobs.appendSlice(arena, compressed);
    }

    var pack: std.ArrayList(u8) = .empty;
    try pack.appendSlice(arena, "ZRSP");
    try appendU32(arena, &pack, @intCast(paths.items.len));
    try appendU32(arena, &pack, @intCast(path_table.items.len));
    try pack.appendSlice(arena, records.items);
    try pack.appendSlice(arena, path_table.items);
    try pack.appendSlice(arena, blobs.items);

    try write(io, pack_path, pack.items);
    std.debug.print(
        "pack: {d} sprites, {d} KiB -> {d} KiB\n",
        .{ paths.items.len, raw_total / 1024, pack.items.len / 1024 },
    );
}

fn appendU32(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn poolAppend(allocator: std.mem.Allocator, pool: *std.ArrayList(u8), text: []const u8) !u32 {
    const offset: u32 = @intCast(pool.items.len);
    try pool.appendSlice(allocator, text);
    return offset;
}

fn appendString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pool: *std.ArrayList(u8),
    value: ?std.json.Value,
) !void {
    if (value) |inner| {
        if (inner == .string) {
            const text = inner.string;
            try appendU32(allocator, out, try poolAppend(allocator, pool, text));
            try appendU32(allocator, out, @intCast(text.len));
            return;
        }
    }
    try appendU32(allocator, out, 0);
    try appendU32(allocator, out, 0);
}
