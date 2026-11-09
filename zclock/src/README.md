# zclock

tty-clock 2 风格的终端时钟：大号点阵数字 + 日期，ANSI 绝对定位，每帧原地
重绘，不清屏、不闪。目标二进制 `zig-out/bin/zclock`。

- 不链 libc，不引第三方依赖（`build.zig.zon` 里 `.dependencies = .{}`）
- 大号点阵时钟 + 日期，ANSI 绝对定位每帧原地重绘，不清屏、不闪
- 参数、几何、按键全部以 <https://github.com/xorg62/tty-clock> 的
  `ttyclock.c` / `ttyclock.h` 的 getopt 串 `iuvsScbtrhBxnDC:f:d:T:a:` 为准逐条对齐

## 文件结构

```
zclock/
├── build.zig          0.17 语法：createModule + root_module，run 用 addPassthruArgs
├── build.zig.zon      name/version/fingerprint/minimum_zig_version，无依赖
├── README.md
├── tools/             交互自测脚本（不属于构建产物）
│   ├── interactive_check.py   管道 + ZCLOCK_FORCE_TTY 验证按键/信号/恢复（26 项断言）
│   ├── screen_dump.py         把 ANSI 输出重放成虚拟 80×24 屏幕，肉眼核对布局
│   └── center_diff.py         真实 pty（script -qec）里逐格对比 -c 居中 vs tty-clock
└── src/
    ├── main.zig       进程入口、App 状态机（几何/按键/主循环）、strftime 落盘、自测
    ├── args.zig       getopt 风格的 19 个参数解析（+ 单测）
    ├── font.zig       ttyclock.h 的原版 3×5 点阵，横向复制成 6×5（+ 单测）
    ├── render.zig     画布/布局/ANSI 发射/纯文本降级（+ 单测）
    ├── clocktime.zig  unix→公历、12/24 小时、strftime 子集（+ 单测）
    ├── tz.zig         自己解析 TZif 拿本地偏移（没有 libc 就没有 localtime）
    └── term.zig       裸系统调用：写/读/ioctl/cbreak/ppoll/信号
```

## 构建 / 运行 / 测试

```sh
zig build                     # 产物 zig-out/bin/zclock
zig build test                # 29 个单测
zig build run -- -s -x        # 0.17 里 Build 没有 b.args，用 passthru 传参

./zig-out/bin/zclock -c -s -x -C 4 -t

python3 tools/interactive_check.py   # 交互路径自测（不需要 pty）
python3 tools/screen_dump.py         # 打印虚拟屏幕上的一帧
TTY_CLOCK=/path/to/tty-clock python3 tools/center_diff.py   # 居中 vs 原版（需要 pty）
```

## 参数表（与 tty-clock 2 原版逐条对照）

原版 getopt 串：`iuvsScbtrhBxnDC:f:d:T:a:`，共 **19** 个选项；下表逐条对应。
`-h` 的帮助正文按 `ttyclock.c` 的 `usage` 逐行照抄（只去掉行尾补白空格），
扩展说明放在 `keys:` / `extended keys:` / `notes:` 三段里。

