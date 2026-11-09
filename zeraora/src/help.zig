//! Help pages, byte for byte what clap prints for the same arguments: same
//! spacing, and the same bold/underline styling when stdout is a terminal.

const std = @import("std");
const app = @import("app.zig");

pub const Page = enum { top, list, name, random, help };

const name_description = "Select pokemon by name. Generally spelled like in the games. A few exceptions are nidoran-f, nidoran-m, mr-mime, farfetchd, flabebe type-null etc. Perhaps grep the output of list if in doubt";

const random_description = "Show a random pokemon. This command can optionally be followed by a generation number or range (1-10) to show random pokemon from a specific generation or range of generations. The generations can be provided as a continuous range (eg. 1-3) or as a list of generations (1,3,6)";

const generations_description = "[GENERATIONS]  Generation number, range (1-10), or list of generations (1,3,6) [default: 1-10]";

const top_text = "Print pokemon sprites in your terminal\n" ++
    "\n" ++
    "Usage: zeraora <COMMAND>\n" ++
    "\n" ++
    "Commands:\n" ++
    "  list    Print list of all pokemon\n" ++
    "  name    " ++ name_description ++ "\n" ++
    "  random  " ++ random_description ++ "\n" ++
    "  help    Print this message or the help of the given subcommand(s)\n" ++
    "\n" ++
    "Options:\n" ++
    "  -h, --help     Print help\n" ++
    "  -V, --version  Print version\n";

const list_text = "Print list of all pokemon\n" ++
    "\n" ++
    "Usage: zeraora list [GENERATIONS]\n" ++
    "\n" ++
    "Arguments:\n" ++
    "  " ++ generations_description ++ "\n" ++
    "\n" ++
    "Options:\n" ++
    "  -h, --help  Print help\n";

const name_text = name_description ++ "\n" ++
    "\n" ++
    "Usage: zeraora name [OPTIONS] <NAME>\n" ++
    "\n" ++
    "Arguments:\n" ++
    "  <NAME>  Name of the pokemon to show\n" ++
    "\n" ++
    "Options:\n" ++
    "  -f, --form <FORM>                  Show an alternative form of the pokemon. For example: mega, mega-x, mega-y, gmax, alola, hisui, galar, paldea [default: regular]\n" ++
    "  -i, --info                         Print pokedex entry (if it exists)\n" ++
    "  -s, --shiny                        Show the shiny version of the pokemon instead\n" ++
    "      --no-title                     Do not display pokemon name\n" ++
    "      --padding-left <PADDING_LEFT>  Left padding [default: 0]\n" ++
    "  -h, --help                         Print help\n";

const random_text = random_description ++ "\n" ++
    "\n" ++
    "Usage: zeraora random [OPTIONS] [GENERATIONS]\n" ++
    "\n" ++
    "Arguments:\n" ++
    "  " ++ generations_description ++ "\n" ++
    "\n" ++
    "Options:\n" ++
    "      --no-mega                      Do not show mega pokemon\n" ++
    "      --no-gmax                      Do not show gigantamax pokemon\n" ++
    "      --no-regional                  Do not show regional pokemon\n" ++
    "      --no-variant                   Do not show any variant-form pokemon\n" ++
    "  -i, --info                         Print pokedex entry (if it exists)\n" ++
    "  -s, --shiny                        Show the shiny version of the pokemon instead\n" ++
    "      --no-title                     Do not display pokemon name\n" ++
    "      --padding-left <PADDING_LEFT>  Left padding [default: 0]\n" ++
    "  -h, --help                         Print help\n";

const help_text = "Print this message or the help of the given subcommand(s)\n" ++
    "\n" ++
    "Usage: zeraora help [COMMAND]...\n" ++
    "\n" ++
    "Arguments:\n" ++
    "  [COMMAND]...  Print help for the subcommand(s)\n";

const page_text = [_][]const u8{ top_text, list_text, name_text, random_text, help_text };

/// The bold prefix clap puts in front of the rest of the usage line.
const page_path = [_][]const u8{ "zeraora", "zeraora list", "zeraora name", "zeraora random", "zeraora help" };

pub fn text(page: Page) []const u8 {
    return page_text[@backingInt(page)];
}

pub fn write(out: *app.Out, page: Page) void {
    const body = text(page);
    if (!out.styled) {
        out.write(body);
        return;
    }
    styled(out, body, page_path[@backingInt(page)]);
}

const Section = enum { none, commands, arguments, options };

fn styled(out: *app.Out, body: []const u8, path: []const u8) void {
    var section: Section = .none;
    var first = true;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (!first) out.write("\n");
        first = false;
        writeLine(out, line, &section, path);
    }
}

fn writeLine(out: *app.Out, line: []const u8, section: *Section, path: []const u8) void {
    if (line.len == 0) return;
    if (std.mem.startsWith(u8, line, "Usage: ")) {
        out.header("Usage:");
        out.write(" ");
        const rest = line["Usage: ".len..];
        if (std.mem.startsWith(u8, rest, path)) {
            out.bold(path);
            out.write(rest[path.len..]);
        } else {
            out.write(rest);
        }
        return;
    }
    if (std.mem.eql(u8, line, "Commands:")) {
        out.header(line);
        section.* = .commands;
        return;
    }
    if (std.mem.eql(u8, line, "Arguments:")) {
        out.header(line);
        section.* = .arguments;
        return;
    }
    if (std.mem.eql(u8, line, "Options:")) {
        out.header(line);
        section.* = .options;
        return;
    }

    switch (section.*) {
        .commands => {
            const indent = line.len - std.mem.trimStart(u8, line, " ").len;
            const rest = line[indent..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            out.write(line[0..indent]);
            out.bold(rest[0..end]);
            out.write(rest[end..]);
        },
        .options => writeOptionLine(out, line),
        else => out.write(line),
    }
}

/// "  -f, --form <FORM>  ..." bolds the short and the long name only, leaving
/// the value placeholder and the description plain.
fn writeOptionLine(out: *app.Out, line: []const u8) void {
    const indent = line.len - std.mem.trimStart(u8, line, " ").len;
    out.write(line[0..indent]);

    var rest = line[indent..];
    if (rest.len > 1 and rest[0] == '-' and rest[1] != '-') {
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        out.bold(rest[0..comma]);
        out.write(", ");
        rest = rest[@min(comma + 2, rest.len)..];
    }
    if (std.mem.startsWith(u8, rest, "--")) {
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        out.bold(rest[0..end]);
        out.write(rest[end..]);
    } else {
        out.write(rest);
    }
}

test "pages keep the clap layout" {
    try std.testing.expect(std.mem.endsWith(u8, text(.top), "  -V, --version  Print version\n"));
    try std.testing.expect(std.mem.startsWith(u8, text(.name), "Select pokemon by name."));
    try std.testing.expect(std.mem.indexOf(u8, text(.random), "  [GENERATIONS]  Generation number") != null);
}
