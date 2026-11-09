# zpipes

终端管道动画屏保：随机游走的管道在屏幕上生长，撞墙或撞到别的管道后重生，
直到占满屏幕再清屏重来。用法行和帮助正文照 `pipes.sh` 的 usage 写，
选项集合对应 `pipes-rs` 的配置项。

## 构建

```sh
zig build
zig build test
./zig-out/bin/zpipes --help
```

## 常用示例

```sh
./zig-out/bin/zpipes
./zig-out/bin/zpipes --fps 30 -c 2,4,6
./zig-out/bin/zpipes -p 256 --theme matrix -k heavy,knobby,dots -n 4
./zig-out/bin/zpipes --color-mode rgb --rainbow 5 --theme pastel -B
./zig-out/bin/zpipes -d 16 -i --max-total-length 120
```

按 `q`、`Esc` 或 `Ctrl-C` 退出，按 `r` 清屏重开。

## 选项

| 选项 | 说明 |
|---|---|
| `-n, --pipe-count N` | 同时存在的管道数（D=1） |
| `-k, --kind LIST` | 管道种类 `heavy,light,curved,double,blocks,knobby,dots`（D=heavy），可重复 |
| `-c, --color COLS` | 逗号分隔的 256 色号 1-255（ansi only），可重复 |
| `-p, --palette MODE` | ANSI 调色板 `8` / `16` / `88` / `256`（D=8） |
| `-B, --bold` | 粗体管道字符（pipes.sh 的 `-B` 相反：无粗体） |
| `-C, --no-color` | 无颜色，等价于 `--color-mode none` |
| `-f, --fps N` | 帧率，0 = 不限速（D=50） |
| `-s, --speed N` | 每个生长步移动格数（D=1） |
| `-r, --reset P` | 屏幕占用率达到该比例就重置，0.1-1.0（D=0.5） |
| `-t, --turn P` | 每步转向概率 0.0-1.0（D=0.15） |
| `-i, --inherit-style` | 重生时继承上一条管道的 kind/color |
| `-h, --help` | 打印帮助（stdout，`exit 0`） |
| `-v, --version` | 打印版本（stdout，`exit 0`） |

扩展选项（`pipes.sh` 没有的部分）：

| 选项 | 说明 |
|---|---|
| `--color-mode MODE` | `ansi`（D）/ `rgb`（真彩色）/ `none` |
| `--theme NAME` | `default`（D）/ `darker` / `pastel` / `matrix` |
| `--rainbow DEG` | RGB 模式下每步旋转色相 0-255 度 |
| `-d, --delay MS` | 每帧延迟毫秒，0 不限速；与 `--fps` 互斥 |
| `--cpf N` | 每帧生长步数（D=1） |
| `--max-length N` | 单条管道最大格数，0 不限（D=0） |
| `--max-total-length N` | 所有存活管道合计最大格数，超出时回收最老的管道（D=0） |
| `--license` | 打印 MIT 许可证全文 |

`--speed` 与 `--cpf` 相乘得到每帧实际生长格数。

## 主题取色范围

| 主题 | ANSI | RGB |
|---|---|---|
| `default` | 完整调色板 | 明亮：S 55-100%，V 75-100% |
| `darker` | 8:1-6，16:1-7，88:16-31，256:16-51 | V 30-60% |
| `pastel` | 16:9-15，88:64-79，256:153-231 | S 25-55%，V 85-100% |
| `matrix` | 绿色系：22,28,34,40,46,82,118,154,190,226（256 色） | 色相 100-140°，V 45-100% |

## 配置文件

路径：`~/.config/<argv0>/config.toml`（如果设置了 `XDG_CONFIG_HOME`，则用
`$XDG_CONFIG_HOME/<argv0>/config.toml`）。例如二进制叫 `zpipes` 时就是
`~/.config/zpipes/config.toml`。

只支持最小的 TOML 子集：`key = value`、`#` 注释；`[section]` 行会被忽略，
不支持数组和嵌套表。键名与命令行长选项一一对应（下划线/连字符均可）。
命令行参数优先于配置文件。非法值会报出文件与行号。

带注释的示例：

```toml
# ~/.config/zpipes/config.toml
# 命令行参数会覆盖这里的值。

color_mode = "ansi"      # ansi | rgb | none
theme = "default"        # default | darker | pastel | matrix
palette = 256            # 8 | 16 | 88 | 256
color = "2,4,6"          # 显式 256 色号（ansi 模式；逗号分隔）
rainbow = 0              # 0-255，仅 rgb 模式
bold = false             # 粗体
inherit_style = false    # 撞边/相撞后继承 kind/color

fps = 50                 # 与 delay 互斥；0 = 不限速
# delay = 20             # 毫秒；与 fps 互斥；0 = 不限速

speed = 1                # 每个生长步移动格数
cpf = 1                  # 每帧生长步数
pipe_count = 1           # 同时存在的管道数
max_length = 0           # 单条管道最大格数，0 = 不限
max_total_length = 0     # 所有存活管道合计上限，0 = 不限
turn = 0.15              # 0.0-1.0
reset = 0.5              # 0.1-1.0

# 管道种类，逗号分隔
kind = "heavy"           # 逗号分隔；默认只有 heavy
```

## 未实现 / 差异

- 未实现 `pipes-rs` 的 `emoji`、`sus` 管道种类（`outline` 已实现，是 `double` 的别名）。
- 默认值对齐 `pipes-rs`：`kind=heavy`（单一种类，pipes.sh 的 `-t 0`）、`fps=50`、
  `turn=0.15`、`reset=0.5`。之前默认把 7 种管道全打开，直接跑 `zpipes` 会同时出现
  粗线、细线、圆角、双线、半方块、锯齿和圆点，看起来像"各种形态的线条"。
- TOML 只解析扁平 `key = value`，忽略 section，不支持数组/嵌套表。
- `-c` 在非 ansi 模式下被忽略；`--rainbow` 在非 rgb 模式下被忽略。
- `--max-total-length` 统计存活管道格数，不擦除已经留下的旧轨迹。
- 布尔选项是开关，不接受 `true/false` 值。

### 和 pipes.sh 的选项对照

| pipes.sh | zpipes | 说明 |
| --- | --- | --- |
| `-p [1-]` 管道数 | `-n` / `--pipe-count` | 短选项被调色板占用 |
| `-t [0-9]` 管道类型 | `-k` / `--kind` | 短选项被转向概率占用 |
| `-c` 颜色 | `-c` / `--color` | 一致，但这里是逗号分隔的 256 色号 |
| `-f` framerate（D=75） | `-f` / `--fps`（D=20） | 默认值不同，0 = 不限速 |
| `-s` 直行概率 | `-s` / `--speed` | 语义不同：这里是每步格数 |
| `-r` 重置字符数 | `-r` / `--reset` | 语义不同：这里是占用率阈值 |
| `-R` 随机起点 | 未实现 | 起点与初始方向固定 |
| `-B` 无粗体 | `-B` / `--bold` | 语义相反 |
| `-C` 无颜色 | `-C` / `--no-color` | 一致 |
| `-K` 跨边界保留颜色/类型 | `-i` / `--inherit-style` | 只在管道重生时继承 |
| `-h` / `-v` | `-h` / `-v` | 一致：stdout，`exit 0` |

非法参数：pipes.sh 打错误后 `exit 1`，zpipes 同样是 `exit 1`。

许可证：MIT，见 `LICENSE`；也可运行 `./zig-out/bin/zpipes --license` 查看。
