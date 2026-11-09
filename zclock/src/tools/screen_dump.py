#!/usr/bin/env python3
"""把 zclock 的 ANSI 输出重放到一块虚拟 80x24 屏幕上，肉眼检查布局/颜色。"""
"""把 zclock 的 ANSI 输出重放成一块虚拟 80x24 屏幕，肉眼核对布局/颜色。
用法：python3 tools/screen_dump.py   （先 zig build）
"""
import os, re, select, subprocess, sys, time

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "zclock")
COLS, ROWS = 80, 24

def run(args, seconds=0.9, keys=b"q"):
    env = dict(os.environ, ZCLOCK_FORCE_TTY="1", TERM="xterm-256color")
    p = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=env)
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.05)
        if r:
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                break
            out += chunk
    p.stdin.write(keys); p.stdin.flush()
    p.wait(timeout=5)
    return out

def render(data):
    screen = [[(" ", None, None) for _ in range(COLS)] for _ in range(ROWS)]
    row = col = 0
    fg = bg = None
    bold = blink = False
    i = 0
    while i < len(data):
        b = data[i]
        if b == 0x1B:
            m = re.match(rb"\x1b\[([0-9;?]*)([A-Za-z])", data[i:])
            if not m:
                i += 1
                continue
            params, final = m.group(1).decode(), m.group(2).decode()
            i += m.end()
            if final == "H":
                parts = params.split(";")
                row = int(parts[0]) - 1 if parts and parts[0] else 0
                col = int(parts[1]) - 1 if len(parts) > 1 and parts[1] else 0
            elif final == "J" and params == "2":
                screen = [[(" ", None, None) for _ in range(COLS)] for _ in range(ROWS)]
            elif final == "m":
                codes = [int(x) for x in params.split(";")] if params else [0]
                for c in codes:
                    if c == 0:
                        fg = bg = None; bold = blink = False
                    elif c == 1:
                        bold = True
                    elif c == 5:
                        blink = True
                    elif 30 <= c <= 37:
                        fg = c - 30
                    elif 40 <= c <= 47:
                        bg = c - 40
            continue
        # 普通字节（我们的输出只有 ASCII 与 UTF-8 制表符）
        if b < 0x80:
            ch = chr(b)
            i += 1
        else:
            for n in (3, 2, 4):
                try:
                    ch = data[i:i + n].decode("utf-8")
                    i += n
                    break
                except UnicodeDecodeError:
                    ch = "?"
                    i += 1
        if 0 <= row < ROWS and 0 <= col < COLS:
            screen[row][col] = (ch, fg, bg)
        col += 1
    return screen

def show(screen, title):
    colors = "0黑 1红 2绿 3黄 4蓝 5洋红 6青 7白".split()
    print(f"===== {title} =====")
    print("   +" + "-" * COLS + "+")
    for r, line in enumerate(screen):
        buf = "".join(("█" if bg is not None else ch) for (ch, fg, bg) in line)
        print(f"{r:2d} |{buf}|")
    print("   +" + "-" * COLS + "+")
    used = sorted({bg for line in screen for (_, _, bg) in line if bg is not None} |
                  {fg for line in screen for (_, fg, _) in line if fg is not None})
    print("使用到的颜色:", ", ".join(colors[c] for c in used) if used else "无")
    print()

if __name__ == "__main__":
    show(render(run(["-c", "-s", "-x", "-t", "-C", "4", "-f", "%A, %d %B %Y"])),
         "zclock -c -s -x -t -C 4 -f '%A, %d %B %Y'  (80x24 虚拟屏)")
    show(render(run(["-c", "-C", "6", "-B"], seconds=1.2)) + [],
         "zclock -c -C 6 -B  （整点无秒）")
