const std = @import("std");
const posix = std.posix;
const sys = @import("xsys.zig");
const term = @import("term.zig");
const grid = @import("grid.zig");
const pipe = @import("pipe.zig");
const palette = @import("palette.zig");
const config = @import("config.zig");
const license = @import("license.zig");

const version = "0.3.0";
const license_text = license.mit;

const help_text =
    \\Usage: zpipes [OPTION]...
    \\Animated pipes terminal screensaver.
    \\
    \\  -p [1-]               number of pipes (D=1)
    \\  -t [0-9]              pipe type (D=0)
    \\  -t c[16 chars]        custom pipe type
    \\  -c [0-255]            pipe color INDEX (D=-c 1 -c 2 ... -c 7 -c 0);
    \\                        can be hexadecimal with '#' prefix
    \\  -f [20-100]           framerate (D=75)
    \\  -s [5-15]             going straight probability, 1 in (D=13)
    \\  -r [0-]               reset after (D=2000) characters, 0 if no reset
    \\  -R                    randomize starting position and direction
    \\  -B                    no bold effect
    \\  -C                    no color
    \\  -K                    keep pipe color and type when crossing edges
    \\  -h                    print this help message
    \\  -v                    print version number
    \\
    \\Note: -t and -c can be used more than once.
    \\
    \\Extended options (not in pipes.sh):
    \\      --kind NAME         heavy, curved, light, double, ascii,
    \\                          ascii-slash, dots, dots-o, railway, knobby,
    \\                          blocks
    \\      --fps N             framerate 0-1000, 0 = unlimited
    \\      --delay MS          frame delay, cannot be combined with --fps
    \\      --speed N           cells per growth step (D=1)
    \\      --cpf N             same as --speed
    \\      --turn F            turn chance 0.0-1.0 (overrides -s)
    \\      --palette MODE      ANSI palette: 8, 16, 88 or 256 (D=8)
    \\      --color-mode MODE   ansi, rgb, none
    \\      --theme NAME        default, darker, pastel, matrix
    \\      --rainbow DEG       hue shift per step, rgb only
    \\      --max-length N      cells per pipe, 0 = unlimited (D=0)
    \\      --max-total-length N
    \\      --inherit-style     keep color and type when a pipe respawns
    \\      --bold              enable bold (already the default)
    \\      --license           print the MIT license and exit
    \\
    \\Configuration:
    \\  ~/.config/<argv0>/config.toml (or $XDG_CONFIG_HOME/<argv0>/config.toml)
    \\  is read when present. Keys match the long options and the command line
    \\  wins.
    \\
    \\Keys:
    \\  P / O                 turn less / more often (pipes.sh P/O)
    \\  F / D                 faster / slower (pipes.sh F/D)
    \\  B / C / K             toggle bold / color / keep-style
    \\  r, R                  clear the screen and restart
    \\  q, Q, Esc, or any other key   quit and restore the terminal
    \\
;

const Opt = enum {
    help,
    version,
    license,
    pipe_count,
    kind,
    pipe_type,
    color,
    framerate,
    fps,
    delay,
    speed,
    turn,
    straight,
    reset,
    random_start,
    bold,
    no_bold,
    no_color,
    keep_style,
    inherit,
    palette,
    color_mode,
    theme,
    rainbow,
    max_length,
    max_total_length,
};