| 原版 | 原版含义（ttyclock.c） | zclock | 说明 |
| --- | --- | --- | --- |
| `-s` | Show seconds | ✅ | 帧宽 35 → 54 列（`NORMFRAMEW`/`SECFRAMEW`） |
| `-S` | Screensaver mode：任意键退出 | ✅ | 配 `-n` 时按数字键仍能换色（原版逻辑如此） |
| `-x` | Show box | ✅ | 用 Unicode 制表符（locale 是 UTF-8 时）或 ASCII `+-|` |
| `-c` | 时钟居中 | ✅ | 行 = `rows/2 - 7/2`，列 = `cols/2 - w/2`，`w` = 35 / 54；实测与 tty-clock 逐格相同，见"居中"一节 |
| `-C [0-7]` | 设置颜色 | ✅ | 0-7 逐值对齐；**额外**接受色名（black…white）。越界值保持原值（与原版 atoi 判断一致） |
| `-b` | Use bold colors | ✅ | 见"照抄的怪癖"：数字块加 `A_BLINK`（SGR 5），日期加粗（SGR 1） |
| `-t` | 12h format | ✅ | `>12` 减 12、`0` 显示 12、日期行尾追加 `" [AM]"/" [PM]"` |
| `-u` | Use UTC | ✅ | 偏移 0，`%Z` 报 `UTC`；优先于 `TZ` |
| `-T tty` | 输出到指定 tty | ✅（有降级） | `open(path, O_RDWR)` + `TCGETS` 判定终端；打不开直接 `exit(1)`，同原版 |
| `-r` | Do rebound | ✅ | 每帧按 `(a,b)` 移动并在四边反弹，边界公式照抄（含 off-by-one） |
| `-f format` | 日期 strftime 格式 | ✅（子集） | 默认 `%F`；支持 `%a%A%b%B%c%C%d%D%e%F%H%I%j%k%l%m%M%n%p%P%r%R%s%S%t%T%u%w%x%X%y%Y%z%Z%%`，超 99 字节截断（原版 `format[100]`） |
| `-n` | 按键不退出 | ✅ | `q`/`Q`/`Esc`/屏保任意键都失效，只能等信号 |
| `-v` | 版本 | ✅ | `zclock 1.0.0 (tty-clock 2 compatible)`，stdout，`exit 0` |
| `-i` | 版权信息 | ✅ | 附原版作者署名 |
| `-h` | 帮助 | ✅ | 未知选项也打印 usage 然后 `exit 0`（原版 `default` 分支如此） |
| `-D` | Hide date | ✅ | 只画 7 行时间窗 |
| `-B` | 冒号闪烁 | ✅ | `time(NULL) % 2`（不是毫秒），照抄 |
| `-d delay` | 重绘间隔（秒，0-99） | ✅ | 默认 1；越界忽略 |
| `-a nsdelay` | 额外纳秒延迟（0-1e9） | ✅ | 默认 0；`ppoll` 用 `{tv_sec=delay, tv_nsec=nsdelay}`，与原版 `pselect` 等价 |

> 任务描述里把 `-S`、`-a`、`-r`、`-B`、`-n` 的语义记成了"不显示秒 / AM-PM / 反色 /
> 闪烁开关 / 不加边框间隔"，实际源码是 **屏保 / 纳秒延迟 / 反弹 / 冒号闪烁 / 按键不退出**。
> 这里一律以源码为准。原版也**没有** `-s` 的反向开关，秒只由 `-s` 打开。

## 运行时按键

原版绑定（`key_event()` 逐条对齐）：

| 键 | 行为 |
| --- | --- |
| `q` / `Q` | 退出（`-n` 时无效） |
| `↑`/`k`、`↓`/`j`、`←`/`h`、`→`/`l` | 移动时钟；居中时无效；边界公式同原版 |
| `s` / `S` | 切换秒（变宽后若越界会整体左移，`set_second()` 逻辑） |
| `t` / `T` | 切换 12/24 小时 |
| `c` / `C` | 切换居中（居中会关掉 rebound） |
| `b` / `B` | 切换 bold |
| `r` / `R` | 切换反弹（开反弹会关掉居中） |
| `x` / `X` | 切换边框 |
| `0`-`7` | 直接选颜色 |
| `Ctrl-C` | 退出（cbreak 保留 ISIG，走 SIGINT → 信号处理 → 恢复终端） |

zclock 额外绑定（原版没有，但**不与任何原版键冲突**，且是任务要求项）：

| 键 | 行为 |
| --- | --- |
| `Esc` | 退出（方向键的 `ESC [ x` 序列优先，不会被误判） |
| `+` / `=`、`-` / `_` | 颜色 +1 / -1（0-7 循环） |
| `p` / `Space` | 暂停 / 继续走时（暂停时冻结时间与闪烁相位） |

## 渲染与几何（和原版逐条对齐）

| 常量 | 原版 | zclock |
| --- | --- | --- |
| 时间窗宽 | `NORMFRAMEW 35` / `SECFRAMEW 54` | 同 |
| 时间窗高 | 7 | 同 |
| 日期窗高 | `DATEWINH 3` | 同 |
| 数字点阵 | `number[][15]`，3×5，每点横向 2 格 | `font.zig` 逐位相同 |
| 数字位置 | 行 1，列 1 / 8 / 20 / 27 /（39 / 46） | 同 |
| 冒号 | 行 2、4，列 16（带秒时列 35），2 格宽 | 同 |
| 日期文本行 | `geo.x + 7` | 同 |
| 日期文本列 | `geo.y + w/2 - len/2` | 同（`@divTrunc` 模拟 C 的整数除法） |
| 日期框 | `newwin(3, len+2, x+6, y+w/2-len/2-1)`，与时间框底边重合 | 同（后画，覆盖时间框底边） |
| 颜色语义 | 数字=反显色块（bg=color），日期=前景色，边框=默认色 | 同：数字 `\e[4Nm`，日期 `\e[3Nm`，框 `\e[0m` |
| 冒号闪烁 | `-B` 且 `time(NULL)%2==0` 时用 `COLOR_PAIR(2)` → 不可见 | 同（该帧画成空格） |
| 脏矩形 | ncurses 自己 diff | 记住上一帧矩形，位置/宽度变化时先擦掉旧矩形再重绘 |

