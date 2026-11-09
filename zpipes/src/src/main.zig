const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const term = @import("term.zig");
const grid = @import("grid.zig");
const pipe = @import("pipe.zig");
const palette = @import("palette.zig");
const config = @import("config.zig");
const license = @import("license.zig");

const version = "0.2.0";
const license_text = license.mit;

const help_text =
    \\Usage: zpipes [OPTION]...
    \\Animated pipes terminal screensaver.
    \\
    \\  -n [1-]               number of pipes (D=1)
    \\  -k LIST               pipe type: heavy, light, curved, double, blocks,
    \\                        knobby, dots (D=heavy)
    \\  -c LIST               pipe color INDEX, comma-separated 256-color
    \\                        indexes 1-255, ansi only
    \\  -p MODE               ANSI palette: 8, 16, 88 or 256 (D=8)
    \\  -B                    bold pipe glyphs
    \\  -C                    no color (same as --color-mode none)
    \\  -f [0-]               framerate, 0 = unlimited (D=50)
    \\  -s [1-]               cells per growth step (D=1)
    \\  -r [0.1-1.0]          reset when the screen is this full (D=0.5)
    \\  -t [0.0-1.0]          turn chance (D=0.15)
    \\  -i                    keep pipe color and type when it respawns
    \\  -h                    print this help message
    \\  -v                    print version number
    \\
    \\Note: -c and -k can be used more than once.
    \\
    \\Extended options:
    \\      --color-mode MODE    ansi (D), rgb (truecolor), none
    \\      --theme NAME         default (D), darker, pastel, matrix
    \\      --rainbow DEG        hue shift per step, 0-255, rgb only
    \\      --delay MS           frame delay in milliseconds, 0 = unlimited;
    \\                           cannot be combined with --fps
    \\      --cpf N              growth steps per frame (D=1)
    \\      --max-length N       cells per pipe, 0 = unlimited (D=0)
    \\      --max-total-length N cells across live pipes, oldest recycled (D=0)
    \\      --license            print the MIT license and exit
    \\      --help               print this help message
    \\
    \\Configuration:
    \\  ~/.config/<argv0>/config.toml (or $XDG_CONFIG_HOME/<argv0>/config.toml)
    \\  is read when present. Keys match the long options and the command line
    \\  wins. Only "key = value" and "# comments" are parsed, [sections] are
    \\  ignored.
    \\
    \\Themes (ANSI side):
    \\  default  full palette       darker  dark shades
    \\  pastel   light shades       matrix  green shades
    \\
    \\Keys:
    \\  q, Q, Esc, Ctrl-C     quit and restore the terminal
    \\  r, R                  clear the screen and restart
    \\
;

const Opt = enum {
    help,
    version,
    license,
    color,
    palette,
    color_mode,
    no_color,
    theme,
    rainbow,
    bold,
    inherit,
    fps,
    delay,
    speed,
    cpf,
    pipe_count,
    max_length,
    max_total_length,
    turn,
    reset,
    kind,
};

fn matchLong(name: []const u8) ?Opt {
    if (std.mem.eql(u8, name, "help")) return .help;
    if (std.mem.eql(u8, name, "version")) return .version;
    if (std.mem.eql(u8, name, "license")) return .license;
    if (std.mem.eql(u8, name, "color")) return .color;
    if (std.mem.eql(u8, name, "palette")) return .palette;
    if (std.mem.eql(u8, name, "color-mode")) return .color_mode;
    if (std.mem.eql(u8, name, "no-color")) return .no_color;
    if (std.mem.eql(u8, name, "theme")) return .theme;
    if (std.mem.eql(u8, name, "rainbow")) return .rainbow;
    if (std.mem.eql(u8, name, "bold")) return .bold;
    if (std.mem.eql(u8, name, "inherit-style")) return .inherit;
    if (std.mem.eql(u8, name, "fps")) return .fps;
    if (std.mem.eql(u8, name, "delay")) return .delay;
    if (std.mem.eql(u8, name, "speed")) return .speed;
    if (std.mem.eql(u8, name, "cpf")) return .cpf;
    if (std.mem.eql(u8, name, "pipe-count")) return .pipe_count;
    if (std.mem.eql(u8, name, "max-length")) return .max_length;
    if (std.mem.eql(u8, name, "max-total-length")) return .max_total_length;
    if (std.mem.eql(u8, name, "turn")) return .turn;
    if (std.mem.eql(u8, name, "reset")) return .reset;
    if (std.mem.eql(u8, name, "kind")) return .kind;
    return null;
}

