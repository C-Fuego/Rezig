# zbonsai

A beautifully random bonsai tree generator for the terminal: it grows a tree
branch by branch, live, forever, or as a screensaver, and reproduces the
output of [cbonsai](https://gitlab.com/jallbrit/cbonsai) character for
character for the same seed and terminal size. No third-party dependencies:
no ncurses, no libc, no vaxis/clap. Just `zig` and `std.os.linux`.

```
$ zbonsai -p -s 42
                                     &&&&&&&&
                                  &&&&&&&&&&&&
                                &&&&&&&&&&&&&&&
                               &&&&&&&&&&&&&&&&
                              &&&&&&&&&&&&\&&& &
                              &&&&&&|&&&&||/&&
                             &&&&&&&&&&&&_/&&
                       &     &&& &\&/~&&&&/~
                      &&&  &  &   //&\  &/|\~/
                     &&&&&&\&&_\_ \|/    \//~                  &
                       &&&_\ &  \_/~~\    /~|               &&&&&&
                     &&&&        ///~       /|\           &  &&&&&&&
                       &          /~|       \|    /___/     /_&_&&
                                  /|/~     \|/~/_/     / _/_/  &&&&
                                  /~        |/~                  &
                                   /~|   |//~
                                     /~|~
                                       /~
                         :___________./~~~\.___________:
                          \                           /
                           \_________________________/
                           (_)                     (_)
```

## Build & test

```sh
zig build                 # -> zig-out/bin/zbonsai
zig build test            # 28 unit tests
zig build run -- -p -s 42 # run from the build graph
```

Requires Zig 0.17.0.

## Usage

```
zbonsai [OPTION]...

  -l, --live             live mode: show each step of growth
  -t, --time=TIME        in live mode, wait TIME secs between steps of
                           growth (must be larger than 0) [default: 0.03]
  -i, --infinite         infinite mode: keep growing trees
  -w, --wait=TIME        in infinite mode, wait TIME between each tree
                           generation [default: 4.00]
  -S, --screensaver      screensaver mode; equivalent to -li and quit on
                           any keypress
  -m, --message=STR      attach message next to the tree
  -b, --base=INT         ascii-art plant base to use, 0 is none
  -c, --leaf=LIST        list of comma-delimited strings randomly chosen
                           for leaves [default: &]
  -k, --color=LIST       list of 4 comma-delimited color indices (0-255) for
                           dark leaves, dark wood, light leaves, light wood
                           [default: 2,3,10,11]
  -M, --multiplier=INT   branch multiplier; higher -> more branching (0-20)
                           [default: 5]
  -L, --life=INT         life; higher -> more growth (0-200) [default: 32]
  -p, --print            print tree to terminal when finished
  -s, --seed=INT         seed random number generator
  -v, --verbose          increase output verbosity
  -h, --help             show help
  -V, --version          show version
```

Values may be attached (`-t0.01`, `--time=0.01`) or separate (`-t 0.01`), and
short flags cluster (`-li`).

## How it works

* `src/tree.zig` — the growth algorithm, following cbonsai's recursive
  `branch()` line by line: five branch kinds (trunk, left/right shoot, dying, dead), the
  same weighted dice tables, the same "dying branches turn into leaves" rules.
* `src/rand.zig` — glibc's `rand()` (TYPE_3 additive feedback), bit-compatible.
  cbonsai uses plain `srand()`/`rand()`, so reusing the generator means
  `zbonsai -s 42` grows the *same tree* as `cbonsai -s 42`, not merely a
  similar one.
* `src/canvas.zig` — a cell grid replacing ncurses' windows, plus a renderer
  that diffs the grid against the previous frame and only emits the changed
  runs (that is what `doupdate()` did for cbonsai).
* `src/message.zig` — word wrapping and the framed message box.
* `src/base.zig` — the two ASCII pots (31x4 and 15x3).
* `src/term.zig` — raw mode, window size, key polling, SIGWINCH/INT/TERM, all
  through `std.os.linux` syscalls with errno decoding.
* `src/main.zig` — mode dispatch: static, live, infinite, screensaver, print.

Growth is computed up front into a list of glyphs, each tagged with a *stage*
(`tick`). Live mode replays the list one stage at a time, which is why pressing
a key can skip the rest of the animation instantly and why a resize can simply
regrow from the same seed — exactly the trick cbonsai's `redrawCurrentTree()`
uses.

## Behaviour notes

* Colours are 256-colour ANSI (`ESC[38;5;Nm`), wood uses `-k` indexes 1 and 3,
  leaves 0 and 2; the pot and the message box use colour 8.
* `-S` is `-l -i` plus "any key quits"; while growing, `q` quits in live mode
  and any other key skips the remaining waits.
* The message box sits at ~70% of the terminal and is opaque: the tree never
  shows through it.
* A terminal too small for the pot simply hides the pot; the tree is clipped to
  the grid instead of crashing or drawing outside it.
* **Non-TTY** (e.g. `zbonsai -p | cat`, or any sandbox without a pty): the TUI
  is skipped entirely, one static tree is printed as plain text without escape
  sequences, and the program exits 0. `ZBONSAI_FORCE_TTY=1` forces the TUI path
  on a pipe, which is handy for smoke tests.

## Differences from cbonsai

| cbonsai | zbonsai |
| --- | --- |
| `-T/--text-origin`, `-g/--geometry`, `-W/--save`, `-C/--load` | not implemented (rejected with an explicit message) |
| screensaver save/load to `$XDG_CACHE_HOME/cbonsai` | not implemented |
| ncurses writes past the last column wrap to the next row | such glyphs are clipped (keeps growth inside the grid) |
| `-M 0` / `-L` out of range divides by zero or draws junk | `-M` limited to 0-20, `-L` to 0-200, `-M 0` behaves like 1 |
| invalid option → help printed, exit 0 | error message on stderr, exit 1 |
| `-v` prints `dx/dy/type/shootCooldown` | prints maxX/maxY, life, multiplier, shoots, branches, stages, nodes, seed, base |
| ncurses wide-char overlap semantics | a double-width leaf erases cleanly instead of leaving half a glyph |
| `--screensaver` caches the tree | each run starts fresh |

Everything else — the random walk, the pot art, the wrapping, the colours, the
messages — reproduces cbonsai's output character for character for the same
seed and terminal size (verified against cbonsai built from upstream `main`;
see the tests and the project report).

## Tests

`zig build test` runs 28 unit tests covering:

* branch growth never leaves the tree window (five terminal sizes, tiny ones
  included) and stage numbers stay monotonic (live replay depends on it),
* branch/shoot/lifecycle counts scale with `-L`/`-M`, custom leaf glyphs are
  the only thing drawn on dying branches,
* the golden tree for `-s 42` at 80x24 (512 stages, 653 glyphs, 360 branches,
  3 shoots) plus a position/glyph checksum,
* message word wrapping (width limits, explicit newlines, hard-broken long
  words, empty message) and the box staying inside a small terminal,
* canvas clipping, the frame diff renderer, and double-width glyph handling,
* glibc `rand()` compatibility against reference values,
* argument parsing (defaults, clusters, `--x=y`, `--x y`, errors).
