const std = @import("std");
const app = @import("app.zig");
const help = @import("help.zig");
const pokemon = @import("pokemon.zig");

pub const version = "0.3.0";

pub const Common = struct {
    info: bool = false,
    shiny: bool = false,
    no_title: bool = false,
    padding_left: usize = 0,
};

pub const Name = struct {
    name: []const u8,
    form: []const u8 = "regular",
    common: Common = .{},
};

pub const Random = struct {
    generations: pokemon.Generations,
    no_mega: bool = false,
    no_gmax: bool = false,
    no_regional: bool = false,
    no_variant: bool = false,
    common: Common = .{},
};

pub const Command = union(enum) {
    list: pokemon.Generations,
    name: Name,
    random: Random,
};

pub const Parsed = union(enum) {
    command: Command,
    /// Help or version was printed, nothing left to do.
    done,
};

const Usage = struct {
    path: []const u8,
    rest: []const u8,
    /// The required part, kept for the narrowed usage clap prints when it
    /// suggests a similar argument.
    tail: []const u8 = "",
};

const top_usage: Usage = .{ .path = "zeraora", .rest = "<COMMAND>" };
const list_usage: Usage = .{ .path = "zeraora list", .rest = "[GENERATIONS]", .tail = "[GENERATIONS]" };
const name_usage: Usage = .{ .path = "zeraora name", .rest = "[OPTIONS] <NAME>", .tail = "<NAME>" };
const name_bare_usage: Usage = .{ .path = "zeraora name", .rest = "<NAME>", .tail = "<NAME>" };
const random_usage: Usage = .{ .path = "zeraora random", .rest = "[OPTIONS] [GENERATIONS]", .tail = "[GENERATIONS]" };
const help_usage: Usage = .{ .path = "zeraora help", .rest = "[COMMAND]...", .tail = "[COMMAND]..." };

const name_options = [_][]const u8{ "form", "info", "shiny", "no-title", "padding-left", "help" };
const random_options = [_][]const u8{
    "no-mega", "no-gmax", "no-regional", "no-variant",
    "info",    "shiny",   "no-title",    "padding-left",
    "help",
};
const list_options = [_][]const u8{"help"};

const Args = struct {
    items: []const [:0]const u8,
    index: usize = 1,

    fn next(self: *Args) ?[:0]const u8 {
        if (self.index >= self.items.len) return null;
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }

    fn peek(self: *Args) ?[:0]const u8 {
        if (self.index >= self.items.len) return null;
        return self.items[self.index];
    }
};

pub fn parse(ctx: *app.Ctx, argv: []const [:0]const u8) app.Fail!Parsed {
    var args = Args{ .items = argv };

    const first = args.next() orelse {
        help.write(&ctx.err, .top);
        return error.Usage;
    };

    if (is(first, "-h") or is(first, "--help")) {
        help.write(&ctx.out, .top);
        return .done;
    }
    if (isVersionFlag(first)) return printVersion(ctx);
    if (is(first, "help")) return parseHelp(ctx, &args);
    if (is(first, "list")) return parseList(ctx, &args);
    if (is(first, "name")) return parseName(ctx, &args);
    if (is(first, "random")) return parseRandom(ctx, &args);

    return reportUnrecognized(ctx, first, top_usage);
}

fn parseHelp(ctx: *app.Ctx, args: *Args) app.Fail!Parsed {
    var page: help.Page = .top;
    while (args.next()) |word| {
        const next_page: help.Page = switch (page) {
            .top => if (is(word, "list"))
                .list
            else if (is(word, "name"))
                .name
            else if (is(word, "random"))
                .random
            else if (is(word, "help"))
                .help
            else
                return reportUnrecognized(ctx, word, top_usage),
            .list => return reportUnrecognized(ctx, word, list_usage),
            .name => return reportUnrecognized(ctx, word, name_usage),
            .random => return reportUnrecognized(ctx, word, random_usage),
            .help => return reportUnrecognized(ctx, word, help_usage),
        };
        page = next_page;
    }

    help.write(&ctx.out, page);
    return .done;
}