fn matchShort(name: []const u8) ?Opt {
    if (name.len != 1) return null;
    return switch (name[0]) {
        'h' => .help,
        'v', 'V' => .version,
        'c' => .color,
        'p' => .palette,
        'C' => .no_color,
        'B' => .bold,
        'i' => .inherit,
        'f' => .fps,
        'd' => .delay,
        's' => .speed,
        'n' => .pipe_count,
        't' => .turn,
        'r' => .reset,
        'k' => .kind,
        else => null,
    };
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "invalid arguments";
    term.print(posix.STDERR_FILENO, "zpipes: {s}\nTry 'zpipes --help' for more information.\n", .{msg}) catch {};
    return error.InvalidArguments;
}

fn parseU32(what: []const u8, value: []const u8, min: u32, max: u32) !u32 {
    const n = std.fmt.parseInt(u32, value, 10) catch
        return fail("invalid value '{s}' for {s}", .{ value, what });
    if (n < min or n > max) {
        return fail("value for {s} must be between {d} and {d}", .{ what, min, max });
    }
    return n;
}

fn parseFraction(what: []const u8, value: []const u8) !f32 {
    const v = std.fmt.parseFloat(f32, value) catch
        return fail("invalid value '{s}' for {s}", .{ value, what });
    if (!(v >= 0.0 and v <= 1.0)) {
        return fail("value for {s} must be between 0.0 and 1.0", .{what});
    }
    return v;
}

fn parseKindList(cfg: *config.Config, value: []const u8) !void {
    cfg.kind_count = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) return fail("kind list contains an empty name", .{});
        const k = pipe.parseKind(part) orelse
            return fail("unknown pipe kind '{s}': expected heavy, light, curved, double, blocks, knobby or dots", .{part});

        var duplicate = false;
        for (cfg.kinds[0..cfg.kind_count]) |existing| {
            if (existing == k) duplicate = true;
        }
        if (!duplicate) {
            if (cfg.kind_count >= cfg.kinds.len) return fail("too many pipe kinds", .{});
            cfg.kinds[cfg.kind_count] = k;
            cfg.kind_count += 1;
        }
    }
    if (cfg.kind_count == 0) return fail("kind list is empty", .{});
}

