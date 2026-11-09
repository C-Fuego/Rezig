# textfig

`textfig` is the shared FIGlet/TOIlet core used by **zfiglet** and **ztoilet**.
It is a pure-Zig (0.17, std only) library with no I/O side effects beyond the
font/control-file search helpers.

```zig
const textfig = @import("textfig");
const font = textfig.font;       // .flf/.tlf parser, glyphs, search paths
const render = textfig.render;   // smushing, layout modes, word wrap
const control = textfig.control; // .flc/.tlc control files
```

## Public surface

### `font`

* `font.parseHeader(line, diag)` — parse/validate the first line of a FIGfont.
* `font.Font.parse(gpa, bytes, display_name, diag)` — parse a complete
  `.flf`/`.tlf` in memory. The result owns an arena; call `deinit()` once.
* `font.Font.glyph(code)` / `hasGlyph(code)` — lookup a codepoint. Mandatory
  ASCII and German slots are direct; code-tagged glyphs are searched last-first
  so the last duplicate wins (as in figlet). Unknown characters yield a
  zero-width glyph.
* `font.Font.builtinTerm(gpa)` — the built-in one-row `term` fallback.
* `font.searchDirs(arena, config)` / `primaryDir(dirs)` — the ordered font
  search path.
* `font.load(io, gpa, dirs, name, diag)` — open and parse a font, trying
  `.flf` then `.tlf`; `term` is built in when no `term.flf` file exists.
* `font.listFonts(...)` — scan the directories and print sorted names.

### `render`

* `smushem(mode, hardblank, direction, prev_width, cur_width, l, r)`
* `smushAmount` / line building are internal to `Renderer`.
* `Renderer.init(...)` + `feed(codepoint)` + `finish()` — figlet's exact
  word-breaking state machine. Each finished line is handed to a `Sink`
  callback as fixed-width rows of codepoints (hardblanks preserved).
* `layoutModeToSmush(mode)` and `applyLayoutOp(current, font_default, op)` —
  `-m/-k/-W/-S/-o/-s` semantics.

### `control`

* `control.Program.parse(gpa, bytes, name, diag)`
* `Program.apply(codepoint)` — applies every `f`-separated stage in order;
  only the first matching mapping in a stage is applied.

## Parser rules implemented

* Header: `flf2a$` / `tlf2a$`, hardblank (UTF-8 codepoint for `.tlf`), height,
  baseline, max length, old layout, comment lines, optional print direction
  (0/1), optional full layout (0..32767), optional codetag count.
* Comment lines are skipped by count; truncation is an error with the exact
  line number.
* Glyphs: 95 ASCII (`0x20`..`0x7e`) then the seven German characters
  `Ä Ö Ü ä ö ü ß` (196, 214, 220, 228, 246, 252, 223).
* Endmark handling matches figlet 2.2.5: strip trailing whitespace, take the
  last remaining character as the endmark, strip the whole trailing run of it
  (normally one on most rows, two on the last row). Content spaces *before*
  the endmark are preserved.
* Code-tagged glyphs: decimal, octal (`0755`) and hex (`0x4E2D`) codes; blank
  lines between blocks are tolerated; negative codes are skipped (they cannot
  be produced by the input decoder).
* Rows of one glyph are padded logically with spaces when read; inconsistent
  row widths are tolerated by using the widest row (figlet uses row 0).

### Layout bits

The low byte of the full layout is the horizontal smush mode; the bits are
figlet's:

| bit | meaning |
| --- | --- |
| 1 | equal character smushing |
| 2 | underscore smushing |
| 4 | hierarchy smushing |
| 8 | opposite-pair smushing |
| 16 | big-X smushing |
| 32 | hardblank smushing |
| 64 | fitting (kerning) by default |
| 128 | smushing by default (overrides 64) |

When the full layout is absent textfig derives it exactly like figlet:
`old == 0` → kerning, `old < 0` → full width, `old > 0` →
`(old & 31) | 128`. The dropped bit 32 is an upstream figlet quirk and is
reproduced on purpose.

`-m` values are figlet's: `-1` full width, `0` kerning, `1..63` controlled
smushing with those rule bits, anything below `-1` (including the documented
`-m-2`) means "use the font default".

## Smushing

`smushem()` is a one-to-one port of figlet's function, including:

1. blanks absorb (a space takes the other character);
2. no overlap when either FIGcharacter is narrower than 2 columns;
3. no overlap in kerning/full-width modes;
4. universal overlapping when no rules are selected (later character wins,
   hardblanks lose against visible characters, RTL uses the logical order);