fn parseList(ctx: *app.Ctx, args: *Args) app.Fail!Parsed {
    var generations: ?[]const u8 = null;
    var positional_only = false;

    while (args.next()) |arg| {
        if (!positional_only) {
            if (is(arg, "--")) {
                positional_only = true;
                continue;
            }
            if (is(arg, "-h") or is(arg, "--help")) {
                help.write(&ctx.out, .list);
                return .done;
            }
            if (arg.len > 1 and arg[0] == '-') return reportUnexpected(ctx, list_usage, arg, &list_options);
        }
        if (generations != null) return reportUnexpected(ctx, list_usage, arg, &list_options);
        generations = arg;
    }

    const parsed = try parseGenerationsArg(ctx, generations orelse "1-9", "[GENERATIONS]");
    return .{ .command = .{ .list = parsed } };
}

fn parseName(ctx: *app.Ctx, args: *Args) app.Fail!Parsed {
    var name: ?[]const u8 = null;
    var form: []const u8 = "regular";
    var common = Common{};
    var positional_only = false;
    var used_form = false;
    var used_info = false;
    var used_shiny = false;
    var used_no_title = false;
    var used_padding = false;

    while (args.next()) |arg| {
        if (!positional_only and is(arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (is(arg, "--help")) {
                    help.write(&ctx.out, .name);
                    return .done;
                }
                const long = arg[2..];
                if (is(long, "info")) {
                    if (used_info) return reportAlreadyUsed(ctx, name_usage, "--info");
                    used_info = true;
                    common.info = true;
                } else if (is(long, "shiny")) {
                    if (used_shiny) return reportAlreadyUsed(ctx, name_usage, "--shiny");
                    used_shiny = true;
                    common.shiny = true;
                } else if (is(long, "no-title")) {
                    if (used_no_title) return reportAlreadyUsed(ctx, name_usage, "--no-title");
                    used_no_title = true;
                    common.no_title = true;
                } else if (longOption(long, "form")) |inline_value| {
                    if (used_form) return reportAlreadyUsed(ctx, name_usage, "--form <FORM>");
                    used_form = true;
                    form = inline_value orelse args.next() orelse
                        return reportMissingValue(ctx, "--form <FORM>");
                } else if (longOption(long, "padding-left")) |inline_value| {
                    if (used_padding) return reportAlreadyUsed(ctx, name_usage, "--padding-left <PADDING_LEFT>");
                    used_padding = true;
                    const value = inline_value orelse args.next() orelse
                        return reportMissingValue(ctx, "--padding-left <PADDING_LEFT>");
                    common.padding_left = try parsePadding(ctx, value);
                } else {
                    // clap narrows the usage line once the positional is filled.
                    return reportUnexpected(ctx, if (name != null) name_bare_usage else name_usage, arg, &name_options);
                }
            } else {
                var i: usize = 1;
                while (i < arg.len) : (i += 1) {
                    switch (arg[i]) {
                        'h' => {
                            help.write(&ctx.out, .name);
                            return .done;
                        },
                        'i' => {
                            if (used_info) return reportAlreadyUsed(ctx, name_usage, "--info");
                            used_info = true;
                            common.info = true;
                        },
                        's' => {
                            if (used_shiny) return reportAlreadyUsed(ctx, name_usage, "--shiny");
                            used_shiny = true;
                            common.shiny = true;
                        },
                        'f' => {
                            if (used_form) return reportAlreadyUsed(ctx, name_usage, "--form <FORM>");
                            used_form = true;
                            if (i + 1 < arg.len) {
                                form = arg[i + 1 ..];
                            } else {
                                form = args.next() orelse
                                    return reportMissingValue(ctx, "--form <FORM>");
                            }
                            break;
                        },
                        else => return reportUnexpectedShort(ctx, name_usage, arg[i]),
                    }
                }
            }
            continue;
        }
        if (name != null) return reportUnexpected(ctx, name_usage, arg, &name_options);
        name = arg;
    }

    const pokemon_name = name orelse return reportMissingRequired(ctx, "<NAME>", name_bare_usage);

    return .{ .command = .{ .name = .{ .name = pokemon_name, .form = form, .common = common } } };
}

