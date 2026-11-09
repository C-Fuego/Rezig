# ziglet

ziglet prints text as large FIGcharacters. It is a single binary that keeps
FIGlet 2.2.5's command line as its default behaviour and adds TOIlet 1.x's
colours, filters and export formats on top:

* by default the output is plain FIGlet: message words or stdin, the font's
  smush mode, control files, print direction and justification;
* giving `-F/--filter`, `--export`, `--irc`, `--html`, `--color`,
  `--no-color`, `--truecolor`, `--256` or a filter shortcut switches to the
  TOIlet canvas pipeline: each rendered line becomes a canvas, the filters
  run in order, and the result is written in the selected export format.

Fonts are FIGlet `.flf` and TOIlet `.tlf` files; `.gz`/`.zip` containers work
through the system zlib. Rendering comes from the [`textfig`](../textfig)
library: no libcaca, no third-party packages.

```sh
zig build
./zig-out/bin/ziglet --help
printf 'Hi' | ./zig-out/bin/ziglet
./zig-out/bin/ziglet -F flip Hi
./zig-out/bin/ziglet --export irc -F rainbow Hi
./zig-out/bin/ziglet -m 0 -w 60 -c text
./zig-out/bin/ziglet -d ../../textfig/src/fonts -C 646-de text
```

## Merged option set

FIGlet owns the short-option namespace. TOIlet features use `-F` plus long
options, so the two CLIs fit into one command without ambiguous cases.

| Option | Owner | Meaning |
| --- | --- | --- |
| `-f, --font NAME` | both | font; suffix optional |
| `-d DIR`, `--font-dir DIR`, `--directory DIR` | both | font directory |
| `-w, --width N` | both | output width, default 80 |
| `-t, --term-width`, `--termwidth` | both | terminal width, else `$COLUMNS`, else 80 |
| `-k`, `--kerning` | both | kern only |
| `-S`, `--force-smush`, `--smush` | both | force smushing |
| `-W`, `--full-width` | both | full width |
| `-o`, `--overflow` | both | universal overlapping |
| `-I CODE`, `--infocode CODE` | both | info codes 0..5 |
| `-v, --version` | both | version block |
| `-s`, `--default-layout` | FIGlet | the font's own layout |
| `-m MODE`, `--layout MODE` | FIGlet | layout bits; `--layout default` is the font layout |
| `-c`, `-l`, `-r`, `-x` | FIGlet | centre / left / right / automatic |
| `--center`, `--justify MODE` | FIGlet | long forms of `-c` / `-l` / `-r` / `-x` |
| `-p`, `-n` | FIGlet | paragraph mode on/off |
| `-D`, `-E` | FIGlet | German charset on/off |
| `-C FILE`, `-N` | FIGlet | add / clear control files |
| `-L`, `-R`, `-X` | FIGlet | force LTR / RTL / font direction |
| `-A` | FIGlet | take input only from the message arguments |
| `-i, --file FILE` | extension | render FILE (`-` = stdin); repeatable |
| `-h, --help` | extension | this help |
| `--hz` | extension | FIGlet's HZ input mode (accepted, no effect: input is UTF-8) |
| `--list-fonts` | extension | list fonts in the search path |
| `-F, --filter LIST` | TOIlet | filter chain, `:` or `,` separated; `list` lists them |
| `--export FORMAT` | TOIlet | `utf8` (default), `ansi`, `irc`, `html`; `list` lists |
| `--irc`, `--html` | TOIlet | shortcuts for `--export irc` / `--export html` |
| `--rainbow`, `--gay`, `--metal` | TOIlet | `-F rainbow` / `-F metal` |
| `--flip`, `--flop`, `--crop`, `--border` | TOIlet | filter shortcuts |
| `--180`, `--left`, `--right` | TOIlet | rotation filters |
| `--color SPEC` | TOIlet | solid colour: `0..255`, `#rrggbb`, `#rgb`, `r,g,b` |
| `--no-color` | TOIlet | never emit colour escapes |
| `--truecolor`, `--256` | TOIlet | 24-bit vs xterm-256 escapes for utf8 |

### Conflict resolutions

* **`-E` belongs to FIGlet** (turn off German input). The export format is
  selected only by `--export`; `-E` deliberately has no export meaning, so
  `-E irc` renders the word `irc`.
