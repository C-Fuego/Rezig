# ztoilet

Colourful large-character output for the terminal: text is printed as large
glyphs (FIGlet/TOIlet style), optionally coloured, filtered (`rainbow`,
`metal`, `flip`, `crop`, ...) and exported as UTF-8, ANSI, IRC or HTML.
Rendering comes from the [`textfig`](../textfig) library; no libcaca, no
third-party packages.

```sh
zig build
./zig-out/bin/ztoilet -d ../refs/figlet/fonts -f standard Hello
./zig-out/bin/ztoilet -d ../refs/figlet/fonts -f small -F flip,rainbow Hi
./zig-out/bin/ztoilet -f ../textfig/src/testdata/tiny.tlf 中文
```

## Options

| Option | Meaning |
| --- | --- |
| `-f, --font NAME` | font; suffix optional |
| `-d, --directory DIR` | font directory (`--font-dir` accepted) |
| `-w, --width N` | output width, default 80 |
| `-t, --termwidth` | terminal width, else `$COLUMNS`, else 80 |
| `-s, --default` | font layout, else overlap (TOIlet default) |
| `-S, --smush` | force smushing |
| `-k, --kerning` | kern only |
| `-W, --full-width` | full width |
| `-o, --overflow` | overlapping |
| `-F, --filter LIST` | filter chain, `:` or `,` separated; `list` lists them |
| `--rainbow, --gay` | `-F rainbow` |
| `--metal` | `-F metal` |
| `--flip`, `--flop`, `--crop`, `--border`, `--180`, `--left`, `--right` | filter shortcuts |
| `--color SPEC` | solid colour: `0..255`, `#rrggbb`, `#rgb`, `r,g,b` |
| `--no-color` | strip all colour output |
| `--truecolor` / `--256` | choose 24-bit vs xterm-256 escapes for utf8 |
| `-E, --export FMT` | `utf8` (default), `ansi`, `irc`, `html`; `list` lists |
| `--irc` / `--html` | shortcuts for `-E irc` / `-E html` |
| `-I CODE` | info codes 0..5; `-I1` prints `20201` |
| `-v, --version`, `-h, --help` | information |
| `-i, --file FILE` | render a file, `-` = stdin; repeatable (**extension**) |

Message arguments are words joined by spaces, or stdin when absent. `-F`
options apply in order of appearance; within one value the left-to-right order
is preserved. `-s` follows libcaca's `update_figfont_settings()`: `old_layout
== -1` means full width, `0` with kerning bits means kerning, matching smush
bits mean controlled smushing, universal-smush fonts use universal
overlapping, and anything else overlaps.

`-h` prints TOIlet's own help layout: the option list from `main.c`'s `HELP`
block (same wording, same order), then a separate `Extended options:` paragraph
for what TOIlet 1.x does not have, and finally TOIlet's `USAGE` block at the
end of the page. `-v`/`-I0` print the version block followed by that same
`USAGE` block. Everything goes to stdout and exits 0.

## Filters

All filters TOIlet 1.x exposes are implemented (`filter.c` lookup table):

| Filter | Effect |
| --- | --- |
| `crop` | remove blank borders |
| `rainbow` (`gay`) | per-cell rainbow from libcaca's six-colour palette |
| `metal` | per-cell metallic palette |
| `flip` | horizontal mirror |
| `flop` | vertical mirror |
| `180`/`rotate` | rotate 180° |
| `left` | rotate 90° counter-clockwise |
| `right` | rotate 90° clockwise |
| `border` | box around the figure |

Colours use libcaca's exact ANSI palette (`#0000aa`…). Rainbow/metal follow
TOIlet's formulas `(x/2 + y + lines) % 6` and `((lines + y + x/8)/2) % 4`.
Unlike upstream TOIlet (which never updates its line counter, so every line
has the same colour phase), ztoilet advances the phase by the canvas height
after each line.

## Export formats

* `utf8` — UTF-8 text; colours use `\x1b[38;5;Nm` (default) or
  `\x1b[38;2;R;G;Bm` with `--truecolor`; reset with `\x1b[0m`.
* `ansi` — classic 16-colour SGR (`30..37`, `90..97`), nearest palette match.
* `irc` — mIRC `\x03NN` foreground codes (two digits), `\x0f` reset. The
  libcaca 16 colours are mapped exactly (e.g. light magenta → IRC pink 13,
  light red → IRC red 4); arbitrary RGB uses nearest mIRC colour.
* `html` — one UTF-8 document with `<pre>` and
  `<span style="color:#rrggbb">`; `& < > "` are escaped. Unlike libcaca's
  export (which emits a whole HTML document per input line), ztoilet emits one
  valid document per invocation.

`--filter list` and `--export list` print the supported sets, so the help is
honest about what is implemented.

## Compatibility table: the same option in figlet and TOIlet