fn parseArgs(args: std.process.Args, cfg: *config.Config) !void {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // 跳过 argv[0]

    var color_cli_seen = false;
    var cli_fps = false;
    var cli_delay = false;

    while (it.next()) |raw| {
        const arg: []const u8 = raw;
        if (arg.len == 0) continue;
        if (arg[0] != '-') return fail("unexpected argument '{s}'", .{arg});

        const is_long = std.mem.startsWith(u8, arg, "--");
        var name: []const u8 = undefined;
        var inline_value: ?[]const u8 = null;

        if (is_long) {
            const body = arg[2..];
            if (body.len == 0) return fail("invalid option '{s}'", .{arg});
            if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                name = body[0..eq];
                inline_value = body[eq + 1 ..];
            } else {
                name = body;
            }
        } else {
            const body = arg[1..];
            if (body.len == 0) return fail("invalid option '{s}'", .{arg});
            name = body[0..1];
            if (body.len > 1) {
                inline_value = if (body[1] == '=') body[2..] else body[1..];
            }
        }

        const opt = if (is_long) matchLong(name) else matchShort(name);
        const option = opt orelse return fail("unknown option '{s}'", .{arg});

        const is_switch = switch (option) {
            .help, .version, .license, .no_color, .bold, .inherit => true,
            else => false,
        };
        if (is_switch) {
            if (inline_value != null) {
                return fail("option '{s}' does not take a value", .{arg});
            }
            switch (option) {
                .help => cfg.help = true,
                .version => cfg.version = true,
                .license => cfg.license = true,
                .no_color => cfg.colors.color_mode = .none,
                .bold => cfg.colors.bold = true,
                .inherit => cfg.inherit_style = true,
                else => unreachable,
            }
            continue;
        }

        const value: []const u8 = inline_value orelse blk: {
            const next = it.next() orelse
                return fail("option '{s}' requires a value", .{arg});
            break :blk next;
        };

        switch (option) {
            .color => {
                if (!color_cli_seen) {
                    cfg.colors.explicit_len = 0;
                    cfg.colors.next_explicit = 0;
                    color_cli_seen = true;
                }
                cfg.colors.addExplicit(value) catch
                    return fail("invalid color list '{s}': expected comma-separated numbers 1-255", .{value});
            },
            .palette => cfg.colors.palette = palette.parseMode(value) catch
                return fail("invalid palette '{s}': expected 8, 16, 88 or 256", .{value}),
            .color_mode => cfg.colors.color_mode = palette.parseColorMode(value) catch
                return fail("invalid color mode '{s}': expected ansi, rgb or none", .{value}),
            .theme => cfg.colors.theme = palette.parseTheme(value) catch
                return fail("invalid theme '{s}': expected default, darker, pastel or matrix", .{value}),
            .rainbow => cfg.rainbow = @intCast(try parseU32("--rainbow", value, 0, 255)),
            .fps => {
                cfg.fps = try parseU32("--fps", value, 0, 1000);
                cfg.fps_set = true;
                cfg.fps_from_cli = true;
                if (cfg.delay_set and !cfg.delay_from_cli) cfg.delay_set = false;
                cli_fps = true;
            },
            .delay => {
                cfg.delay_ms = try parseU32("--delay", value, 0, 60_000);
                cfg.delay_set = true;
                cfg.delay_from_cli = true;
                if (cfg.fps_set and !cfg.fps_from_cli) cfg.fps_set = false;
                cli_delay = true;
            },
            .speed => cfg.speed = try parseU32("--speed", value, 1, 100),
            .cpf => cfg.cpf = try parseU32("--cpf", value, 1, 100),
            .pipe_count => cfg.pipe_count = @intCast(try parseU32("--pipe-count", value, 1, 512)),
            .max_length => cfg.max_length = try parseU32("--max-length", value, 0, 1_000_000),
            .max_total_length => cfg.max_total_length = try parseU32("--max-total-length", value, 0, 1_000_000),
            .turn => cfg.turn_chance = try parseFraction("--turn", value),
            .reset => {
                const v = try parseFraction("--reset", value);
                if (v < 0.1) return fail("value for --reset must be between 0.1 and 1.0", .{});
                cfg.reset_threshold = v;
            },
            .kind => try parseKindList(cfg, value),
            .help, .version, .license, .no_color, .bold, .inherit => unreachable,
        }
    }

    if (cli_fps and cli_delay) {
        return fail("--fps and --delay are mutually exclusive", .{});
    }
}

const Early = enum { none, help, version, license };

fn earlyAction(args: std.process.Args) Early {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next();
    while (it.next()) |raw| {
        const arg: []const u8 = raw;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "--license")) return .license;
    }
    return .none;
}

fn exeName(args: std.process.Args) []const u8 {
    var it = std.process.Args.Iterator.init(args);
    const a0 = it.next() orelse return "zpipes";
    var base: []const u8 = a0;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    return if (base.len == 0) "zpipes" else base;
}