fn parseRandom(ctx: *app.Ctx, args: *Args) app.Fail!Parsed {
    var generations: ?[]const u8 = null;
    var random = Random{ .generations = .{} };
    var positional_only = false;
    var used_no_mega = false;
    var used_no_gmax = false;
    var used_no_regional = false;
    var used_no_variant = false;
    var used_info = false;
    var used_shiny = false;
    var used_no_title = false;
    var used_padding = false;

    while (args.next()) |arg| {
        if (!positional_only and is(arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and arg.len > 1 and arg[0] == '-') {
            if (arg[1] == '-') {
                if (is(arg, "--help")) {
                    help.write(&ctx.out, .random);
                    return .done;
                }
                const long = arg[2..];
                if (is(long, "no-mega")) {
                    if (used_no_mega) return reportAlreadyUsed(ctx, random_usage, "--no-mega");
                    used_no_mega = true;
                    random.no_mega = true;
                } else if (is(long, "no-gmax")) {
                    if (used_no_gmax) return reportAlreadyUsed(ctx, random_usage, "--no-gmax");
                    used_no_gmax = true;
                    random.no_gmax = true;
                } else if (is(long, "no-regional")) {
                    if (used_no_regional) return reportAlreadyUsed(ctx, random_usage, "--no-regional");
                    used_no_regional = true;
                    random.no_regional = true;
                } else if (is(long, "no-variant")) {
                    if (used_no_variant) return reportAlreadyUsed(ctx, random_usage, "--no-variant");
                    used_no_variant = true;
                    random.no_variant = true;
                } else if (is(long, "info")) {
                    if (used_info) return reportAlreadyUsed(ctx, random_usage, "--info");
                    used_info = true;
                    random.common.info = true;
                } else if (is(long, "shiny")) {
                    if (used_shiny) return reportAlreadyUsed(ctx, random_usage, "--shiny");
                    used_shiny = true;
                    random.common.shiny = true;
                } else if (is(long, "no-title")) {
                    if (used_no_title) return reportAlreadyUsed(ctx, random_usage, "--no-title");
                    used_no_title = true;
                    random.common.no_title = true;
                } else if (longOption(long, "padding-left")) |inline_value| {
                    if (used_padding) return reportAlreadyUsed(ctx, random_usage, "--padding-left <PADDING_LEFT>");
                    used_padding = true;
                    const value = inline_value orelse args.next() orelse
                        return reportMissingValue(ctx, "--padding-left <PADDING_LEFT>");
                    random.common.padding_left = try parsePadding(ctx, value);
                } else return reportUnexpected(ctx, random_usage, arg, &random_options);
            } else {
                var i: usize = 1;
                while (i < arg.len) : (i += 1) {
                    switch (arg[i]) {
                        'h' => {
                            help.write(&ctx.out, .random);
                            return .done;
                        },
                        'i' => {
                            if (used_info) return reportAlreadyUsed(ctx, random_usage, "--info");
                            used_info = true;
                            random.common.info = true;
                        },
                        's' => {
                            if (used_shiny) return reportAlreadyUsed(ctx, random_usage, "--shiny");
                            used_shiny = true;
                            random.common.shiny = true;
                        },
                        else => return reportUnexpectedShort(ctx, random_usage, arg[i]),
                    }
                }
            }
            continue;
        }
        if (generations != null) return reportUnexpected(ctx, random_usage, arg, &random_options);
        generations = arg;
    }

    random.generations = try parseGenerationsArg(ctx, generations orelse "1-9", "[GENERATIONS]");
    return .{ .command = .{ .random = random } };
}

fn printVersion(ctx: *app.Ctx) Parsed {
    ctx.out.print("zeraora {s}\n", .{version});
    return .done;
}

fn isVersionFlag(arg: []const u8) bool {
    return is(arg, "-V") or is(arg, "-v") or is(arg, "--version");
}

/// clap names the offending option in the usage line when it suggested one,
/// and prints the whole flattened group when that option belongs to it.
fn usageWithSuggestion(out: *app.Out, usage: Usage, suggested: []const u8) void {
    out.header("Usage:");
    out.write(" ");
    out.bold(usage.path);
    out.write(" ");
    if (commonGroupMember(suggested)) {
        out.write("<--info|--shiny|--no-title|--padding-left <PADDING_LEFT>>");
    } else {
        out.bold(optionFragment(suggested));
    }
    out.write(" ");
    out.write(usage.tail);
    out.write("\n");
    moreInfo(out);
}

fn commonGroupMember(option: []const u8) bool {
    return std.mem.eql(u8, option, "info") or
        std.mem.eql(u8, option, "shiny") or
        std.mem.eql(u8, option, "no-title") or
        std.mem.eql(u8, option, "padding-left");
}

const option_fragments = [_]struct { option: []const u8, fragment: []const u8 }{
    .{ .option = "form", .fragment = "--form <FORM>" },
    .{ .option = "info", .fragment = "--info" },
    .{ .option = "shiny", .fragment = "--shiny" },
    .{ .option = "no-title", .fragment = "--no-title" },
    .{ .option = "padding-left", .fragment = "--padding-left <PADDING_LEFT>" },
    .{ .option = "no-mega", .fragment = "--no-mega" },
    .{ .option = "no-gmax", .fragment = "--no-gmax" },
    .{ .option = "no-regional", .fragment = "--no-regional" },
    .{ .option = "no-variant", .fragment = "--no-variant" },
    .{ .option = "help", .fragment = "--help" },
};

fn optionFragment(option: []const u8) []const u8 {
    for (option_fragments) |entry| {
        if (std.mem.eql(u8, entry.option, option)) return entry.fragment;
    }
    return "--";
}

/// "Usage: zeraora name [OPTIONS] <NAME>" followed by the hint clap appends.
fn usageBlock(out: *app.Out, usage: Usage) void {
    out.header("Usage:");
    out.write(" ");
    out.bold(usage.path);
    out.write(" ");
    out.write(usage.rest);
    out.write("\n");
    moreInfo(out);
}

fn moreInfo(out: *app.Out) void {
    out.write("\nFor more information, try '");
    out.bold("--help");
    out.write("'.\n");
}

fn reportUnrecognized(ctx: *app.Ctx, word: []const u8, usage: Usage) app.Fail {
    ctx.err.errorBadge();
    ctx.err.write(" unrecognized subcommand '");
    ctx.err.yellow(word);
    ctx.err.write("'\n\n");
    usageBlock(&ctx.err, usage);
    return error.Usage;
}

fn reportMissingRequired(ctx: *app.Ctx, what: []const u8, usage: Usage) app.Fail {
    ctx.err.errorBadge();
    ctx.err.write(" the following required arguments were not provided:\n  ");
    ctx.err.green(what);
    ctx.err.write("\n\n");
    usageBlock(&ctx.err, usage);
    return error.Usage;
}

fn reportUnexpected(ctx: *app.Ctx, usage: Usage, arg: []const u8, candidates: []const []const u8) app.Fail {
    ctx.err.errorBadge();
    ctx.err.write(" unexpected argument '");
    ctx.err.yellow(arg);
    ctx.err.write("' found\n\n");

    if (arg.len > 1 and arg[0] == '-') {
        ctx.err.write("  ");
        ctx.err.tipBadge();
        if (closestOption(arg, candidates)) |similar| {
            ctx.err.write(" a similar argument exists: '");
            ctx.err.green(std.fmt.allocPrint(ctx.arena, "--{s}", .{similar}) catch similar);
            ctx.err.write("'\n\n");
            usageWithSuggestion(&ctx.err, usage, similar);
            return error.Usage;
        } else {
            ctx.err.write(" to pass '");
            ctx.err.yellow(arg);
            ctx.err.write("' as a value, use '");
            ctx.err.green(std.fmt.allocPrint(ctx.arena, "-- {s}", .{arg}) catch arg);
            ctx.err.write("'\n\n");
        }
    }
    usageBlock(&ctx.err, usage);
    return error.Usage;
}

fn reportUnexpectedShort(ctx: *app.Ctx, usage: Usage, short: u8) app.Fail {
    const text = std.fmt.allocPrint(ctx.arena, "-{c}", .{short}) catch return error.Usage;
    return reportUnexpected(ctx, usage, text, &.{});
}

fn reportMissingValue(ctx: *app.Ctx, option: []const u8) app.Fail {
    ctx.err.errorBadge();
    ctx.err.write(" a value is required for '");
    ctx.err.yellow(option);
    ctx.err.write("' but none was supplied\n");
    moreInfo(&ctx.err);
    return error.Usage;
}

fn reportAlreadyUsed(ctx: *app.Ctx, usage: Usage, option: []const u8) app.Fail {
    ctx.err.errorBadge();
    ctx.err.write(" the argument '");
    ctx.err.yellow(option);
    ctx.err.write("' cannot be used multiple times\n\n");
    usageBlock(&ctx.err, usage);
    return error.Usage;
}

fn parseGenerationsArg(ctx: *app.Ctx, value: []const u8, label: []const u8) app.Fail!pokemon.Generations {
    return pokemon.Generations.parse(value) catch {
        ctx.err.errorBadge();
        ctx.err.write(" invalid value '");
        ctx.err.yellow(value);
        ctx.err.write("' for '");
        ctx.err.bold(label);
        ctx.err.print(
            "': Invalid generations `{s}`, should be an integer, a comma-separated list, or a range of integers between 1 and 9\n",
            .{value},
        );
        moreInfo(&ctx.err);
        return error.Usage;
    };
}

fn parsePadding(ctx: *app.Ctx, value: []const u8) app.Fail!usize {
    return std.fmt.parseInt(usize, value, 10) catch {
        ctx.err.errorBadge();
        ctx.err.write(" invalid value '");
        ctx.err.yellow(value);
        ctx.err.write("' for '");
        ctx.err.bold("--padding-left <PADDING_LEFT>");
        ctx.err.write("': invalid digit found in string\n");
        moreInfo(&ctx.err);
        return error.Usage;
    };
}

/// Best-effort version of clap's "did you mean" suggestion: a long option a
/// couple of edits away from what was typed.
fn closestOption(arg: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (arg.len < 3 or arg[1] != '-') return null;
    const typed = arg[2..];
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (candidates) |candidate| {
        const distance = editDistance(typed, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    var previous: [64]usize = undefined;
    var current: [64]usize = undefined;
    const width = @min(b.len, previous.len - 1);
    for (0..width + 1) |j| previous[j] = j;
    for (a, 0..) |char_a, i| {
        current[0] = i + 1;
        for (1..width + 1) |j| {
            const substitution = previous[j - 1] + @intFromBool(char_a != b[j - 1]);
            current[j] = @min(@min(previous[j] + 1, current[j - 1] + 1), substitution);
        }
        previous = current;
    }
    return previous[@min(b.len, width)];
}

/// Splits "--name=value" into its inline value (null when only "--name" was
/// given), returning null if `long` is a different option.
fn longOption(long: []const u8, comptime name: []const u8) ??[]const u8 {
    if (std.mem.eql(u8, long, name)) return @as(?[]const u8, null);
    if (long.len > name.len + 1 and std.mem.startsWith(u8, long, name) and long[name.len] == '=') {
        return long[name.len + 1 ..];
    }
    return null;
}

fn is(arg: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, arg, expected);
}
