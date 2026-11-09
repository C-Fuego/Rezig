# zlolcat

A rainbow colouring filter for the console: it concatenates files, or standard
input, to standard output (like `cat`) and paints the text with the diagonal
rainbow of the Ruby [lolcat](https://github.com/busyloop/lolcat) original
(v100.0.1).

The colouring loop is not "inspired by" lolcat, it is the same loop: the same
`ANSI_ESCAPE` split, the same per-character `colour + character + \e[39m`
sequence, the same `@os` bookkeeping, the same `\e7`/`\e8` animation, the same
tty check and the same closing `\e[m`.  What the Ruby does with a line is
written out in `src/render.zig` next to the Zig that does it.

```sh
zig build            # -> zig-out/bin/zlolcat
zig build test       # unit tests
ls | ./zig-out/bin/zlolcat
```

Like lolcat, it only colours when **stdout is a terminal**; `-f`/`--force`
overrides that (`ls | zlolcat | cat -v` is a plain `cat`, `ls | zlolcat -f |
cat -v` shows the escapes).

## Colour model

Every character gets its colour from a sine wave.  `i` is the line offset
`@os` plus the character's index inside the line divided by the spread:

```
i     = os + index / spread
angle = frequency * i
r = sin(angle)           * 127 + 128
g = sin(angle + 2pi/3)   * 127 + 128
b = sin(angle + 4pi/3)   * 127 + 128
```

The bytes are truncated towards zero, exactly like Ruby's `"%02X" % float`.

`@os` starts at the seed for every file and grows by **one per line**
(`@os += 1` in `Lol.cat`).  The index inside a line advances the hue by
`frequency / spread` per character, the next line by `frequency / 1`.  This is
the real lolcat behaviour: the `filtered.length/spread` step in
`println_plain` only runs for a line *without* a trailing newline (the tail of
a 4096-byte read) and is undone by the line that follows it.

## Options

The short options are lolcat's own.

| flag | meaning | default |
| --- | --- | --- |
| `-p, --spread <F>` | rainbow spread | `3.0` |
| `-F, --freq <F>` | rainbow frequency (`--frequency` also accepted) | `0.1` |
| `-S, --seed <N>` | starting offset, `0` = random 1..255 | `0` |
| `-a, --animate` | redraw each line `duration` times | off |
| `-d, --duration <N>` | animation frames per line | `12` |
| `-s, --speed <F>` | animation frames per second | `20.0` |
| `-i, --invert` | fg/bg swap: rainbow background, `\e[49m` after each character | off |
| `-t, --truecolor` | force 24-bit colour | `COLORTERM` |
| `-f, --force` | colour even when stdout is not a tty | off |
| `-v, --version` | print the version and exit | - |
| `-h, --help` | print the rainbow help and exit | - |

Extensions (none of them change the default behaviour):

| flag | meaning |
| --- | --- |
| `--256` | force the 256-colour palette |
| `--invert-hue` | rotate the hue by half a cycle |
| `--passthrough-color` | inject no colour of ours, only copy the input |
| `--no-color` | never colour: plain `cat` |
| `-D, --dialup` | random 30-700 ms pause after every line |
| `--no-space-color` | do not spend a colour escape on a space (see below) |

`FILE...` inputs are printed in order; `-` means stdin.  With no file, stdin is
used, and every file starts its rainbow at the same seed (`Lol.cat` resets
`@os` per file).

The licence is MIT; see `LICENSE`.

## Behaviour notes

- Every line is split with lolcat's `ANSI_ESCAPE` into `(escape prefix,
  character)` pairs.  The prefix is copied verbatim, then come our colour, the
  character and `\e[39m` (`\e[49m` with `-i`).  A line therefore ends with one
  extra colour+reset pair: Ruby's `scan` yields the final empty match.
- Colours the input already sets are **overridden**, not respected: `ls
  --color=always | zlolcat -f` repaints every name.
- Spaces, `TAB` (expanded to eight spaces, like `str.gsub! "\t", "        "`),
  `\r`, NUL and stray control bytes are characters and are painted like any
  other.  Nothing is treated as "blank".
- Multi-byte characters are painted per code point (one colour per character,
  never per byte) because Ruby's `.` matches a character in a UTF-8 string.
- Input is processed in 4096-byte blocks, one `sysread` each, and a block that
  ends inside an escape sequence or a half-received code point is completed by
  the next read before anything is printed - both as in the original.  A block
  is gathered for at most 5 ms though: `sysread` returns as soon as *any* byte
  is there, and waiting for the 4096 bytes to actually arrive is what makes a
  filter look hung on a producer that writes `abc` and then goes quiet.
- `-a` hides the cursor once, saves it with `\e7`, draws `duration` frames
  (`\e8` + `@os += spread`, `sleep 1/speed` after every frame) and restores
  `@os` afterwards; between frames `\e[...@JKPX` is stripped from the line.
- Output is staged: the pairs of a line are built in a 32 KiB block that is
  handed to the writer as one piece, instead of four writes per character, and
  it is flushed to the file at the end of *every read* - one `write` per block,
  so the delay of the filter is one read plus at most the 5 ms a block may wait
  to fill (measured: 7-11 ms for a producer that dribbles out one byte at a
  time).  Nothing about the bytes changes - only how they travel.
- At the end of each input, and only when stdout is a terminal, the original's
  `ensure` block is sent: `\e[m\e[?25h\e[?1;5;2004l`.

### Deviations from the Ruby

| topic | lolcat | zlolcat | why |
| --- | --- | --- | --- |
| `-h`/`--help` | prints the rainbow help, then exits **1** (an Optimist artefact) | prints it and exits **0** | a help text is not an error |
| 256-colour rounding | nearest entry of Paint's palette table | nearest entry of the xterm-256 palette (Euclidean RGB) | Paint's exact table is not available here; the sequence structure is identical, `-t` is byte exact |
| invalid UTF-8 / a file ending mid-escape | the buffer that cannot be read to completion is dropped | it is printed (bytes as characters) | never throw input away |
| `--version` text | `lolcat 100.0.1 (c)2011 moe@busyloop.net` | `zlolcat 1.0.0 (c)2011 moe@busyloop.net` | different program |
| extra options | - | `--256`, `--invert-hue`, `--passthrough-color`, `--no-color`, `--no-space-color`, `-D/--dialup` | opt-in only |

### `--no-space-color`

Opt-in, off by default: a space is painted with the colour of its position but
the escape is not printed, so a run of blanks costs one byte each instead of
the usual `\e[38;2;r;g;bm` + space + `\e[39m`.  A space has no glyph, so with a
foreground colour the screen is identical - this only makes sense when the
colour is a foreground one, which is why `-i` (a background colour, visible
behind a space) ignores the flag.  The colour index of every character, the
per-character `\e[39m` of the others and the trailing empty pair are untouched;
tab expansion still produces eight spaces, it just does not colour them.

On the cmatrix stream below this takes the output from 2.42x the input to
1.64x (24 bytes saved per space, and 55% of the characters are spaces), which
is what decides whether a terminal emulator can keep up - see the numbers in
the next section.

## Performance

### What was measured

`script -qec "timeout 1 cmatrix -u 0" /dev/null` gives one second of cmatrix at
the usual 80x24: **3,554,545 bytes** in, of which **225,743 characters** have to
be painted (55% of them spaces) and 3.3 MB are escape sequences copied
verbatim.  `zlolcat -f` turns that into **8,608,525 bytes**, i.e. 2.42x the
input - the arithmetically unavoidable shape of `colour + character +
\e[39m` (25 bytes per character in 24-bit mode).

CPU time of zlolcat alone (`getrusage`, best of five, same conditions for both
builds; 4 MB of plain characters to make the per-character cost visible, plus
the one-second cmatrix stream):

| workload | before | after |
| --- | --- | --- |
| 1 s of cmatrix, 24-bit (`-t`) | 48.6 ms | 21.7 ms |
| 1 s of cmatrix, 256 colours (`--256`) | 400.0 ms | 36.6 ms |
| 4 MB of characters, one line, `-t` | 612 ms | 212 ms |
| 4 MB of characters, one line, `--256` | 6595 ms | 308 ms |
| 4.35 MB of 80-column lines, `-t` | 627 ms | 244 ms |

so 150-175 ns per character became 53-56 ns, and the 256-colour path (which is
what a terminal without `COLORTERM=truecolor` gets) stopped being 11x more
expensive than the 24-bit one.  The end-to-end pipeline still finishes in
1.01 s of wall clock for one second of cmatrix, so nothing is queued up behind
the filter.

Where the time went, from ablation builds of the old code:

| cost | per character |
| --- | --- |
| three libm `sin` calls (`rainbow`) + the byte conversion | 98 ns |
| flat 256-entry palette search (`--256` only) | 1.9 µs |
| `std.fmt` escape + four `std.Io.Writer.writeAll` per character | ~30 ns |
| reading the input (already 4 KiB blocks: 868 reads for 3.5 MB) | ~2 ns |

so: the sine, the palette search and the formatting, not the I/O.  The writes
were 4 calls per character, i.e. ~900k per second of cmatrix; reads were never
byte-at-a-time (868 reads of 4 KiB for the 3.5 MB stream).  On a pty the
remaining cost is the pty itself, which every consumer pays: reading that same
stream costs `cat` 316 ms and `dd bs=64k` 169 ms of CPU per second, while
`zlolcat -t` now needs 212 ms - 77 ms of it in user space.  The colouring has
become cheaper than `cat`'s copying, which is as far as a filter can go.

### What made it fast

| change | where |
| --- | --- |
| the three sines of a line are one `sin`/`cos` pair per 64 characters plus a rotation per character; any channel within 1e-4 of a truncation boundary is recomputed with the real `sin`, so the bytes are the ones `rgbAt` prints | `color.Rainbow` |
| the 256-colour nearest-palette search is closed-form (the cube is separable per channel, the greys are a quadratic) instead of a 256-entry scan, still picking the same entry, ties included | `color.quantize256` |
| escapes are written digit by digit from integer arithmetic instead of `std.fmt` | `render.putEscape` |
| a 32 KiB block is filled and handed over as one piece instead of four writes per character | `Renderer.emit` |
| ASCII characters skip the UTF-8 decoder, the escape matcher only runs when a byte is `ESC`, a line without a tab is not copied | `render.charLength`, `printlnPlain`, `expandTabs` |

### Latency

Cheap output must not become *late* output, and two buffers stood in the way of
that:

1. `readSliceShort` does not return a short read - it fills the whole 4096-byte
   slice before it returns.  A producer that sends `abc` and then pauses left
   the filter waiting for bytes that never came, so `(printf 'abc'; sleep 2) |
   zlolcat` printed nothing for 2.0 s.
2. `writeAll` only fills the writer's buffer.  Without an explicit `flush` the
   last 64 KiB of output sat in it until the buffer filled or the input ended,
   so anything smaller than 64 KiB - the tail of a stream, a line someone is
   waiting for, a cmatrix screen between two of its writes - was held back.

Both are fixed: a block is gathered for at most 5 ms (one `poll` with the
remaining budget, on the file descriptor), and it is written out - staging
block and writer buffer - before the next read is started.  The batching that
the speed-up depends on stays: one read and one write per block, not per
character.

Measured on the same machine, before and after:

| producer | before | after |
| --- | --- | --- |
| `(printf 'abc'; sleep 2) \| zlolcat -f` | first byte after 2003 ms | after 11 ms |
| one byte every 150 ms, no newline | one chunk at the end, 766 ms | 5 chunks, each 7-12 ms after its byte |
| `timeout 3 cmatrix -u 0 \| zlolcat -f` | 723 writes, worst gap 36 ms, first after 26 ms | 946 writes, worst gap 21 ms, first after 11 ms |

The cmatrix row looks tame because 64 KiB of its output only takes 7 ms to
accumulate - but that is the shape of the bug: the delay is whatever it takes
to fill the buffer, and it is unbounded for a producer that is slower or a
terminal that is.

The rotated sine is the only place where "same output" needed proof rather
than a measurement: the rotation is a few ULP away from `sin()`, so every
channel checks whether it is about to truncate near an integer (or near the
0/255 clamp) and falls back to `sin()` there.  With an anchor every 64
characters the accumulated error stays below 1e-9 of a byte step even for
absurdly long lines, i.e. five orders of magnitude under the guard.  The test
in `color.zig` compares 200,000 rotated characters - and every spread,
frequency, seed and `--invert-hue` combination - against `rgbAt` byte for byte.

### Is the output still the original's?

Yes, byte for byte: the same 199-case matrix (plain text, tabs, Chinese, emoji,
ANSI colour, an OSC title, `\r\n`, NULs and other control bytes, invalid UTF-8,
a 4 MB line, a split escape at a block boundary, the cmatrix streams, several
files at once, `-a`, `-i`, `--256`, `--256 -i`, `--invert-hue`,
`--passthrough-color`, `--no-color`, several `-S`/`-p`/`-F`) was diffed against
the build before the change: every byte identical.  Only `--help` grew the one
line that documents `--no-space-color`.

Two further volume tricks were measured and rejected, because both change the
bytes and neither is needed: dropping the per-character `\e[39m` (5 of the 25
bytes, so 20% in 24-bit mode), and skipping the colour when two neighbouring
characters quantise to the same palette entry - in `--256` that is 84% of the
characters and 28% of the output of a cmatrix stream, but in the 24-bit default
*none* of the 226,122 characters of that stream repeats its predecessor, so the
trick buys nothing where it would hurt most.  Keeping every character's
`colour + character + \e[39m` also means no `--strict` switch and no
"optimisation difference" to remember.