| Option | FIGlet 2.2.5 | TOIlet 1.x | zfiglet | ztoilet |
| --- | --- | --- | --- | --- |
| `-f`, `--font` | font name | same | same | same |
| `-d` | `--font-dir` | `--directory` | `-d/--font-dir` | `-d/--directory` |
| `-w` | output width | same | same | same |
| `-t` | terminal width | `--termwidth` | same | same |
| `-s` | font layout | font layout, else overlap | font layout | libcaca default rules |
| `-S` | force smush | force smush | same | same |
| `-k` | kerning | kerning | same | same |
| `-W` | full width | full width | same | same |
| `-o` | overlap | overlap | same | same |
| `-E` | **German off** | **export format** | German off | export format |
| `-F` | removed (illegal) | filter chain | error message | filter chain |
| `-C` | control file | — | supported | — (textfig API only) |
| `-m` | layout bits | — | supported | — |
| `-c/-l/-r/-x` | justification | — | supported | — |
| `-p/-n` | paragraph mode | — | supported | — |
| `-L/-R/-X` | direction | — | supported | — |
| `-A` | argument-only input | — | supported | — |
| `-N` | clear control files | — | supported | — |
| `-D` | German on | — | supported | — |
| `-I` | info codes | figlet-compatible | 20205 / flf2+tlf2 | 20201 / flf2+tlf2 |
| `-h` | usage on error | help | help | help |
| `-v` | version | version | version | version |
| `--color`, `--no-color`, `--truecolor`, `--256` | — | — | — | extension |
| `--file/-i` | — | — | extension | extension |

Because the two tools are separate binaries, the `-E` clash no longer exists:
`zfiglet -E` disables German input, `ztoilet -E` selects an export.

## Differences from TOIlet 1.x

1. **No libcaca.** Colours are truecolor/256/16 SGR, not libcaca attributes;
   there is no dithering, background colour or attribute support.
2. **Only the four requested export formats.** libcaca also offers svg, ps,
   troff, tga, binfont, html3, etc. They are not listed by `-E list`; adding
   them would mean reproducing libcaca's exporters.
3. **Compressed `.tlf` fonts work.** TOIlet's repository stores several fonts
   as zip archives (named `.tlf`); ztoilet detects the zip signature, reads the
   central directory and inflates deflate entries with the system zlib.
   `.tlf.gz` and `.tlf.zip` are accepted as well. ZIP64, encrypted and
   multi-disk archives are rejected with a clear error. zlib (and libc) is a
   runtime dependency; no headers or `@cImport` are used.
4. **Wrapping** uses figlet's word-breaking renderer: breaks happen at the last
   blank (words stay whole where possible). libcaca breaks only between
   FIGcharacters at the width boundary, even mid-word. This is a deliberate
   shared-core choice; the width limit itself is respected.
5. **Default font** is `standard`, not TOIlet's `ascii9`. `ascii9` is not
   installed here; `standard` is available in the reference package and keeps
   the two CLIs consistent. `-f term` (built-in) is always available.
6. **Default layout** follows libcaca's rules for `old_layout`/`full_layout`,
   with one conscious exception: universal-smush fonts use universal
   overlapping instead of libcaca's "all six rules" fallback, so output stays
   consistent with zfiglet.
7. **Filter glyph substitution** covers the common ASCII mirror pairs
   (`()[]{}<>/\`, `bdpq`, `MW`, `ft`, etc.). libcaca's full CP437/Unicode
   lookup tables (box-drawing halves, arrows, etc.) are not reproduced;
   geometry (dimensions and cell positions) is exact.
8. **`-s` on legacy fonts** with rules but no smush-by-default bit falls back
   to overlapping, per libcaca; zfiglet uses full width there.
9. **TOIlet's `cx->lines` bug** (never advanced, so rainbow/metal do not shift
   between lines) is fixed: ztoilet advances the colour phase per canvas.
10. **HTML** is one document per run instead of one document per line.
11. **`--color` is an extension**; TOIlet only colours through filters.
12. **East Asian widths**: each codepoint is one canvas cell (no `wcwidth`);
    libcaca marks fullwidth characters as two cells. Geometry can therefore
    differ for CJK/emoji glyphs.
13. **`.tlc`** is handled by textfig with the FIGlet control-file grammar;
    upstream TOIlet/libcaca has no control files, so there is no upstream
    syntax to match. zfiglet's `-C` can apply it to a `.tlf` font.

## Consistency with zfiglet

Both binaries use the same `textfig` renderer. With filters and colour off,
`zfiglet -f FONT MESSAGE` and `ztoilet -f FONT MESSAGE` produce identical
bytes for 17 of the 18 reference `.flf` fonts; the exception is `ivrit.flf`,
whose `print_direction` is right-to-left (figlet honours it, TOIlet always
prints left-to-right). This is covered by the manual `diff` check in the
project report.

## Tests

`zig build test` runs 15 tests: filter-chain parsing (both separators,
aliases, unknown names), rainbow/metal colouring, canvas resize/crop/flip/
flop/180/left/right, utf8/ansi/irc/html export snippets, colour specs and
palette mapping, CLI parsing (`-F`, `-E`, `--color`, layout order, list modes)
and an end-to-end tiny-font render through canvas + exporter.
