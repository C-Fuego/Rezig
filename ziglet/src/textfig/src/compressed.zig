//! Optional gzip/zip font containers, backed by the system zlib.
//!
//! zlib is declared by hand (no `@cImport`) and linked with `-lz`; see
//! build.zig. Two entry points:
//!
//!   * `gunzipFile` uses the gzFile interface (gzopen/gzread/gzclose) and is
//!     used for `*.flf.gz` / `*.tlf.gz`.
//!   * `unzipBytes` parses the zip central directory, supports stored
//!     (method 0) and deflated (method 8, raw inflate with windowBits -15)
//!     entries, and returns the first font-like entry.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    OpenFailed,
    InvalidGzip,
    InvalidZip,
    NotZip,
    UnsupportedZip,
    TooLarge,
};

// zlib ABI ---------------------------------------------------------------

const alloc_func = *const fn (?*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque;
const free_func = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

const z_stream = extern struct {
    next_in: ?[*]const u8,
    avail_in: c_uint,
    total_in: c_ulong,
    next_out: ?[*]u8,
    avail_out: c_uint,
    total_out: c_ulong,
    msg: ?[*:0]const u8,
    state: ?*anyopaque,
    zalloc: ?alloc_func,
    zfree: ?free_func,
    @"opaque": ?*anyopaque,
    data_type: c_int,
    adler: c_ulong,
    reserved: c_ulong,
};

extern fn gzopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn gzread(file: *anyopaque, buf: [*]u8, len: c_uint) c_int;
extern fn gzclose(file: *anyopaque) c_int;
extern fn inflateInit2_(
    strm: *z_stream,
    window_bits: c_int,
    version: [*:0]const u8,
    stream_size: c_int,
) c_int;
extern fn inflate(strm: *z_stream, flush: c_int) c_int;
extern fn inflateEnd(strm: *z_stream) c_int;
extern fn zlibVersion() [*:0]const u8;

const Z_OK: c_int = 0;
const Z_STREAM_END: c_int = 1;
const Z_NO_FLUSH: c_int = 0;
const MAX_WBITS: c_int = 15;

pub fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

pub fn isZip(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04");
}

/// Decompress a gzip file using zlib's gzFile streaming API.
pub fn gunzipFile(a: Allocator, path: []const u8, limit: usize) Error![]u8 {
    const path_z = a.allocSentinel(u8, path.len, 0) catch return error.OutOfMemory;
    @memcpy(path_z, path);
    defer a.free(path_z);

    const file = gzopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = gzclose(file);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = gzread(file, &buf, @intCast(buf.len));
        if (n < 0) return error.InvalidGzip;
        if (n == 0) break;
        const got: usize = @intCast(n);
        if (out.items.len + got > limit) return error.TooLarge;
        out.appendSlice(a, buf[0..got]) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch return error.OutOfMemory;
}

const ZipEntry = struct {
    method: u16,
    flags: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    local_offset: u32,
    name: []const u8,
};

fn readU16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return error.InvalidZip;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn readU32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return error.InvalidZip;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn findEocd(bytes: []const u8) Error!usize {
    if (bytes.len < 22) return error.InvalidZip;
    var pos: usize = bytes.len - 22;
    const min_pos: usize = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
    while (true) {
        if ((readU32(bytes, pos) catch 0) == 0x06054b50) return pos;
        if (pos == min_pos) break;
        pos -= 1;
    }
    return error.InvalidZip;
}

/// Extract the first font-like entry from a zip archive.
pub fn unzipBytes(a: Allocator, bytes: []const u8, limit: usize) Error![]u8 {
    if (!isZip(bytes)) return error.NotZip;
    const eocd = try findEocd(bytes);
    const entries_disk = try readU16(bytes, eocd + 8);
    const entries_total = try readU16(bytes, eocd + 10);
    const cd_size = try readU32(bytes, eocd + 12);
    const cd_offset = try readU32(bytes, eocd + 16);
    if (entries_total == 0xffff or cd_size == 0xffffffff or cd_offset == 0xffffffff) {
        return error.UnsupportedZip; // ZIP64
    }
    if (entries_disk != entries_total) return error.UnsupportedZip; // multi-disk
    const cd_off_usize: usize = cd_offset;
    const cd_size_usize: usize = cd_size;
    if (cd_off_usize + cd_size_usize > bytes.len) return error.InvalidZip;

    var chosen: ?ZipEntry = null;
    var fallback: ?ZipEntry = null;
    var saw_non_dir = false;
    var off: usize = cd_off_usize;
    var idx: usize = 0;
    while (idx < entries_total) : (idx += 1) {
        if (try readU32(bytes, off) != 0x02014b50) return error.InvalidZip;
        if (off + 46 > bytes.len) return error.InvalidZip;
        const flags = try readU16(bytes, off + 8);
        const method = try readU16(bytes, off + 10);
        const compressed_size = try readU32(bytes, off + 20);
        const uncompressed_size = try readU32(bytes, off + 24);
        const name_len = try readU16(bytes, off + 28);
        const extra_len = try readU16(bytes, off + 30);
        const comment_len = try readU16(bytes, off + 32);
        const local_offset = try readU32(bytes, off + 42);
        if (compressed_size == 0xffffffff or uncompressed_size == 0xffffffff or local_offset == 0xffffffff) {
            return error.UnsupportedZip;
        }
        const name_end = off + 46 + name_len;
        if (name_end > bytes.len) return error.InvalidZip;
        const name = bytes[off + 46 .. name_end];
        const entry: ZipEntry = .{
            .method = method,
            .flags = flags,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .local_offset = local_offset,
            .name = name,
        };
        const is_dir = std.mem.endsWith(u8, name, "/");
        if (!is_dir) saw_non_dir = true;
        const usable = !is_dir and (method == 0 or method == 8);
        if (usable) {
            if (std.mem.endsWith(u8, name, ".flf") or std.mem.endsWith(u8, name, ".tlf")) {
                chosen = entry;
                break; // prefer the font entry
            }
            if (fallback == null) fallback = entry;
        }
        off = name_end + extra_len + comment_len;
    }

    const entry = chosen orelse fallback orelse
        return if (saw_non_dir) error.UnsupportedZip else error.InvalidZip;
    if ((entry.flags & 1) != 0) return error.UnsupportedZip; // encrypted
    if (entry.uncompressed_size > limit) return error.TooLarge;

    const local: usize = entry.local_offset;
    if (try readU32(bytes, local) != 0x04034b50) return error.InvalidZip;
    if (local + 30 > bytes.len) return error.InvalidZip;
    const lname_len: usize = try readU16(bytes, local + 26);
    const lextra_len: usize = try readU16(bytes, local + 28);
    const data_off = local + 30 + lname_len + lextra_len;
    const csize: usize = entry.compressed_size;
    const data_end = data_off + csize;
    if (data_end > bytes.len) return error.InvalidZip;
    const data = bytes[data_off..data_end];

    if (entry.method == 0) {
        if (entry.compressed_size != entry.uncompressed_size) return error.InvalidZip;
        const out = a.alloc(u8, data.len) catch return error.OutOfMemory;
        @memcpy(out, data);
        return out;
    }
    return inflateRaw(a, data, entry.uncompressed_size, limit);
}

/// zlib raw inflate (no gzip/zlib wrapper): the format inside zip entries.
fn inflateRaw(a: Allocator, data: []const u8, expected: u32, limit: usize) Error![]u8 {
    var strm: z_stream = std.mem.zeroes(z_stream);
    strm.next_in = data.ptr;
    strm.avail_in = @intCast(data.len);
    if (inflateInit2_(&strm, -MAX_WBITS, zlibVersion(), @sizeOf(z_stream)) != Z_OK) {
        return error.InvalidZip;
    }
    defer _ = inflateEnd(&strm);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        strm.next_out = buf[0..].ptr;
        strm.avail_out = @intCast(buf.len);
        const ret = inflate(&strm, Z_NO_FLUSH);
        const produced: usize = buf.len - strm.avail_out;
        if (produced > 0) {
            if (out.items.len + produced > limit) return error.TooLarge;
            out.appendSlice(a, buf[0..produced]) catch return error.OutOfMemory;
        }
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK) return error.InvalidZip;
        if (produced == 0 and strm.avail_in == 0) return error.InvalidZip;
    }
    if (out.items.len != @as(usize, expected)) return error.InvalidZip;
    return out.toOwnedSlice(a) catch return error.OutOfMemory;
}

test "gzip and zip magic detection" {
    try std.testing.expect(isGzip(&.{ 0x1f, 0x8b, 0x08 }));
    try std.testing.expect(!isGzip("flf2a"));
    try std.testing.expect(isZip(&.{ 'P', 'K', 3, 4 }));
    try std.testing.expect(!isZip("PK66"));
}
