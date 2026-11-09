const std = @import("std");
const app = @import("app.zig");
const assets = @import("assets.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const embed = @import("embed");

pub const regular_form = "regular";

/// Order of the language slots inside a database record.
pub const languages = [_][]const u8{ "en", "fr", "de", "ja", "zh_hans", "zh_hant" };

const header_len = 12;
const form_slots = 8;
const record_size = 16 + form_slots * 8 + languages.len * 8 * 2;
const names_base = 16 + form_slots * 8;
const descs_base = names_base + languages.len * 8;

pub const Generations = struct {
    mask: u16 = 0,
    bad: bool = false,

    pub fn parse(input: []const u8) error{Invalid}!Generations {
        var gens = Generations{};

        if (std.mem.indexOfScalar(u8, input, '-')) |dash| {
            const start = std.fmt.parseInt(u8, input[0..dash], 10) catch return error.Invalid;
            const end = std.fmt.parseInt(u8, input[dash + 1 ..], 10) catch return error.Invalid;
            if (start > end) return error.Invalid;
            var gen = start;
            while (gen <= end) : (gen += 1) {
                gens.set(gen);
                if (gen == 255) break;
            }
        } else {
            var parts = std.mem.splitScalar(u8, input, ',');
            while (parts.next()) |part| {
                const gen = std.fmt.parseInt(u8, part, 10) catch return error.Invalid;
                gens.set(gen);
            }
        }

        if (gens.bad or gens.mask == 0) return error.Invalid;
        return gens;
    }

    fn set(self: *Generations, gen: u8) void {
        if (gen < 1 or gen > 9) {
            self.bad = true;
            return;
        }
        self.mask |= @as(u16, 1) << @intCast(gen);
    }

    pub fn contains(self: Generations, gen: u8) bool {
        if (gen < 1 or gen > 9) return false;
        return self.mask & (@as(u16, 1) << @intCast(gen)) != 0;
    }
};

/// db.bin, compiled from assets/pokemon.json at build time. Nothing is parsed
/// or copied at startup: every accessor reads straight out of the blob.
pub const Database = struct {
    blob: []const u8,
    count: usize,
    pool_off: usize,
    config: config.Config,

    pub fn load(cfg: config.Config) !Database {
        const blob = embed.db;
        if (blob.len < header_len or !std.mem.eql(u8, blob[0..4], "ZRDB")) return error.InvalidDatabase;
        const count = readU32(blob, 4);
        if (readU32(blob, 8) != record_size) return error.InvalidDatabase;
        const pool_off = header_len + @as(usize, count) * record_size;
        if (pool_off > blob.len) return error.InvalidDatabase;
        return .{ .blob = blob, .count = count, .pool_off = pool_off, .config = cfg };
    }

    pub fn list(self: Database, ctx: *app.Ctx, generations: Generations) void {
        for (0..self.count) |i| {
            if (!generations.contains(self.genAt(i))) continue;
            ctx.out.print("{s}\n", .{self.slugAt(i)});
        }
    }

    pub fn showByName(self: Database, ctx: *app.Ctx, request: cli.Name) app.Fail!void {
        const found = self.find(request.name) orelse
            return ctx.die("Invalid pokemon `{s}`", .{request.name});

        const is_regular = std.mem.eql(u8, request.form, regular_form);
        if (!is_regular and !self.hasForm(found, request.form)) {
            return ctx.die("Invalid form `{s}` for pokemon `{s}`", .{ request.form, request.name });
        }

        const shiny_dir = if (request.common.shiny) "shiny" else "regular";
        const art_path = if (is_regular)
            std.fmt.bufPrint(&ctx.buffer, "colorscripts/{s}/{s}", .{ shiny_dir, self.slugAt(found) }) catch
                return ctx.die("Out of memory", .{})
        else
            std.fmt.bufPrint(&ctx.buffer, "colorscripts/{s}/{s}-{s}", .{ shiny_dir, self.slugAt(found), request.form }) catch
                return ctx.die("Out of memory", .{});
        const fetched = assets.get(ctx.io, ctx.arena, art_path) catch |err|
            return ctx.die("Failed to unpack pokemon art from '{s}': {t}", .{ art_path, err });
        const art = fetched orelse
            return ctx.die("Could not read pokemon art from '{s}'", .{art_path});

        const padding = ctx.arena.alloc(u8, request.common.padding_left) catch
            return ctx.die("Out of memory", .{});
        @memset(padding, ' ');

        const language = languageIndex(self.config.language);

        if (!request.common.no_title) {
            const lang_slot = language orelse return invalidLanguage(ctx, self.config.language);
            const display_name = self.nameAt(found, lang_slot) orelse
                return invalidLanguage(ctx, self.config.language);
            if (is_regular) {
                ctx.out.print("{s}{s}\n", .{ padding, display_name });
            } else {
                ctx.out.print("{s}{s} ({s})\n", .{ padding, display_name, request.form });
            }
        }

        if (request.common.info) {
            if (language) |lang_slot| {
                if (self.descAt(found, lang_slot)) |description| {
                    printLines(&ctx.out, description, padding);
                }
            }
        }

        ctx.out.print("\n", .{});
        printLines(&ctx.out, art, padding);
    }

    pub fn showRandom(self: Database, ctx: *app.Ctx, request: cli.Random) app.Fail!void {
        var seed_bytes: [8]u8 = undefined;
        std.Io.random(ctx.io, &seed_bytes);
        var prng: std.Random.DefaultPrng = .init(std.mem.readInt(u64, &seed_bytes, .little));
        const rand = prng.random();

        var count: usize = 0;
        for (0..self.count) |i| {
            if (request.generations.contains(self.genAt(i))) count += 1;
        }
        if (count == 0) return ctx.die("Invalid generations", .{});

        var pick = rand.uintLessThan(usize, count);
        var chosen: usize = 0;
        for (0..self.count) |i| {
            if (!request.generations.contains(self.genAt(i))) continue;
            if (pick == 0) {
                chosen = i;
                break;
            }
            pick -= 1;
        }

        var form_buffer: [form_slots + 1][]const u8 = undefined;
        var form_count: usize = 0;
        for (0..self.formCount(chosen)) |k| {
            const form = self.formAt(chosen, k);
            if (isExcluded(form, request)) continue;
            form_buffer[form_count] = form;
            form_count += 1;
        }
        form_buffer[form_count] = regular_form;
        form_count += 1;

        const form = form_buffer[rand.uintLessThan(usize, form_count)];
        const shiny = request.common.shiny or rand.float(f64) < self.config.shiny_rate;

        try self.showByName(ctx, .{
            .name = self.slugAt(chosen),
            .form = form,
            .common = .{
                .info = request.common.info,
                .shiny = shiny,
                .no_title = request.common.no_title,
                .padding_left = request.common.padding_left,
            },
        });
    }

    fn find(self: Database, slug: []const u8) ?usize {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.slugAt(i), slug)) return i;
        }
        return null;
    }

    fn recordAt(self: Database, i: usize) []const u8 {
        const start = header_len + i * record_size;
        return self.blob[start..][0..record_size];
    }

    fn stringAt(self: Database, offset: u32, len: u32) []const u8 {
        const start = self.pool_off + offset;
        return self.blob[start..][0..len];
    }

    fn slot(self: Database, i: usize, field_offset: usize) ?[]const u8 {
        const record = self.recordAt(i);
        const offset = readU32(record, field_offset);
        const len = readU32(record, field_offset + 4);
        if (len == 0) return null;
        return self.stringAt(offset, len);
    }

    pub fn slugAt(self: Database, i: usize) []const u8 {
        return self.slot(i, 0).?;
    }

    fn genAt(self: Database, i: usize) u8 {
        return @intCast(readU32(self.recordAt(i), 8));
    }

    fn formCount(self: Database, i: usize) usize {
        return readU32(self.recordAt(i), 12);
    }

    fn formAt(self: Database, i: usize, k: usize) []const u8 {
        return self.slot(i, 16 + k * 8).?;
    }

    fn hasForm(self: Database, i: usize, form: []const u8) bool {
        for (0..self.formCount(i)) |k| {
            if (std.mem.eql(u8, self.formAt(i, k), form)) return true;
        }
        return false;
    }

    fn nameAt(self: Database, i: usize, language: usize) ?[]const u8 {
        return self.slot(i, names_base + language * 8);
    }

    fn descAt(self: Database, i: usize, language: usize) ?[]const u8 {
        return self.slot(i, descs_base + language * 8);
    }
};

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn languageIndex(language: []const u8) ?usize {
    for (languages, 0..) |name, i| {
        if (std.mem.eql(u8, name, language)) return i;
    }
    return null;
}

