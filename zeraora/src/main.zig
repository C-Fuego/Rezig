const std = @import("std");
const app = @import("app.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const pokemon = @import("pokemon.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    var out_buffer: [64 * 1024]u8 = undefined;
    var out_file = stdout.writer(io, &out_buffer);
    var err_buffer: [8 * 1024]u8 = undefined;
    var err_file = stderr.writer(io, &err_buffer);

    var ctx = app.Ctx{
        .io = io,
        .arena = init.arena.allocator(),
        .environ = init.environ_map,
        .out = .{ .w = &out_file.interface, .styled = styled(io, stdout, init.environ_map) },
        .err = .{ .w = &err_file.interface, .styled = styled(io, stderr, init.environ_map) },
    };

    var code: u8 = 0;
    run(&ctx, init) catch |err| {
        code = switch (err) {
            error.Usage => 2,
            error.Failure => 1,
        };
    };

    ctx.out.flush();
    ctx.err.flush();
    std.process.exit(code);
}

/// Colours the way clap decides them: a terminal, unless NO_COLOR, CLICOLOR=0
/// or TERM=dumb says otherwise, and always when CLICOLOR_FORCE asks for them.
fn styled(io: std.Io, file: std.Io.File, environ: *std.process.Environ.Map) bool {
    if (environ.get("CLICOLOR_FORCE")) |value| {
        if (!std.mem.eql(u8, value, "0")) return true;
    }
    if (!(file.isTty(io) catch false)) return false;
    if (environ.get("NO_COLOR")) |value| {
        if (value.len != 0) return false;
    }
    if (environ.get("CLICOLOR")) |value| {
        if (std.mem.eql(u8, value, "0")) return false;
    }
    if (environ.get("TERM")) |value| {
        if (std.mem.eql(u8, value, "dumb")) return false;
    }
    return true;
}

fn run(ctx: *app.Ctx, init: std.process.Init) app.Fail!void {
    const argv = init.minimal.args.toSlice(ctx.arena) catch
        return ctx.die("Failed to read command line arguments", .{});

    const parsed = try cli.parse(ctx, argv);
    const command = switch (parsed) {
        .done => return,
        .command => |command| command,
    };

    const cfg = try config.load(ctx);
    const db = pokemon.Database.load(cfg) catch |err| switch (err) {
        else => return ctx.die("Failed to load pokemon db: {t}", .{err}),
    };

    switch (command) {
        .list => |generations| db.list(ctx, generations),
        .name => |request| try db.showByName(ctx, request),
        .random => |request| try db.showRandom(ctx, request),
    }
}