fn matchLong(name: []const u8) ?Opt {
    if (std.mem.eql(u8, name, "help")) return .help;
    if (std.mem.eql(u8, name, "version")) return .version;
    if (std.mem.eql(u8, name, "license")) return .license;
    if (std.mem.eql(u8, name, "pipe-count")) return .pipe_count;
    if (std.mem.eql(u8, name, "kind")) return .kind;
    if (std.mem.eql(u8, name, "type")) return .pipe_type;
    if (std.mem.eql(u8, name, "color")) return .color;
    if (std.mem.eql(u8, name, "framerate")) return .framerate;
    if (std.mem.eql(u8, name, "fps")) return .fps;
    if (std.mem.eql(u8, name, "delay")) return .delay;
    if (std.mem.eql(u8, name, "speed")) return .speed;
    if (std.mem.eql(u8, name, "cpf")) return .speed;
    if (std.mem.eql(u8, name, "turn")) return .turn;
    if (std.mem.eql(u8, name, "straight")) return .straight;
    if (std.mem.eql(u8, name, "reset")) return .reset;
    if (std.mem.eql(u8, name, "random-start")) return .random_start;
    if (std.mem.eql(u8, name, "bold")) return .bold;
    if (std.mem.eql(u8, name, "no-bold")) return .no_bold;
    if (std.mem.eql(u8, name, "no-color")) return .no_color;
    if (std.mem.eql(u8, name, "keep-style")) return .keep_style;
    if (std.mem.eql(u8, name, "inherit-style")) return .inherit;
    if (std.mem.eql(u8, name, "palette")) return .palette;
    if (std.mem.eql(u8, name, "color-mode")) return .color_mode;
    if (std.mem.eql(u8, name, "theme")) return .theme;
    if (std.mem.eql(u8, name, "rainbow")) return .rainbow;
    if (std.mem.eql(u8, name, "max-length")) return .max_length;
    if (std.mem.eql(u8, name, "max-total-length")) return .max_total_length;
    return null;
}

/// 短选项和 pipes.sh 完全一致。
fn matchShort(name: []const u8) ?Opt {
    if (name.len != 1) return null;
    return switch (name[0]) {
        'h' => .help,
        'v' => .version,
        'p' => .pipe_count,
        't' => .pipe_type,
        'c' => .color,
        'f' => .framerate,
        's' => .straight,
        'r' => .reset,
        'R' => .random_start,
        'B' => .no_bold,
        'C' => .no_color,
        'K' => .keep_style,
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

fn countGlyphs(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        i += 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) : (i += 1) {}
        n += 1;
    }
    return n;
}

fn addSetId(cfg: *config.Config, id: usize) !void {
    if (cfg.set_count >= cfg.set_ids.len) return fail("too many pipe types", .{});
    cfg.set_ids[cfg.set_count] = @intCast(id);
    cfg.set_count += 1;
}

fn addCustomSet(cfg: *config.Config, text: []const u8) !void {
    if (cfg.custom_count >= cfg.custom_texts.len) return fail("too many custom pipe types", .{});
    if (cfg.set_count >= cfg.set_ids.len) return fail("too many pipe types", .{});
    cfg.custom_texts[cfg.custom_count] = text;
    cfg.set_ids[cfg.set_count] = -@as(i16, @intCast(cfg.custom_count + 1));
    cfg.custom_count += 1;
    cfg.set_count += 1;
}

fn addKindName(cfg: *config.Config, name: []const u8) !void {
    const id = pipe.parseKind(name) orelse
        return fail("unknown pipe kind '{s}'", .{name});
    try addSetId(cfg, id);
}

fn appendColor(cfg: *config.Config, spec: []const u8) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return fail("invalid color list '{s}'", .{spec});
        var idx: u16 = 0;
        if (part[0] == '#') {
            if (part.len < 2) return fail("unrecognized hexadecimal string '{s}'", .{part});
            idx = std.fmt.parseInt(u16, part[1..], 16) catch
                return fail("unrecognized hexadecimal string '{s}'", .{part});
        } else {
            idx = std.fmt.parseInt(u16, part, 10) catch
                return fail("invalid color index '{s}'", .{part});
        }
        if (idx > 255) return fail("color index out of range: {s}", .{part});
        if (cfg.colors.explicit_len >= cfg.colors.explicit.len) return fail("too many colors", .{});
        cfg.colors.explicit[cfg.colors.explicit_len] = @intCast(idx);
        cfg.colors.explicit_len += 1;
    }
}