* **`-h` prints help.** FIGlet's `-h` (HZ input mode) is the long option
  `--hz`; it is accepted for compatibility but has no effect because input is
  UTF-8.
* **`-s` belongs to FIGlet** (the font's own layout). TOIlet's default layout
  is reached through `--layout default`.
* **`-F` belongs to TOIlet** (filter chain); FIGlet has no legal `-F`.
* Shared options have the same meaning in both: `-f -d -w -t -k -S -W -o -I
  -v`.
* All FIGlet-only options are preserved: `-A -C -N -D -X -L -R -l -c -r -x
  -p -n -m -I`.
* Because TOIlet's `--left`/`--right` are rotation filters, FIGlet's
  justification long forms are `--justify left|center|right|default` (and
  `--center`); the short forms `-l`/`-r`/`-c` are unchanged.

Option order matters where FIGlet says it does: `-s -k -S -W -o -m` are
applied left to right on top of the font's smush mode.

## Pipelines

The FIGlet pipeline writes rendered rows directly: hardblanks become spaces,
rows are truncated to `outputwidth - 1`, and centring/right justification use
FIGlet's `putstring()` formulas. This is the default and is byte-identical to
FIGlet 2.2.5 for the bundled fonts.

The TOIlet pipeline is selected by any TOIlet option. It turns each rendered
row block into a canvas, applies the same justification as padding, runs the
requested filters in order, and exports the canvas. Layout, direction,
control files and German input behave identically in both pipelines.

`-I` codes: `0` version and usage, `1` `20205` (FIGlet's version integer),
`2` font directory, `3` font name, `4` output width, `5` `flf2 tlf2`;
negative means normal operation. `-v`/`-I0` start with `ziglet 1.0.0`.

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
TOIlet's formulas `(x/2 + y + lines) % 6` and `((lines + y + x/8)/2) % 4`, but
the phase advances by the canvas height after each line, so consecutive lines
do shift colour (upstream TOIlet never advances its line counter).

## Export formats

* `utf8` — UTF-8 text; colours use `\x1b[38;5;Nm` (default) or
  `\x1b[38;2;R;G;Bm` with `--truecolor`; reset with `\x1b[0m`.
* `ansi` — classic 16-colour SGR (`30..37`, `90..97`), nearest palette match.
* `irc` — mIRC `\x03NN` foreground codes (two digits), `\x0f` reset.
* `html` — one UTF-8 document with `<pre>` and
  `<span style="color:#rrggbb">`; `& < > "` are escaped.

`-F list` and `--export list` print the supported sets.

## Font search and input

Font search order: `-d DIR`, `$FIGLET_FONTDIR`, `$XDG_DATA_HOME/figlet` (or
`~/.local/share/figlet`), `/usr/share/figlet`, `/usr/share/ziglet/fonts`,
then the current directory. Names expand to `name`,
`name.flf[.gz|.zip]` and `name.tlf[.gz|.zip]`. Control files are `.flc` or
`.tlc`; `-C` without a suffix tries both.

Message arguments are words joined by spaces; an empty argument forces a line
break. With no arguments, input is read from stdin. `-A` suppresses stdin.
`-i/--file` renders files instead (repeatable, `-` = stdin). Text is decoded
as UTF-8 with U+FFFD replacement, CRLF is normalised, and FIGlet's whitespace,
paragraph (`-p`) and German (`-D`) rules are applied before rendering.

## Companion tools

`zig build` also installs three small programs; they share ziglet's
`textfig` font search path, parser and compressed-font support.

| Tool | Purpose |
| --- | --- |
| `zfiglist` | List the fonts and control files in the search path; one name per line, sorted. |
| `zshowfigfonts` | Print every font with a sample; `--brief` lists only the names. |
| `zchkfont` | Validate font files and report header, height, width, endmark and character-block problems with line numbers. |

```sh
./zig-out/bin/zfiglist -d ../../textfig/src/fonts
./zig-out/bin/zshowfigfonts --brief
./zig-out/bin/zshowfigfonts -f slant "Hello world"
./zig-out/bin/zchkfont ../../textfig/src/fonts/standard.flf
```

`zfiglist` follows figlist's output shape (`Default font`, `Font directory`,
then the font and control-file sections) but scans every directory in the
search path (only the `-d` directory when one is given), removes duplicates,
and includes `.flf.gz`/`.flf.zip` fonts.
`zshowfigfonts` keeps showfigfonts' `name :` + sample layout; the sample is
the positional words, or the font name itself when no words are given.
`zchkfont` accepts several files at once and exits 1 if any file has an error;
warnings (for example a stale `Codetag_Cnt` header field) do not change the
exit status. It checks plain `.flf`/`.tlf` text; decompress `.gz`/`.zip`
containers first.

## Differences from TOIlet 1.x

| Aspect | TOIlet 1.x | ziglet |
| --- | --- | --- |
| Default layout | libcaca `update_figfont_settings()` rules | FIGlet's font smush mode (`--layout default` for the font layout, `-s` resets to it) |
| Direction/justification | always left-to-right, flush left | FIGlet's `-L/-R/-X` and `-c/-l/-r/-x` apply to both pipelines |
| Colour model | libcaca attributes: dithering, background, attributes | truecolor/256/16 SGR foreground only |
| Export formats | every libcaca exporter (svg, ps, troff, tga, binfont, html3, ...) | only `utf8`, `ansi`, `irc`, `html`; `--export list` says exactly that |
| Runtime dependencies | libcaca | system zlib (compressed fonts) and libc |
| Compressed fonts | zip archives named `.tlf` in the repository | plain, `.flf.gz`/`.tlf.gz` and `.flf.zip`/`.tlf.zip`; ZIP64/encrypted/multi-disk rejected with a clear error |
| Wrapping | breaks between FIGcharacters at the width boundary, even mid-word | FIGlet's break at the last blank, so words stay whole where possible |
| Default font | `ascii9` | `standard` (`ascii9` is not bundled); `-f term` is built in |
| Filter glyph substitution | full CP437/Unicode mirror tables (box drawing, arrows, ...) | common ASCII mirror pairs (`()[]{}<>/\`, `bdpq`, `MW`, `ft`, ...); geometry is exact |
| Rainbow/metal line phase | `cx->lines` never advances, so every line has the same phase | phase advances by canvas height per line |
| HTML export | one whole document per input line | one valid document per invocation |
| East Asian widths | fullwidth codepoints occupy two canvas cells (`wcwidth`) | one codepoint is one canvas cell; CJK/emoji geometry can differ |
| `-E` | export format | FIGlet's German off; use `--export` |
| `--color`, `--no-color`, `--truecolor`, `--256` | not available (colour only through filters) | extensions |
| `-i, --file` | not available | extension: render files, `-` = stdin |

## Differences from FIGlet 2.2.5

Everything in FIGlet's `getopt` table is implemented. Remaining differences:

1. **TOIlet options are additions**: `-F/--filter`, `--export`, `--irc`,
   `--html`, `--color`, `--no-color`, `--truecolor`, `--256` and the filter
   shortcuts. In FIGlet, `-F` is an illegal option.
2. **`-h` is help**, not HZ input mode; HZ is `--hz` and is accepted without
   effect. ISO 2022/DBCS/Shift-JIS input modes are likewise not decoded:
   textfig is UTF-8 only.
3. **Compressed fonts** `.flf.gz`/`.tlf.gz`/`.flf.zip`/`.tlf.zip` work through
   the system zlib; `.tlf` and `.tlc` are first-class.
4. **Default font directory** uses the documented XDG/system search path
   instead of a compiled-in `fonts` directory; `term` falls back to a built-in
   font.
5. **`-i/--file`** and **`--list-fonts`** are extensions; the long option names
   for FIGlet's own switches are conveniences as well.
6. Negative code-tagged glyphs are parsed and skipped; rows of a glyph with
   inconsistent widths are padded to the widest row. No bundled font triggers
   either case.

## Tests

`zig build test` runs 31 tests. The main module covers the merged CLI (option
ownership, layout order, infocodes, errors, canvas-mode detection), the FIGlet
`putstring` justification, a FIGlet end-to-end render, and TOIlet filters,
canvas transforms, colour specs, exports and a canvas-pipeline end-to-end
render. The companion tools contribute 8 tests: 2 for `zfiglist`, 3 for
`zshowfigfonts` and 3 for `zchkfont`.