每帧只发 `\e[{row};{col}H` + 需要改的样式（`SGR` 变化时才重发），**不清屏**，
所以不会闪。屏幕比时钟小时按屏幕裁剪，不写最后一格（避免触发滚动）。

## 居中（`-c`）：实测与 tty-clock / clock-rs 对照

### 公式

原版 `set_center()` 就是两行：

```c
clock_move((LINES / 2 - (geo.h / 2)),      /* 行 */
           (COLS  / 2 - (geo.w / 2)),      /* 列 */
           geo.w, geo.h);
```

`geo.h` 恒为 **7**，`geo.w` 恒为 **35**（`NORMFRAMEW`）或 **54**（`SECFRAMEW`，
只有 `-s` 会切到它）。`-x` 的边框、日期窗（`len+2` 宽）和 `-t` 追加的 `" [AM]"`
都**不改变** `geo.w`：它们只改画进窗口里的内容，所以不参与居中计算。zclock 的
`setCenter()` 与之一致（`@divTrunc` 模拟 C 的整数除法，正数下等同）。

### 真实 pty 实测（`script -qec`，逐帧解析坐标）

方法：`script -qec "stty rows R cols C; <程序> -u -c …" /dev/null` 抓帧，用一个
小 VT 解析器（支持 CUP/VPA/CHA/REP/EL 等）重放到 R×C 屏幕上，取"所有非普通空格
单元"的包围盒（行, 列, 行, 列，0-based）。tty-clock 用 `rustrefs/orig_tty_clock`
原样 `make` 出来的可执行文件。

| 尺寸 | 参数 | tty-clock | zclock |
| --- | --- | --- | --- |
| 80x24 | `-c` | (10, 24, 16, 55) | (10, 24, 16, 55) |
| 80x24 | `-c -x` | (9, 23, 17, 57) | (9, 23, 17, 57) |
| 80x24 | `-c -s` | (10, 14, 16, 64) | (10, 14, 16, 64) |
| 80x24 | `-c -t` | (10, 24, 16, 55) | (10, 24, 16, 55) |
| 80x24 | `-c -x -s -t` | (9, 13, 17, 66) | (9, 13, 17, 66) |
| 80x24 | `-c -D` | (10, 24, 14, 55) | (10, 24, 14, 55) |
| 40x12 | `-c` | (4, 4, 10, 35) | (4, 4, 10, 35) |
| 40x12 | `-c -s` | (1, 1, 10, 39) | (1, 1, 10, 39) |
| 40x12 | `-c -x -s -t` | (0, 0, 11, 39) | (0, 0, 11, 39) |
| 120x40 | `-c` | (18, 44, 24, 75) | (18, 44, 24, 75) |
| 120x40 | `-c -s` | (18, 34, 24, 84) | (18, 34, 24, 84) |
| 120x40 | `-c -x -s -t` | (17, 33, 25, 86) | (17, 33, 25, 86) |

（完整矩阵在 `tools/center_diff.py`：三种尺寸 × 六种组合，`all equal`。`-s` 的
包围盒右边界取决于当前秒数的字形，所以脚本会在同一秒内重试；终端比时钟还窄时
ncurses 会用带背景色的 `\e[K` 擦整行，左边界偶尔多算一个纯背景格，脚本把它标成
`OK*` —— 时钟本身的坐标仍然逐格相同。）

### 照抄的 ncurses 细节：`mvwin()` 挪不动的窗口

40x12 上带 `-s` 时时钟宽 54 列，`cols/2 - w/2 = -7`。原版把 `-7` 交给
`mvwin(framewin, 3, -7)`，而 ncurses 的 `mvwin()` **拒绝**把窗口挪到屏幕外
（负坐标，或者窗口会伸出右/下边界时返回 `ERR`，位置不变）。tty-clock 从不检查
返回值，于是 `geo` 记着 `(3, -7)`、窗口却留在 `(0, 0)`，日期窗（另一次
`mvwin()`，它放得下）照常挪到 `(9, 14)`。屏幕上就是"时钟贴左上角被裁掉 + 日期
框飘在下面"。