fn parseArgs(args: std.process.Args, cfg: *config.Config) !void {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // 跳过 argv[0]

    var color_cli_seen = false;
    var type_cli_seen = false;
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
            .help, .version, .license, .no_color, .bold, .no_bold, .random_start, .keep_style, .inherit => true,
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
                .no_bold => cfg.colors.bold = false,
                .random_start => cfg.random_start = true,
                .keep_style => cfg.keep_style = true,
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
                // 第一次 -c 会清掉默认配色表，之后逐个追加，和 pipes.sh 的 C+=() 一致
                if (!color_cli_seen) {
                    cfg.colors.explicit_len = 0;
                    cfg.colors.next_explicit = 0;
                    color_cli_seen = true;
                }
                try appendColor(cfg, value);
            },
            .pipe_type => {
                if (!type_cli_seen) {
                    cfg.set_count = 0;
                    type_cli_seen = true;
                }
                // -t c<16 字符>：按字符数判断，pipes.sh 的 c???????????????? 也是按字符
                if (value.len > 0 and value[0] == 'c') {
                    if (countGlyphs(value[1..]) != 16) {
                        return fail("custom pipe type must be 'c' followed by exactly 16 characters", .{});
                    }
                    try addCustomSet(cfg, value[1..]);
                } else {
                    const n = try parseU32("pipe type", value, 0, pipe.type_count - 1);
                    try addSetId(cfg, n);
                }
            },
            .kind => {
                if (!type_cli_seen) {
                    cfg.set_count = 0;
                    type_cli_seen = true;
                }
                var parts = std.mem.splitScalar(u8, value, ',');
                while (parts.next()) |part| {
                    const p = std.mem.trim(u8, part, " \t");
                    if (p.len == 0) return fail("kind list contains an empty name", .{});
                    try addKindName(cfg, p);
                }
            },
            .pipe_count => cfg.pipe_count = @intCast(try parseU32("-p", value, 1, 512)),
            .framerate => {
                cfg.fps = try parseU32("-f", value, 20, 100);
                cfg.fps_set = true;
                cfg.fps_from_cli = true;
                if (cfg.delay_set and !cfg.delay_from_cli) cfg.delay_set = false;
                cli_fps = true;
            },
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
            .straight => cfg.straight_divisor = try parseU32("-s", value, 5, 15),
            .turn => cfg.straight_divisor = config.divisorFromChance(try parseFraction("--turn", value)),
            .speed => cfg.speed = try parseU32("--speed", value, 1, 100),
            .reset => cfg.reset_chars = try parseU32("-r", value, 0, 10_000_000),
            .max_length => cfg.max_length = try parseU32("--max-length", value, 0, 1_000_000),
            .max_total_length => cfg.max_total_length = try parseU32("--max-total-length", value, 0, 1_000_000),
            .palette => cfg.colors.palette = palette.parseMode(value) catch
                return fail("invalid palette '{s}': expected 8, 16, 88 or 256", .{value}),
            .color_mode => cfg.colors.color_mode = palette.parseColorMode(value) catch
                return fail("invalid color mode '{s}': expected ansi, rgb or none", .{value}),
            .theme => cfg.colors.theme = palette.parseTheme(value) catch
                return fail("invalid theme '{s}': expected default, darker, pastel or matrix", .{value}),
            .rainbow => cfg.rainbow = @intCast(try parseU32("--rainbow", value, 0, 255)),
            .help, .version, .license, .no_color, .bold, .no_bold, .random_start, .keep_style, .inherit => unreachable,
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
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) return .version;
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
    defer _ = sys.close(fd);

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

/// pipes.sh 的帧间隔是 read -t 0.0$((1000/f))，也就是 floor(1000/f)/100 秒。
/// 75fps 得到 13ms（实际 76.9fps），和原版完全一致。
fn frameNs(fps: u32) u64 {
    if (fps == 0) return 0;
    const hundredths: u64 = 1000 / fps;
    if (hundredths == 0) return 1_000_000;
    return hundredths * 1_000_000;
}