5. equal, underscore, hierarchy (`|`, `/\`, `[]`, `{}`, `()`, `<>`),
   opposite-pair, big-X and hardblank rules, in that order.

`smushAmount()` mirrors figlet's `smushamt()`: per row it finds the last
non-space of the line and the first non-space of the incoming glyph, allows
fitting up to contact, and adds one extra column only when `smushem()` permits
it. The minimum over all rows is used. The width check and `-w1` behaviour are
figlet's.

## Word breaking

`Renderer.feed()` is a transcription of figlet's `main()` loop, including
`wordbreakmode` (−1 absorb blanks, 0 neutral, 1 word, 2 word+blanks, 3 had a
break), splitting at the last blank run, preserving empty lines, and the
"absorb the newline after a forced break" rule. Overlong words are broken at
the width limit; a single glyph wider than the limit is printed on its own
line, as in figlet.

## Control files

`.flc` and `.tlc` use the FIGfont control grammar:

```
t inchar outchar
t inchar1-inchar2 outchar1-outchar2
number number
f
```

Comments (`#`), blank lines, numeric/octal/hex escapes and the `\a \b \e \f
\n \r \t \v \\` sequences are supported. `f` starts a new stage. The
`b/u/h/j/g` input-mode commands are accepted and ignored (textfig is always
UTF-8). Upstream TOIlet/libcaca has no control-file support; `.tlc` is an
alias for the same FIGlet grammar applied to `.tlf` fonts.

## Font search path

1. `-d`/`--font-dir` (ztoilet: `--directory`)
2. `$FIGLET_FONTDIR`
3. `$XDG_DATA_HOME/figlet`, else `~/.local/share/figlet`
4. `/usr/share/figlet`
5. `.` (current directory, as in both originals)

For a name without a suffix, the candidate order in every directory is:

```
name
name.flf      name.flf.gz      name.flf.zip
name.tlf      name.tlf.gz      name.tlf.zip
```

Names that already carry `.flf`, `.tlf`, `.gz` or `.zip` are tried verbatim.
The built-in `term` font is used only if no `term` file was found.

## Compressed fonts (system zlib)

`font.load` transparently accepts compressed containers:

* `.flf.gz` / `.tlf.gz` are decompressed with zlib's streaming `gzFile`
  interface (`gzopen`/`gzread`/`gzclose`).
* `.flf.zip` / `.tlf.zip` (and any font whose *content* starts with the zip
  signature, which is how TOIlet's repository stores `ascii9.tlf` and friends)
  are read through the central directory. Method 0 (stored) is copied,
  method 8 (deflate) is inflated raw with `inflateInit2_(-MAX_WBITS)`. ZIP64,
  encrypted, multi-disk and non-0/8 compression methods are rejected with a
  clear diagnostic.
* The decompressed limit is 64 MiB, the same as the plain-file limit.

zlib is declared by hand in `src/compressed.zig` (`extern` z_stream /
inflateInit2_ / inflate / inflateEnd / gzopen / gzread / gzclose) and linked
with `mod.linkSystemLibrary("z", .{})`. `link_libc = true` is required as well:
libz allocates through libc, and a non-libc Zig executable can crash on the
first zlib allocation. Only the shared library is needed; no zlib headers are
used and no `@cImport` is generated.

## Limits and diagnostics

* Font files are capped at 64 MiB; control files at 4 MiB.
* Height is capped at 4096 rows.
* Baseline is validated to `1..height` (the FIGfont standard; figlet itself
  does not check this).
* Parse, truncation, missing-glyph and invalid-header errors come with a
  human-readable message in `font.Diag`; callers print it and exit 1. No panic
  path is used for malformed input.
* Compressed fonts are supported through the system zlib (`.gz` streaming,
  `.zip` stored/deflate). Compressed *control files* are still not supported;
  decompress them first. ZIP64, encrypted and multi-disk archives are rejected
  with an explanation.
* A cell is one Unicode codepoint. There is no `wcwidth`/East-Asian-width
  logic; a CJK glyph occupies one cell in the internal canvas even though a
  terminal may draw it two columns wide.

## Tests

`zig build test` runs 20 unit tests covering header parsing (FLF/TLF, optional
fields, invalid values), endmark stripping (spaces, double endmarks, UTF-8),
full font parsing and codetags, truncation errors, all smushing rules, layout
mode bits, width-based wrapping, empty lines, control-file mapping/stages and
the `.tlc` alias, gzip font loading and zip font loading (both deflate and
stored entries) with byte-identical rendering against the plain fixture.

The synthetic fixtures `tiny.flf`, `tiny.tlf`, `tiny.flf.gz`, `tiny.flf.zip`
(deflate) and `tiny_stored.flf.zip` (stored) are generated by
`tools/gen_tiny_font.py`; the plain fonts are exported as
`textfig.fixtures.tiny_flf` / `.tiny_tlf` for downstream CLI tests.

The two zlib rendering tests use a **real** font instead: `mini.flf` is copied
from `refs/figlet/fonts/mini.flf` (New BSD), `mini.flf.gz` is `gzip -9 -n`
output, and `mini.flf.zip` / `mini_stored.flf.zip` are deterministic Python
`zipfile` archives (method 8 and method 0).