zclock 照抄这个行为：`geo` 是逻辑坐标，`win_x/win_y` 是窗口的实际位置，两者在
放不下时会分家（`clockMove` / `moveDateWindow`）。不这么做的话 40x12 会和原版
差一整个时钟的位置。终端小到连日期窗都放不下时（例如 80x8），日期窗也留在
`init()` 的位置 —— 同样与原版一致。

### 与 clock-rs 的差异（默认行为不同）

clock-rs（<https://github.com/Oughie/clock-rs>，`src/position.rs` +
`src/clock/mod.rs`）的居中公式其实和 tty-clock 一样：

```rust
Self::Center => (len / 2).saturating_sub(offset),   // 行 offset = HEIGHT/2 = 3，列 offset = clock_width/2
```

但默认值和边界处理不同：

| 项 | tty-clock / zclock | clock-rs |
| --- | --- | --- |
| 是否默认居中 | **否**，默认 `(0,0)` 左上角，要加 `-c` | **是**，`[position] horizontal = "center"`、`vertical = "center"` 是默认配置（没有 `-c` 这种开关，用配置文件/`--horizontal`/`--vertical` 改） |
| 时钟宽度 | 35 / 54 列 | 32 / 51 列（字形间距不同） |
| 放不下时 | `mvwin()` 失败 → 窗口留在原处，`geo` 照旧前进 | `saturating_sub` → 坐标夹到 0；`is_too_large()` 时整帧都不画（`width+1 >= COLS` 或 `height+1 >= LINES`） |
| 日期行 | 单独一个 `len+2` 宽的日期窗，列 = `geo.y + w/2 - len/2 - 1` | 同一个 padding 里推出来：`" ".repeat(half_width - text_len/2)`，比 tty-clock 偏右 1 列 |
| `-x` 边框 | 有，画在时间窗边线上（不改宽度） | 没有边框功能 |
| 垂直定位 | `newwin`/`mvwin` 的行坐标 | `MoveTo(0, padding.top)`，`padding.top = height/2 - 7/2` |

结论：`zclock -c` 与 tty-clock 2 **逐格一致**；clock-rs 只是"默认就居中、宽度
和放不下时的处理不同"，所以 zclock 跟 tty-clock，不跟 clock-rs 的默认值。

## 与原版的差异

### 照抄的"怪癖"（看着奇怪但是原版行为）

- `-b` 给数字块加的是 `A_BLINK`（闪烁）而不是 `A_BOLD`，只有日期行是 `A_BOLD`。
- 方向键下边界判断是 `geo.x <= LINES - h - DATEWINH`，允许越过一格（off-by-one）。
- rebound 第一帧是在移动之后画的，所以 `-r` 起手位置是 `(1,1)` 而不是 `(0,0)`。
- `-C abc` 走 atoi → 0 → 黑色；`-C 9` / `-C 99` 直接忽略。
- `-d 0 -a 0` 是 100% CPU 忙等（原版 `pselect` 零超时），想要高帧率请按 man page 用 `-d 0 -a 100000000`。
- 终端比时钟还窄时（例如 40x12 配 `-s`，54 列 > 40 列）：ncurses 的 `mvwin()`
  拒绝把窗口挪到屏幕外，而 tty-clock 不看返回值，于是窗口留在 `(0,0)` 被裁掉，
  `geo` 却记着 `(3, -7)`；日期窗是另一次 `mvwin()`，它放得下，照常挪到时钟下方。
  zclock 连这个也照抄（`clockMove` / `moveDateWindow`），否则整块时钟会差一格。

### 降级行为（做不到 / 换了实现方式的地方）

| 项 | 原版做法 | zclock | 影响 |
| --- | --- | --- | --- |
| `-T` 判定 | `stat()` + `S_ISCHR` | `open(O_RDWR)` + `TCGETS` | `/dev/null` 这类"字符设备但不是终端"的路径会被拒绝（原版会接受然后画不出去）。真正 tty 的行为一致；打不开时同样 `exit(1)` 并报 `couldn't be opened: <errno>` |
| 终端能力 | ncurses terminfo | 直接发 xterm 系序列 `\e[?1049h/l`、`\e[?25l/h` | 非 xterm 系（少数老终端）可能不认 alternate screen |
| 本地时间 | `localtime()` | 自己解析 TZif | 支持 `/etc/localtime`、`TZ=Asia/Shanghai`、`TZ=:Europe/Berlin`、`TZ=/path`；**不支持** POSIX 规则串（`CET-1CEST,M3.5.0,…`），此时退回 `/etc/localtime`，再不行才 UTC |
| `strftime` | libc 全量 + `LC_TIME` 本地化 | 子集，只有英文名（C locale） | `%A/%B` 永远是英文；`%G/%V/%U/%W` 等未实现，原样输出 `%G` |
| SIGSEGV | `endwin()` 后退出 | 未处理 | 崩溃时终端可能停在 raw 模式（可用 `reset` 恢复） |
| 光标/清屏 | ncurses | 手发 ANSI | 相等 |