/// 颜色和样式的取用方式。pipes.sh 初始化时是"随机起点 + 依次递增"，
/// 之后每次绕边才是随机重取，所以两种模式要分开。
const StylePicker = struct {
    colors: *palette.Colors,
    sets: []const *const pipe.Set,
    set_pos: usize = 0,
    set_started: bool = false,

    const Chosen = struct {
        set: *const pipe.Set,
        color: palette.Color,
    };

    /// pipes.sh 的 init_pipes：表和颜色都是"随机起点 + 依次递增"。
    fn initial(self: *StylePicker, rng: std.Random) Chosen {
        var cho: *const pipe.Set = pipe.builtin[0];
        if (self.sets.len > 0) {
            if (!self.set_started) {
                self.set_pos = rng.uintLessThan(usize, self.sets.len);
                self.set_started = true;
            }
            cho = self.sets[self.set_pos % self.sets.len];
            self.set_pos = (self.set_pos + 1) % self.sets.len;
        }
        return .{ .set = cho, .color = self.colors.cycle(rng) };
    }

    fn fresh(self: *StylePicker, rng: std.Random) Chosen {
        const cho = if (self.sets.len == 0)
            pipe.builtin[0]
        else
            self.sets[rng.uintLessThan(usize, self.sets.len)];
        return .{ .set = cho, .color = self.colors.pick(rng) };
    }
};

