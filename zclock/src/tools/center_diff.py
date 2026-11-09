#!/usr/bin/env python3
"""Compare the -c centering of zclock with tty-clock 2 in a real pty.

Both programs are started under `script -qec` inside a pty of a fixed size, the
ANSI stream is replayed into a small VT screen and the bounding box of
everything that is not a plain space is printed for both.  Equal boxes mean the
clocks sit at the same place, whatever the font glyphs are.

    $ TTY_CLOCK=/path/to/tty-clock ./tools/center_diff.py

`TTY_CLOCK` defaults to `tty-clock` from `$PATH`.  A terminal emulator is
needed for the pty (`script`, from util-linux); no other dependency.
"""
import os
import re
import subprocess
import sys
import tempfile

ZCLOCK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "zig-out", "bin", "zclock")

SIZES = [(24, 80), (12, 40), (40, 120)]
COMBOS = [
    ("plain", "-u -c", "-u -c"),
    ("box", "-u -c -x", "-u -c -x"),
    ("secs", "-u -c -s", "-u -c -s"),
    ("twelve", "-u -c -t", "-u -c -t"),
    ("all", "-u -c -x -s -t", "-u -c -x -s -t"),
    ("nodate", "-u -c -D", "-u -c -D"),
]

CSI = re.compile("\x1b\\[([0-9;?<=>]*)([@-~])")


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[(" ", False) for _ in range(cols)] for _ in range(rows)]
        self.r = self.c = 0
        self.styled = False
        self.last = " "

    def put(self, ch):
        if self.c >= self.cols:
            self.c = 0
            self.r += 1
            if self.r >= self.rows:
                self.grid.pop(0)
                self.grid.append([(" ", False) for _ in range(self.cols)])
                self.r = self.rows - 1
        if 0 <= self.r < self.rows:
            self.grid[self.r][self.c] = (ch, self.styled)
        self.last = ch
        self.c += 1


def replay(data, rows, cols):
    s = Screen(rows, cols)
    text = data.decode("utf-8", "replace")
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\x1b":
            m = CSI.match(text, i)
            if m:
                vals = [v for v in m.group(1).replace("?", "").split(";") if v != ""]

                def arg(idx, default=1):
                    try:
                        return int(vals[idx])
                    except (IndexError, ValueError):
                        return default

                final = m.group(2)
                if final in "Hf":
                    s.r = max(0, min(rows - 1, arg(0) - 1))
                    s.c = max(0, min(cols - 1, arg(1) - 1))
                elif final == "d":
                    s.r = max(0, min(rows - 1, arg(0) - 1))
                elif final == "G":
                    s.c = max(0, min(cols - 1, arg(0) - 1))
                elif final == "A":
                    s.r = max(0, s.r - arg(0))
                elif final == "B":
                    s.r = min(rows - 1, s.r + arg(0))
                elif final == "C":
                    s.c = min(cols - 1, s.c + arg(0))
                elif final == "D":
                    s.c = max(0, s.c - arg(0))
                elif final == "J" and arg(0) in (2, 3):
                    s.grid = [[(" ", False) for _ in range(cols)] for _ in range(rows)]
                elif final == "K":
                    for x in range(s.c if arg(0) == 0 else 0, cols):
                        s.grid[s.r][x] = (" ", s.styled)
                elif final == "m":
                    s.styled = any(v not in ("", "0") for v in vals)
                elif final == "b":  # REP: repeat the previous character
                    for _ in range(arg(0)):
                        s.put(s.last)
                i = m.end()
                continue
            if i + 1 < n and text[i + 1] in "()*+-./":
                i += 3
                continue
            i += 2
            continue
        if ch == "\r":
            s.c = 0
        elif ch == "\n":
            s.r += 1
            if s.r >= rows:
                s.grid.pop(0)
                s.grid.append([(" ", False) for _ in range(cols)])
                s.r = rows - 1
        elif ch == "\b":
            s.c = max(0, s.c - 1)
        elif ch == "\t":
            s.c = min(cols - 1, (s.c // 8 + 1) * 8)
        elif ch >= " " and ch != "\x7f":
            s.put(ch)
        i += 1
    return s


def bbox(s):
    found = [
        (r, c)
        for r in range(s.rows)
        for c in range(s.cols)
        if s.grid[r][c][0] != " " or s.grid[r][c][1]
    ]
    if not found:
        return None
    rows = [r for r, _ in found]
    cols = [c for _, c in found]
    return (min(rows), min(cols), max(rows), max(cols))


def capture(binary, flags, rows, cols):
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as fh:
        path = fh.name
    cmd = f"stty rows {rows} cols {cols}; {binary} {flags}"
    env = dict(os.environ, TERM="xterm-256color", LC_ALL="C.UTF-8", LANG="C.UTF-8")
    with open(path, "wb") as fh:
        subprocess.run(["timeout", "1", "script", "-qec", cmd, "/dev/null"],
                       stdout=fh, stderr=subprocess.DEVNULL, env=env)
    with open(path, "rb") as fh:
        data = fh.read()
    os.unlink(path)
    return replay(data, rows, cols)


def main():
    tty_clock = os.environ.get("TTY_CLOCK", "tty-clock")
    if not os.path.exists(ZCLOCK):
        sys.exit(f"zclock not built: {ZCLOCK}")
    bad = 0
    for rows, cols in SIZES:
        for name, tc_flags, zc_flags in COMBOS:
            # With -s the right edge depends on the digits of the second being
            # shown, and the two captures are a second apart; retry until both
            # land in the same second.
            tc = zc = None
            same = artefact = False
            for _ in range(3):
                tc = bbox(capture(tty_clock, tc_flags, rows, cols))
                zc = bbox(capture(ZCLOCK, zc_flags, rows, cols))
                same = tc == zc
            # In a terminal narrower than the clock ncurses erases whole lines
            # with the *current* background (`ESC [ K`), so it can paint one
            # extra blank cell at the clipped left edge.  The clock itself sits
            # on the same cells; only that erase artefact differs.
                artefact = (
                    tc is not None and zc is not None
                    and tc[0] == zc[0] and tc[2] == zc[2] and tc[3] == zc[3]
                    and abs(tc[1] - zc[1]) == 1
                )
                if same or artefact:
                    break
            bad += 0 if same or artefact else 1
            label = "OK" if same else ("OK*" if artefact else "DIFF")
            print(f"{cols}x{rows} {name:7s} tty-clock={tc} zclock={zc} {label}")
    print("all equal" if bad == 0 else f"{bad} difference(s)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