### 未实现

- 无（19 个参数全部有实现）。`-h` 之外没有长选项；`--help`/`--version`/`--info`
  是额外接受的等价写法（原版 getopt 会把这几个当非法选项然后打印 usage，效果接近）。

### 非 TTY 降级

stdout 不是终端时**不发一个转义序列**，直接打印一帧纯文本（点阵用 `#` 表示色块），
然后 `exit 0`。这样 `zclock | cat`、CI、沙箱里都不会挂起。

```
$ ./zig-out/bin/zclock

 ###### ######      ###### ######
 ##  ## ##  ##  ##      ## ##
 ##  ## ##  ##      ###### ######
 ##  ## ##  ##  ##      ##     ##
 ###### ######      ###### ######

            2026-11-08
```

交互自测用的调试开关：`ZCLOCK_FORCE_TTY=1` 会把非 tty 的 stdout 当终端处理
（用于没有 pty 的沙箱里验证按键/信号路径）。它不是 tty-clock 的功能，正常使用不需要。

## Zig 0.17 踩坑记录

| 0.17 变化 | 这里的写法 |
| --- | --- |
| `std.fs` 收缩、`std.posix.write` 没了 | 全部走 `std.os.linux.{read,write,ioctl,openat,close,clock_gettime}`，返回值自己解 `-errno`（`term.errnoOf`） |
| `main` 签名 | `pub fn main(init: std.process.Init) !void`，argv 用 `init.minimal.args.iterate()`，env 用 `init.environ_map`，分配器用 `init.arena` |
| `b.args` 没了 | `run_cmd.addPassthruArgs()` |
| `linkLibC` 不适用 | 完全不链 libc；`localtime`/`strftime` 自己实现 |
| `std.time.timestamp()` 删了 | `linux.clock_gettime(.REALTIME, &ts)` |
| `std.Thread.sleep` 不在 | `posix.ppoll(&.{}, &timespec, null)`（顺便得到 ns 精度和原版 pselect 的语义） |
| `std.ArrayList` 是 unmanaged | `.empty` + `append(alloc, x)` |
| `Allocator.dupeZ` 没了 | `alloc.allocSentinel(u8, len, 0)` + `@memcpy` |
| `std.posix.tcgetattr` 对 EBADF `unreachable` | `isTty` 用 `ioctl(TCGETS)` 自己判，不 panic |
| `std.fs` 无 `fstat` | 用 `TCGETS` 代替 `S_ISCHR`（见上表） |

## 自测（本机沙箱实测）

```sh
$ zig build && zig build test
# 29 tests passed

$ ./zig-out/bin/zclock --help | head -3
usage : zclock [-iuvsScbtrahDBxn] [-C [0-7]] [-f format] [-d delay] [-a nsdelay] [-T tty]
    -s            Show seconds
    -S            Screensaver mode (any key quits, unless -n)

$ TERM=xterm-256color timeout 2 ./zig-out/bin/zclock | cat -v | head -c 400

 ###### ######      ###### ######
 ##  ## ##  ##  ##      ## ##
 ##  ## ##  ##      ###### ######
 ##  ## ##  ##  ##      ##     ##
 ###### ######      ###### ######

            2026-11-08
```

交互路径两套验证：

- 没有 pty 时用 `ZCLOCK_FORCE_TTY=1` + 管道，26 项断言全过（alternate screen、
  隐藏/恢复光标、按键、颜色、暂停、`-n`、屏保、SIGINT/SIGTERM 恢复、SIGWINCH
  重排、`-T` 报错）。
- 有 pty 时用 `script -qec "stty rows R cols C; …"` 真跑一遍，把 ANSI 流重放成
  虚拟屏幕再比坐标：`tools/center_diff.py` 在 80x24 / 40x12 / 120x40 上把 `-c`
  与 tty-clock 2（`rustrefs/orig_tty_clock` 里 `make` 出来的）逐格对比，`all equal`。