fn isExcluded(form: []const u8, request: cli.Random) bool {
    if (request.no_variant) return true;
    if (request.no_mega and equalsAny(form, &.{ "mega", "mega-x", "mega-y" })) return true;
    if (request.no_gmax and std.mem.eql(u8, form, "gmax")) return true;
    if (request.no_regional and equalsAny(form, &.{ "alola", "galar", "hisui", "paldea" })) return true;
    return false;
}

fn equalsAny(value: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

fn invalidLanguage(ctx: *app.Ctx, language: []const u8) app.Fail {
    return ctx.die("Invalid language `{s}`, should be one of [en, fr, de, ja, zh_hans, zh_hant]", .{language});
}

/// Mirrors str::lines(): strips a trailing newline, drops carriage returns.
fn printLines(out: *app.Out, text: []const u8, padding: []const u8) void {
    if (text.len == 0) return;
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var lines = std.mem.splitScalar(u8, text[0..end], '\n');
    while (lines.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        out.write(padding);
        out.write(line);
        out.write("\n");
    }
}

test "generation parsing" {
    try std.testing.expect(Generations.parse("2").?.contains(2));
    const range = Generations.parse("1-3").?;
    try std.testing.expect(range.contains(1) and range.contains(3) and !range.contains(4));
    const sparse = Generations.parse("1,3,5").?;
    try std.testing.expect(sparse.contains(5) and !sparse.contains(2));
    try std.testing.expect(Generations.parse("0") == error.Invalid);
    try std.testing.expect(Generations.parse("1-100") == error.Invalid);
    try std.testing.expect(Generations.parse("a,b,c") == error.Invalid);
    try std.testing.expect(Generations.parse("3-1") == error.Invalid);
}

test "database loads" {
    const db = try Database.load(.{});
    try std.testing.expect(db.count > 900);
    try std.testing.expectEqualStrings("bulbasaur", db.slugAt(0));
    try std.testing.expect(languageIndex("zh_hans") != null);
    try std.testing.expect(languageIndex("xx") == null);
}