fn configPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map, args: std.process.Args) !?[]const u8 {
    const name = exeName(args);
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fmt.allocPrint(allocator, "{s}/{s}/config.toml", .{ xdg, name });
    }
    if (env.get("HOME")) |home| {
        if (home.len > 0) return try std.fmt.allocPrint(allocator, "{s}/.config/{s}/config.toml", .{ home, name });
    }
    return null;
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const fd = posix.openat(posix.AT.FDCWD, path, .{ .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer _ = linux.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, buf[0..]);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

fn makePipe(
    g: *grid.Grid,
    rng: std.Random,
    colors: *palette.Colors,
    kinds: []const pipe.Kind,
    old: ?*const pipe.Pipe,
    inherit: bool,
) ?pipe.Pipe {
    if (old != null and inherit) return pipe.Pipe.spawnLike(g, rng, old.?);
    return pipe.Pipe.spawn(g, rng, colors, kinds);
}

fn enforceTotalLimit(pipes: []pipe.Pipe, max_total: u32) void {
    if (max_total == 0) return;
    while (pipe.totalLength(pipes) > max_total) {
        if (!pipe.reclaimOldest(pipes)) break;
    }
}

fn run(cfg: *const config.Config) !void {
    const allocator = std.heap.page_allocator;

    term.installSignals();

    var raw_opt: ?term.RawMode = term.RawMode.enable(posix.STDIN_FILENO) catch |err| switch (err) {
        error.NotATerminal => null,
        else => return err,
    };
    defer if (raw_opt) |*raw| raw.restore();

    try term.enterScreen();
    defer term.leaveScreen();

    const size = term.getSize();
    var g = try grid.Grid.init(allocator, size.cols, size.rows);
    defer g.deinit();

    var prng = std.Random.DefaultPrng.init(makeSeed());
    const rng = prng.random();

    var colors = cfg.colors;
    const kinds = cfg.kinds[0..cfg.kind_count];

    const pipes = try allocator.alloc(pipe.Pipe, cfg.pipe_count);
    defer allocator.free(pipes);
    for (pipes) |*p| p.* = .{};

    var seq: u64 = 1;
    for (pipes) |*p| {
        if (makePipe(&g, rng, &colors, kinds, null, false)) |np| {
            p.* = np;
            p.spawn_seq = seq;
            seq += 1;
        }
    }
    enforceTotalLimit(pipes, cfg.max_total_length);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    const frame_ns: u64 = if (cfg.delay_set)
        @as(u64, cfg.delay_ms) * 1_000_000
    else if (cfg.fps == 0)
        0
    else
        @divTrunc(1_000_000_000, cfg.fps);

    var next_frame = term.nowNs();
    var frame_count: usize = 0;
    var reset_requested = false;

    while (true) {
        if (term.quit_pending.load(.monotonic)) break;

        var key_buf: [64]u8 = undefined;
        const key_len = term.readInput(&key_buf) catch 0;
        for (key_buf[0..key_len]) |ch| {
            switch (ch) {
                'q', 'Q', 0x1b, 0x03 => term.quit_pending.store(true, .monotonic),
                'r', 'R' => reset_requested = true,
                else => {},
            }
        }
        if (term.quit_pending.load(.monotonic)) break;

        frame.clearRetainingCapacity();
        frame_count += 1;

        const got_winch = term.winch_pending.swap(false, .monotonic);
        if (got_winch or frame_count % 20 == 0) {
            const new_size = term.getSize();
            if (new_size.cols != g.cols or new_size.rows != g.rows) {
                try g.resize(new_size.cols, new_size.rows);
                for (pipes) |*p| {
                    if (p.alive and (p.x < 0 or p.y < 0 or
                        p.x >= @as(i32, @intCast(g.cols)) or
                        p.y >= @as(i32, @intCast(g.rows))))
                    {
                        p.alive = false;
                    }
                }
                try frame.appendSlice(allocator, "\x1b[2J");
                try g.renderAll(allocator, &frame);
            }
        }

        if (reset_requested) {
            reset_requested = false;
            g.clearAll();
            for (pipes) |*p| {
                p.* = .{};
                if (makePipe(&g, rng, &colors, kinds, null, false)) |np| {
                    p.* = np;
                    p.spawn_seq = seq;
                    seq += 1;
                }
            }
            enforceTotalLimit(pipes, cfg.max_total_length);
            try frame.appendSlice(allocator, "\x1b[2J");
        }

        const steps_per_frame = @min(cfg.cpf * cfg.speed, 4096);
        for (pipes) |*p| {
            if (!p.alive) {
                const old = p.*;
                if (makePipe(&g, rng, &colors, kinds, &old, cfg.inherit_style)) |np| {
                    p.* = np;
                    p.spawn_seq = seq;
                    seq += 1;
                } else {
                    continue;
                }
            }

            var step_i: u32 = 0;
            while (step_i < steps_per_frame and p.alive) : (step_i += 1) {
                p.step(&g, rng, cfg.turn_chance, cfg.rainbow);
                if (cfg.max_length > 0 and p.length >= cfg.max_length) {
                    p.alive = false;
                }
            }
        }

        if (cfg.max_total_length > 0) {
            enforceTotalLimit(pipes, cfg.max_total_length);
        }

        if (g.occupancy() >= cfg.reset_threshold) {
            g.clearAll();
            for (pipes) |*p| {
                p.* = .{};
                if (makePipe(&g, rng, &colors, kinds, null, false)) |np| {
                    p.* = np;
                    p.spawn_seq = seq;
                    seq += 1;
                }
            }
            enforceTotalLimit(pipes, cfg.max_total_length);
            try frame.appendSlice(allocator, "\x1b[2J");
        }

        try g.renderDirty(allocator, &frame);
        if (frame.items.len > 0) {
            try term.writeAll(posix.STDOUT_FILENO, frame.items);
        }

        if (frame_ns > 0) {
            const now = term.nowNs();
            if (now < next_frame) {
                term.sleepNs(next_frame - now);
                next_frame += frame_ns;
                if (next_frame < now) next_frame = now + frame_ns;
            } else {
                next_frame = now + frame_ns;
            }
        }
    }
}

fn makeSeed() u64 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0x9e3779b97f4a7c15;
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec *% 1_000_000_000 +% nsec;
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args;
    const allocator = init.arena.allocator();

    switch (earlyAction(args)) {
        .help => {
            term.writeAll(posix.STDOUT_FILENO, help_text) catch {};
            return 0;
        },
        .version => {
            term.print(posix.STDOUT_FILENO, "zpipes {s}\n", .{version}) catch {};
            return 0;
        },
        .license => {
            term.writeAll(posix.STDOUT_FILENO, license_text) catch {};
            return 0;
        },
        .none => {},
    }

    var cfg = config.Config{};
    const path_opt = configPath(allocator, init.environ_map, args) catch |err| {
        term.print(posix.STDERR_FILENO, "zpipes: cannot build config path: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    if (path_opt) |path| {
        const text_opt = readConfigFile(allocator, path) catch |err| {
            term.print(posix.STDERR_FILENO, "zpipes: cannot read config {s}: {s}\n", .{ path, @errorName(err) }) catch {};
            return 1;
        };
        if (text_opt) |text| {
            config.parseToml(&cfg, text, path) catch return 1;
        }
    }

    parseArgs(args, &cfg) catch return 1;

    if (cfg.help) {
        term.writeAll(posix.STDOUT_FILENO, help_text) catch {};
        return 0;
    }
    if (cfg.version) {
        term.print(posix.STDOUT_FILENO, "zpipes {s}\n", .{version}) catch {};
        return 0;
    }
    if (cfg.license) {
        term.writeAll(posix.STDOUT_FILENO, license_text) catch {};
        return 0;
    }

    run(&cfg) catch |err| {
        term.print(posix.STDERR_FILENO, "zpipes: fatal error: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    return 0;
}