fn place(
    g: *grid.Grid,
    rng: std.Random,
    slot: *pipe.Pipe,
    chosen: StylePicker.Chosen,
    random_start: bool,
    seq: *u64,
) void {
    slot.* = .{};
    if (pipe.spawn(g, rng, chosen.set, chosen.color, random_start)) |np| {
        slot.* = np;
        slot.spawn_seq = seq.*;
        seq.* += 1;
    }
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

    // 把配置里的表 id 解析成指针；自定义表在这里按 UTF-8 切成 16 个字形。
    var custom_sets: [16]pipe.Set = undefined;
    var selected: [32]*const pipe.Set = undefined;
    for (cfg.set_ids[0..cfg.set_count], 0..) |id, i| {
        if (id >= 0) {
            selected[i] = pipe.builtin[@intCast(id)];
        } else {
            const ci: usize = @intCast(-@as(i32, id) - 1);
            _ = pipe.splitGlyphs(cfg.custom_texts[ci], &custom_sets[ci]) catch 0;
            selected[i] = &custom_sets[ci];
        }
    }
    const sets = selected[0..cfg.set_count];

    var colors = cfg.colors;
    var picker = StylePicker{ .colors = &colors, .sets = sets };

    // 运行时可变的参数，对应 pipes.sh 里能被按键改动的 s / f / BOLD / NOCOLOR / KEEPCT。
    var turn_divisor: u32 = cfg.straight_divisor;
    var fps: u32 = cfg.fps;
    var frame_ns: u64 = if (cfg.delay_set) @as(u64, cfg.delay_ms) * 1_000_000 else frameNs(fps);
    var bold = cfg.colors.bold;
    var no_color = cfg.colors.color_mode == .none;
    var keep_style = cfg.keep_style;

    const pipes = try allocator.alloc(pipe.Pipe, cfg.pipe_count);
    defer allocator.free(pipes);
    for (pipes) |*p| p.* = .{};

    var seq: u64 = 1;
    for (pipes) |*p| place(&g, rng, p, picker.initial(rng), cfg.random_start, &seq);
    enforceTotalLimit(pipes, cfg.max_total_length);

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(allocator);

    var next_frame = term.nowNs();
    var frame_count: usize = 0;
    var reset_requested = false;
    var round: u64 = 0; // pipes.sh 的 t：已跑轮数

    while (true) {
        if (term.quit_pending.load(.monotonic)) break;

        var key_buf: [64]u8 = undefined;
        const key_len = term.readInput(&key_buf) catch 0;
        for (key_buf[0..key_len]) |ch| {
            switch (ch) {
                // pipes.sh 的实时调节键
                'P' => turn_divisor = @min(turn_divisor + 1, 15),
                'O' => {
                    if (turn_divisor > 3) turn_divisor -= 1;
                },
                'F' => {
                    fps = @min(fps + 1, 100);
                    frame_ns = frameNs(fps);
                },
                'D' => {
                    if (fps > 20) fps -= 1;
                    frame_ns = frameNs(fps);
                },
                'B' => {
                    bold = !bold;
                    colors.bold = bold;
                },
                'C' => {
                    no_color = !no_color;
                    colors.color_mode = if (no_color) .none else .ansi;
                },
                'K' => keep_style = !keep_style,
                // zpipes 自己的重开
                'r', 'R' => reset_requested = true,
                'q', 'Q', 0x1b, 0x03 => term.quit_pending.store(true, .monotonic),
                // 原版行为：其它任意键退出
                else => term.quit_pending.store(true, .monotonic),
            }
        }
        if (term.quit_pending.load(.monotonic)) break;

        frame.clearRetainingCapacity();
        frame_count += 1;

        const got_winch = term.winch_pending.swap(false, .monotonic);
        if (got_winch or frame_count % 20 == 0) {
            const new_size = term.getSize();
            if (new_size.cols != g.cols or new_size.rows != g.rows) {
                // pipes.sh 收到 SIGWINCH 只更新 w/h，不清屏、也不杀管道：
                // 已有内容留在屏幕上，管道下一帧靠 %w/%h 自己绕回来。
                try g.resize(new_size.cols, new_size.rows);
            }
        }

        if (reset_requested) {
            reset_requested = false;
            g.clearAll();
            for (pipes) |*p| place(&g, rng, p, picker.initial(rng), cfg.random_start, &seq);
            enforceTotalLimit(pipes, cfg.max_total_length);
            try frame.appendSlice(allocator, "\x1b[2J");
        }

        const steps_per_frame = @min(cfg.cpf * cfg.speed, 4096);
        const turn_chance: f32 = 1.0 / @as(f32, @floatFromInt(turn_divisor));
        for (pipes) |*p| {
            if (!p.alive) {
                const chosen = if (cfg.inherit_style)
                    StylePicker.Chosen{ .set = p.set, .color = p.color }
                else
                    picker.fresh(rng);
                place(&g, rng, p, chosen, cfg.random_start, &seq);
            }

            var step_i: u32 = 0;
            while (step_i < steps_per_frame and p.alive) : (step_i += 1) {
                pipe.step(p, &g, rng, .{
                    .turn_chance = turn_chance,
                    .rainbow = cfg.rainbow,
                    .keep_style = keep_style,
                    .colors = &colors,
                    .sets = sets,
                });
                if (cfg.max_length > 0 and p.length >= cfg.max_length) {
                    p.alive = false;
                }
            }
        }

        if (cfg.max_total_length > 0) {
            enforceTotalLimit(pipes, cfg.max_total_length);
        }

        try g.renderDirty(allocator, &frame);
        if (frame.items.len > 0) {
            try term.writeAll(posix.STDOUT_FILENO, frame.items);
        }

        // pipes.sh 是先画后判定：((r > 0 && t * p >= r)) && tput reset ... || ((t++))
        if (cfg.reset_chars > 0 and round * @as(u64, @intCast(cfg.pipe_count)) >= cfg.reset_chars) {
            round = 0;
            g.clearAll();
            for (pipes) |*p| place(&g, rng, p, picker.initial(rng), cfg.random_start, &seq);
            enforceTotalLimit(pipes, cfg.max_total_length);
            // tput reset + civis 的等价物：清屏、归位、重新隐藏光标
            try term.writeAll(posix.STDOUT_FILENO, "\x1b[0m\x1b[2J\x1b[H\x1b[?25l");
        } else {
            round +%= 1;
        }

        if (frame_ns > 0) {
            const now = term.nowNs();
            if (now < next_frame) {
                var wait = next_frame - now;
                while (wait > 0) {
                    term.sleepNs(wait);
                    const t = term.nowNs();
                    if (t >= next_frame) break;
                    wait = next_frame - t;
                }
                next_frame += frame_ns;
                const after = term.nowNs();
                if (next_frame < after) next_frame = after + frame_ns;
            } else {
                next_frame = now + frame_ns;
            }
        }
    }
}


fn makeSeed() u64 {
    var ts: std.posix.timespec = undefined;
    const rc = sys.clock_gettime(sys.CLOCK.REALTIME, &ts);
    if (sys.errno(rc) != .SUCCESS) return 0x9e3779b97f4a7c15;
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
