#!/usr/bin/env python3
"""沙箱里没有 /dev/ptmx，所以用管道 + ZCLOCK_FORCE_TTY=1 验证交互路径。"""
"""交互路径自测：没有 pty 的环境里用管道 + ZCLOCK_FORCE_TTY=1。
用法：python3 tools/interactive_check.py   （先 zig build）
"""
import os, signal, subprocess, sys, time

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "zclock")

def spawn(args):
    env = dict(os.environ)
    env["ZCLOCK_FORCE_TTY"] = "1"
    env["TERM"] = "xterm-256color"
    p = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return p

def read_for(p, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        # 非阻塞读：用 select
        import select
        r, _, _ = select.select([p.stdout], [], [], 0.05)
        if r:
            chunk = os.read(p.stdout.fileno(), 65536)
            if not chunk:
                break
            out += chunk
    return out

def show(tag, data, n=260):
    print(f"--- {tag}: {len(data)} bytes")
    print(repr(data[:n]))
    print()

fail = []
def check(name, cond):
    print(("PASS  " if cond else "FAIL  ") + name)
    if not cond:
        fail.append(name)

# 1) 启动画面 + q 退出
p = spawn(["-s", "-x"])
first = read_for(p, 0.8)
show("startup -s -x", first)
p.stdin.write(b"q"); p.stdin.flush()
tail = read_for(p, 0.8)
rc = p.wait(timeout=5)
show("after q", tail, 120)
check("alternate screen entered", b"\x1b[?1049h" in first)
check("cursor hidden", b"\x1b[?25l" in first)
check("absolute positioning used", b"\x1b[1;" in first)
check("green block background (\\e[42m)", b"\x1b[42m" in first)
check("box drawn", "\u250c".encode() in first or b"+" in first)
check("exit code 0 on q", rc == 0)
check("cursor restored", b"\x1b[?25h" in tail)
check("alternate screen left", b"\x1b[?1049l" in tail)

# 2) 按键：取消居中、移动、开秒、换色、暂停、Esc
p = spawn(["-c", "-C", "2"])
read_for(p, 0.4)
for key in [b"c", b"l", b"j", b"s", b"4", b" "]:
    p.stdin.write(key); p.stdin.flush(); time.sleep(0.12)
moved = read_for(p, 0.8)
show("after c l j s 4 SPACE", moved, 400)
check("color 4 applied (\\e[44m)", b"\x1b[44m" in moved)
check("seconds frame is wider (54 cols -> \\e[;5?H)", b"H" in moved)
p.stdin.write(b"\x1b"); p.stdin.flush()
tail = read_for(p, 0.6)
rc = p.wait(timeout=5)
check("Esc quits", rc == 0)
check("restored after Esc", b"\x1b[?25h" in tail and b"\x1b[?1049l" in tail)

# 3) SIGTERM 优雅退出并恢复
p = spawn(["-d", "1"])
head = read_for(p, 0.5)
os.kill(p.pid, signal.SIGTERM)
tail = read_for(p, 0.8)
rc = p.wait(timeout=5)
show("SIGTERM tail", tail, 120)
check("SIGTERM exit code 0", rc == 0)
check("SIGTERM restored terminal", b"\x1b[?25h" in tail and b"\x1b[?1049l" in tail)

# 4) SIGINT（Ctrl-C 的信号路径）同样恢复
p = spawn([])
read_for(p, 0.4)
os.kill(p.pid, signal.SIGINT)
tail = read_for(p, 0.8)
rc = p.wait(timeout=5)
check("SIGINT exit code 0", rc == 0)
check("SIGINT restored terminal", b"\x1b[?25h" in tail and b"\x1b[?1049l" in tail)

# 5) SIGWINCH 重排 + 清屏
p = spawn(["-c", "-s"])
read_for(p, 0.4)
os.kill(p.pid, signal.SIGWINCH)
after = read_for(p, 0.7)
check("SIGWINCH clears screen", b"\x1b[2J" in after)
check("SIGWINCH redraws", b"H" in after and len(after) > 200)
p.stdin.write(b"q"); p.stdin.flush()
p.wait(timeout=5)

# 6) 屏保模式 -S：任意键退出
p = spawn(["-S"])
read_for(p, 0.4)
p.stdin.write(b"z"); p.stdin.flush()
rc = p.wait(timeout=5)
check("screensaver any-key exit", rc == 0)

# 7) -n 不因按键退出（用 SIGTERM 收尾）
p = spawn(["-n"])
read_for(p, 0.4)
p.stdin.write(b"q"); p.stdin.flush()
time.sleep(0.4)
check("-n ignores q", p.poll() is None)
os.kill(p.pid, signal.SIGTERM)
rc = p.wait(timeout=5)
check("-n exits on SIGTERM", rc == 0)

# 8) stdin EOF：继续当时钟跑（原版 pselect 的行为），用 SIGTERM 收尾
p = spawn([])
read_for(p, 0.4)
p.stdin.close()
time.sleep(0.5)
check("stdin EOF keeps running", p.poll() is None)
os.kill(p.pid, signal.SIGTERM)
rc = p.wait(timeout=5)
check("SIGTERM exits after EOF", rc == 0)

# 9) -T 错误处理
r = subprocess.run([BIN, "-T", "/dev/null"], capture_output=True, text=True)
print("zclock -T /dev/null ->", r.returncode, r.stderr.strip())
check("-T non-tty rejected with exit 1", r.returncode == 1 and "character device" in r.stderr)
r = subprocess.run([BIN, "-T", "/nonexistent/tty"], capture_output=True, text=True)
print("zclock -T /nonexistent/tty ->", r.returncode, r.stderr.strip())
check("-T missing path rejected with exit 1", r.returncode == 1 and "couldn't be opened" in r.stderr)

# 10) 屏保 + -n：数字键换色仍能工作
p = spawn(["-S", "-n"])
read_for(p, 0.4)
p.stdin.write(b"5"); p.stdin.flush()
out = read_for(p, 0.6)
check("screensaver -n digit changes color", b"\x1b[45m" in out)
os.kill(p.pid, signal.SIGTERM)
p.wait(timeout=5)

print()
if fail:
    print("FAILED:", fail)
    sys.exit(1)
print("ALL CHECKS PASSED")
