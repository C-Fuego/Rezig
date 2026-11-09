# 终端玩具 Rust 参考实现功能盘点

> 盘点日期：2026-11-08
> 用途：给 Zig 重写 lolcat / cmatrix / cbonsai / pipes.sh / tty-clock 做功能对照。
> 参考仓库 clone 在 `rustrefs/`（只读，未修改）。所有参数、默认值都来自实际源码（clap/lexopt 定义、README、man page），不是凭印象。

## 0. 总览

| 工具 | 采用的 Rust 参考 | Stars | 最后提交 | 完成度 / 定位 |
| --- | --- | ---: | --- | --- |
| lolcat | [ur0/lolcat](https://github.com/ur0/lolcat) | 112 | 2024-02-06 | 最接近“命令行 lolcat”的完整移植；ANSI 透传、256/真彩、bg/dialup |
| lolcat（进阶） | [mazznoer/lolcrab](https://github.com/mazznoer/lolcrab) | 173 | 2025-12-22 | lcat-rs 分支；噪声渐变、14 组调色板、CSS 渐变、动画、配置文件 |
| lolcat（最小） | [kaan-escober/lolcat-rs](https://github.com/kaan-escober/lolcat-rs) | 3 | 2026-01-01 | 约 200 行，只有 `-f/-s`，真彩输出，适合当公式参考 |
| cbonsai | [roberte777/rbonsai](https://github.com/roberte777/rbonsai) | 34 | 2025-03-31 | 主参考；crossterm 重写，live/infinite/screensaver/print 都有，缺原版一半参数 |
| cbonsai（扩展） | [Mrpalland/rbonsai-extended](https://github.com/Mrpalland/rbonsai-extended) | 0 | 2025-11-03 | `src/` 与 rbonsai 逐文件相同（diff 无差异），没有实际新功能 |
| cmatrix | [Fierthraix/rmatrix](https://github.com/Fierthraix/rmatrix) | 67 | 2026-06-25 | 明确自称 cmatrix 移植；参数/按键结构最贴近原版，但只有 ASCII 字符 |
| cmatrix（现代） | [Tripstack-Corp/rmatrix](https://github.com/Tripstack-Corp/rmatrix) | 20 | 2026-10-19 | 24 位渐隐、8 套字符、真彩/256/16 回退、damage tracking、seed 回放 |
| pipes.sh | [lhvy/pipes-rs](https://github.com/lhvy/pipes-rs) | 450 | 2025-08-21 | 功能最全；TOML 配置 + 9 种管道 + OKLCH 调色 |
| tty-clock | [lukeMains/tty-clock-rs](https://github.com/lukeMains/tty-clock-rs) | 2 | 2022-07-24 | 极不完整：只有 `-h` 实现，其余参数全是 TODO |
| tty-clock（进阶） | [ckaznable/tenki](https://github.com/ckaznable/tenki) | 170 | 2026-07-23 | tty-clock + 天气效果，ratatui；参数/交互与原版差异大 |
| tty-clock（配置化） | [maachue/ametokei](https://github.com/maachue/ametokei) | 1 | 2026-07-10 | tenki 分支；配置文件、自定义字体、12h/UTC/日期格式齐全 |

原版对照仓库（同时 clone 了，只读）：

- lolcat：<https://github.com/busyloop/lolcat>（Ruby，2021-12-03）
- cmatrix：<https://github.com/abishekvashok/cmatrix>（C，2023-12-09）
- cbonsai：<https://gitlab.com/jallbrit/cbonsai>（C，2026-10-25；GitHub 上 `jallbrit/cbonsai` 已 404，改用 GitLab 官方仓库）
- pipes.sh：<https://github.com/pipeseroni/pipes.sh>（Bash，2018-04-22）
- tty-clock：<https://github.com/xorg62/tty-clock>（C，2021-11-21）

> 注：任务里提到的 `jmcclell/lolcat_rust` 经 GitHub API 确认已不存在（404）。`ur0/lolcat` 的 crate 名就是 `lolcat`，CLI 参数（`-s/--seed`、`-S/--spread`、`-f/--frequency`、`-B/--bg`、`-D/--dialup`）与早期 `lolcat_rust` 一脉相承，故作为 lolcat 主参考。

---

## 1. lolcat

### 1.1 主参考：ur0/lolcat

- 仓库：<https://github.com/ur0/lolcat>
- 最后提交：2024-02-06（`abcaac0`），版本 1.5.2
- 依赖：clap 2.x、rand、utf8-chars、termsize；纯 stdout 流式输出，无 TUI 全屏

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-s, --seed <N>` | 随机种子 | `0` | 源码中 `seed == 0` 时随机成 `rand()*10e9`，即 0 表示自动 |
| `-S, --spread <F>` | 彩条倾斜/展开程度 | `3.0` | 原版 lolcat 用 `-p/--spread` |
| `-f, --frequency <F>` | 彩虹频率 | `0.1` | 原版用 `-F/--freq`，短选项正好相反，迁移时建议只认长选项 |
| `-B, --bg` | 背景彩虹模式 | `false` | 前景按背景灰度自动取黑/白（阈值 `0xA0`）；行首空白不着色 |
| `-D, --dialup` | 拨号模式：每行结束随机停顿 | `false` | 每行 `30..700ms` 随机 sleep，模拟慢速终端 |
| `-F, --force-color` | 非 tty 也输出颜色 | `false` | 否则 stdout 非终端时原样输出（等于 cat） |
| `--terminal-width <N>` | 自定义折行宽度 | 终端列数；取不到时 `65535` | 传 `0` 有实现 bug（内部 +1 后每个字符都换行），Zig 复刻建议把 0 解释为“不折行” |
| `<file>`（位置参数，短选项 `-i`） | 输入文件 | stdin | long 名写成 `"--input file name"`（带空格），实际 `--input` 不可用；只记位置参数即可 |
| `-h, --help` | 帮助 | — | 帮助文本本身用彩虹渲染 |
| `-V, --version` | 版本 | — | 同样彩虹渲染 |

#### 交互行为

- 无按键/鼠标处理，纯过滤器；Ctrl-C 由终端默认信号终止。
- 支持 `--help` / `--version`，且两者输出都经过 lolcat 着色（这是很有意思的小亮点）。
- 只接受一个文件参数；多个文件需要自己循环调用。
- 非 tty 默认不加色；`-F` 强制。

#### 渲染细节

- 按 **Unicode 字符**（`utf8-chars`）而非字节处理，CJK 宽字符按 1 列计（折行会偏）。
- 颜色公式（每字符）：

$$i = \frac{frequency \times seed}{spread},\quad
R=\sin(i)\cdot127+128,\;
G=\sin(i+\tfrac{2\pi}{3})\cdot127+128,\;
B=\sin(i+\tfrac{4\pi}{3})\cdot127+128$$

- `seed` 每输出一个字符 +1；换行时 `seed` 回到“行首 seed + 1”，因此整体呈斜向彩虹。
- 真彩检测：只看 `COLORTERM == "truecolor" | "24bit"`；是则 `\x1b[38;2;r;g;bm`，否则手工量化到 256 色 `\x1b[38;5;Nm`（6×6×6 色立方）。
- 遇到 ANSI 转义序列（CSI、nF 等）原样透传，不参与着色，避免破坏已有颜色/光标控制。
- 折行：达到 `terminal_width+1` 时自动换行并重置行首 seed；换行时若 bg 模式发 `\x1b[49m` 清背景。
- bg 模式：前景黑/白由背景灰度（sRGB→linear→灰阶→sRGB）决定；每行第一个非空白字符前不着色。
- 结束时发 `\x1b[39m` 复位前景色。

#### 相对原版（busyloop/lolcat）缺什么

原版基线：`-p/--spread 3.0`、`-F/--freq 0.1`、`-S/--seed 0`、`-a/--animate`、`-d/--duration 12`、`-s/--speed 20`、`-i/--invert`、`-t/--truecolor`、`-f/--force`、`-v`、`-h`。

| 缺失 | 说明 |
| --- | --- |
| `--animate` / `--duration` / `--speed` | 原版逐行“淡入/推进”动画；ur0 完全没有 |
| `--invert` | 原版前后景反转；ur0 只有 `--bg`（背景彩虹，前景自动黑白） |
| `--truecolor` 显式开关 | ur0 只靠 `COLORTERM` 自动判断，不能强制 |
| `--force` 的短选项 `-f` | 被 `--frequency` 占用，ur0 只能用 `-F` |
| 多文件参数 | 原版 `lolcat file1 file2`；ur0 只取一个 |
| `-v` 短版本号 | ur0 用 `-V` |

反过来，ur0 **多了**：`--bg`、`--dialup`、`--terminal-width`、ANSI 透传、256 色回退、彩虹 help。

#### 值得复刻的亮点

1. ANSI 转义序列透传（很多复刻会直接踩坏 `ls --color`、`git log` 的输出）。
2. 256 色回退 + `COLORTERM` 真彩检测，兼容性成本低。
3. bg 模式用灰度阈值自动选黑/白前景，代码短、效果好。
4. `--dialup` 这种“没用但好玩”的彩蛋，符合玩具定位。
5. 彩虹 help/version，成本极低、观感好。

---

### 1.2 进阶参考：mazznoer/lolcrab

- 仓库：<https://github.com/mazznoer/lolcrab>
- 最后提交：2025-12-22（`abd629e`），版本 0.4.x
- 定位：`lcat-rs` 的分支，“像 lolcat 但用噪声（OpenSimplex）+ 更多颜色”
- 配置文件：`$XDG_CONFIG_HOME/lolcrab/config`（每行一个 flag，如 `--linear` / `--gradient fruits` / `--spread 15`）

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `[File]...` | 输入文件，`-` 表示 stdin | `-` | 支持多文件依次输出 |
| `-g, --gradient <NAME>` | 预设渐变 | `rainbow` | 源码共 15 个值：cividis、cool、cubehelix、fruits、inferno、lolcat、magma、plasma、rainbow、rd-yl-gn、sinebow、spectral、turbo、viridis、warm（README 漏列 `lolcat`） |
| `--presets` | 列出所有预设渐变 | — | 直接退出 |
| `-c, --custom <CSS>` | 自定义 CSS 渐变 | — | 如 `linear-gradient(...)`，交给 colorgrad 解析 |
| `--sharp <N>` | 让渐变分段“锐利” | 不启用 | 0–255 的档数 |
| `-s, --scale <F>` | 噪声尺度 | `0.034` | 建议 0.01–0.2，越小色块越大 |
| `-S, --seed <N>` | 噪声种子 | 随机 | u64 |
| `-i, --invert` | 背景着色（前后景反转） | `false` | 对应 lolcat 的 `--invert` |
| `-r, --random-colors <N>` | 随机 N 个颜色当自定义渐变 | 不启用 | 源码限制 `1..=15`（README 写 1..100，不一致） |
| `-L, --lolcat` | 兼容模式：等价 `--linear --gradient lolcat` | `false` | 想对齐 lolcat 观感时用这个 |
| `-a, --animate` | 动画模式 | `false` | 文字横向滚过渐变，不是逐行淡入 |
| `-d, --duration <N>` | 动画时长（步数） | `5` | 源码 clamp 到 1–30 |
| `--speed <N>` | 动画帧间隔 | `150ms` | 源码 clamp 到 30–200ms |
| `-l, --linear` | 线性渐变模式 | `false` | 与噪声模式二选一 |
| `-A, --angle <DEG>` | 线性渐变角度 | 随机 | 0–360；指定后自动开 linear |
| `--spread <F>` | 线性渐变跨度 | `13` | 0–100 |
| `--offset <F>` | 渐变偏移 | 随机 | 0–1 |
| `--config-file` | 打印配置文件路径 | — | 不进入渲染 |
| `-h, --help` / `-V, --version` | 帮助/版本 | — | 手写 flag（未用 clap 默认） |

#### 交互 / 渲染

- 同样是无交互过滤器；Ctrl-C 退出。
- 输出 24 位真彩（colorgrad + fastrand + noise），没有 256 色回退，也没有 `--force`。
- 颜色来自二维噪声场采样，不是正弦公式；因此色块是有机形状，不是斜条纹。
- 动画模式：`x = -(duration-1) * text_len` 起步，逐帧右移，每帧 sleep `speed`。
- 支持作为库使用（`Lolcrab::new`、`colorize_str`、`set_invert`、`randomize_position`、`reset_position`）。

#### 相对原版缺什么 / 多什么

- 缺：`--spread/--freq` 的正弦模型（被噪声/线性模式替代）、`--force`、`--truecolor` 开关、逐字符 dialup。
- 多：15 组渐变、CSS 自定义渐变、噪声尺度、随机配色、线性角度/偏移/跨度、横向滚动动画、配置文件、多文件、库 API。

#### 值得复刻的亮点

- `--lolcat` 这个“兼容档位”很聪明：一套二进制同时提供原味和花哨两种观感。
- 预设渐变表（viridis/turbo/…）可以直接抄成 RGB 控制点数组。
- 配置文件“每行一个命令行参数”的实现极简，Zig 里也好做。

---

### 1.3 最小实现：kaan-escober/lolcat-rs

- 仓库：<https://github.com/kaan-escober/lolcat-rs>
- 最后提交：2026-01-01（`fb87160`）

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-f, --freq <F>` | 彩虹频率 | `0.1` | 与 ur0 一致 |
| `-s, --spread <F>` | 彩虹展开 | `2.6` | 与 ur0 的 3.0 不同 |
| `[FILES]...` | 输入文件，`-` 为 stdin | `-` | 支持多文件 |
| `-h, --help` | 手写帮助 | — | 没有 `-V` |

实现要点：

- 始终 24 位真彩，无 256 回退、无 `--force`、非 tty 也会染色。
- 颜色：`i = seed + line_idx + char_idx/spread`，再套正弦；振幅用 150 而不是 127（“饱和度增强”）。
- seed 由 `nanos ^ pid` 再 SplitMix64 混合后 `% 256`。
- 自述“binary safe / 非法 UTF-8 也能像 cat 一样过”，但主循环按 `char` 处理，实际需看 `process.rs`；Zig 复刻建议直接按字节流 + UTF-8 解码错误回退。

价值：公式和参数命名最干净，适合当“最小可运行版”；功能上不要以它为准。

---

### 1.4 lolcat 复刻建议

必须：

- stdin/文件流式处理、UTF-8 解码、ANSI 透传。
- `seed` / `spread` / `frequency` 三参数 + 正弦公式。
- 真彩 + 256 色回退、`--force-color`。
- `--help` / `--version`。

建议做：

- `--bg`（背景彩虹 + 自动黑白前景），实现约 30 行。
- `--terminal-width` 折行。
- `--animate/--duration/--speed`（原版核心玩法之一，逐行推进）。
- `--invert`。

可以砍：

- `--dialup`（彩蛋，非核心）。
- 噪声渐变、CSS 渐变、预设调色板、配置文件（lolcrab 路线，和“复刻 lolcat”不是一个目标）。

---

## 2. cbonsai

### 2.1 主参考：roberte777/rbonsai

- 仓库：<https://github.com/roberte777/rbonsai>
- 最后提交：2025-03-31（`368d0a2`），v0.1.5
- 依赖：clap 4（derive）、crossterm 0.27、rand 0.8；GPL-3.0-or-later
- 结构：`Config`（clap）在 `src/lib.rs`，生长算法在 `src/bonsai/mod.rs`，底座画在 `src/base.rs`，消息框/按键在 `src/bonsai/utility.rs`

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-l, --live` | 逐步生长（每步停顿） | `false` | 每画一个节点 sleep `time` |
| `-t, --time <SEC>` | live 模式每步停顿 | `0.03` | f64 秒 |
| `-i, --infinite` | 无限循环长树 | `false` | 一棵结束等 `wait` 再长下一棵 |
| `-w, --wait <SEC>` | infinite 模式两棵树之间等待 | `4.0` | 等待期间按键可退出 |
| `-S, --screensaver` | 屏保模式：等价 `-li`，任意键退出 | `false` | 不保存/加载进度（原版会） |
| `-m, --message <STR>` | 树旁消息框 | 无 | 画在终端约 70% 位置，带 `+ - |` 边框、按词换行 |
| `-b, --base <N>` | 底座样式 | `1` | 只实现了 1 和 2；其它值不画底座，也没有 0=无 |
| `-M, --multiplier <N>` | 分枝倍率 | `3` | 帮助写“higher -> less branches”，原版帮助写“higher -> more branching”，默认值也从 5 变 3；实际观感需在 Zig 版重新调参 |
| `-L, --life <N>` | 初始生命（越大树越大） | `32` | i32，无范围校验 |
| `-p, --print` | 结束后把最终树打印到终端 | `false` | 退出 alternate screen 后重画一次，光标回底部 |
| `-s, --seed <N>` | 随机种子 | 无（取 Unix 秒） | u64，可复现 |
| `-v, --verbose` | 调试输出 | `false` | 显示 maxX/maxY、life、shoots、dx/dy、branch type |
| `-h, --help` / `-V, --version` | 帮助/版本 | — | clap 自动 |

#### 交互行为

- 启动即 `enable_raw_mode` + 隐藏光标 + `EnterAlternateScreen`，退出恢复。
- `-S` 强制 `live = true, infinite = true`；任意按键（KeyEventKind::Press）退出。
- 非 infinite 且非 print：画完后阻塞等待任意按键再退出。
- infinite：每棵树之间等待 `wait`，期间按键退出。
- live：每画一个节点 sleep `time`，期间检测按键，可中断。
- 无鼠标处理；Ctrl-C 在 raw mode 下也表现为按键事件，因此同样会退出。
- 无显式 `q` 键，任意键即可。

#### 渲染细节

- 字符：树干/枝条用 `/~\|_` 组合；叶子固定 `&`（源码里留了 `conf.leaves` 的注释但未实现）。
- 颜色（256 色 ANSI）：枝干 3（绿）或 11（亮黄）随机 + 偶尔 Bold；枯枝 2；死枝 10；底座 8/2/11。
- 底座 1 是 31 列、4 行的 `:____./~~~\.____:` 花盆；底座 2 是 15 列的三行小盆。
- 树的可用高度：base=1 时 `rows-5`，base=2 时 `rows-4`，其它 `rows`。
- 生长算法：Trunk / ShootLeft / ShootRight / Dying / Dead 五种 BranchType；按 age、life、multiplier 用加权随机决定 `dx/dy`；`life < 3` 变 Dead，`life < 4` 强制 `&`。
- 整棵树先算进 `Vec<Val>`，再按顺序绘制；`print` 模式复用这份 Vec 重画。
- 消息框：宽 25% 终端、按词换行；边框用 `+ - |`；位置在 `(0.7*cols, 0.7*rows)` 附近。

#### 相对原版（cbonsai）缺什么

原版基线：`-l/--live`、`-t/--time 0.03`、`-i/--infinite`、`-w/--wait 4.00`、`-S/--screensaver`、`-m/--message`、`-T/--text-origin ROW,COL`、`-b/--base INT`（0=无）、`-g/--geometry ROW,COL`、`-c/--leaf LIST`、`-k/--color LIST`（4 个 0–255 索引，默认 `2,3,10,11`）、`-M/--multiplier INT`（默认 5，0–20）、`-L/--life INT`（0–200，默认 32）、`-p/--print`、`-s/--seed`、`-W/--save FILE`、`-C/--load FILE`、`-v`、`-h`、`-V`。

| 缺失 | 影响 |
| --- | --- |
| `-c/--leaf LIST` | 叶子固定 `&`，不能自定义（很显眼的可玩性缺失） |
| `-k/--color LIST` | 颜色写死 2/3/10/11，不能改 |
| `-T/--text-origin` | 不能把 stdin 文本放到指定行列 |
| `-g/--geometry` | 底座不能任意定位 |
| `-b 0` 与 base 3+ | 只有 1/2；原版 0=无底座 |
| `-W/--save`、`-C/--load` | 不能保存/续长树；屏保模式也不会缓存进度 |
| `-M` 默认值/语义 | 原版默认 5、帮助称越大分枝越多；rbonsai 默认 3，且 `shoot_cooldown = multiplier`，越大冷却越久，帮助改称“分枝越少” |
| `-L` 范围 | 原版限制 0–200；rbonsai 不校验 |

反过来 rbonsai 多了：crossterm 跨平台（不依赖 ncurses）、`print` 模式复用已生成树、更清晰的 Config 结构。

#### 值得复刻的亮点

1. “先算完整棵树到数组，再统一绘制”——live 与 print 共用同一份数据，逻辑干净。
2. `-S` = `-li` + 任意键退出，组合语义清晰。
3. 消息框的按词换行 + 相对定位，适合终端尺寸变化。
4. `-v` 直接把生长参数画在角落，调试生长算法非常方便。
5. seed 默认取 Unix 秒，命令行可复现。

### 2.2 rbonsai-extended

- 仓库：<https://github.com/Mrpalland/rbonsai-extended>
- 最后提交：2025-11-03
- 结论：`src/` 与 rbonsai **逐文件相同**（`diff -rq` 无输出），只是 README/发布分支不同；不要指望它补了 leaf/color/save。

### 2.3 cbonsai 复刻建议

必须：

- 五种 BranchType 的生长/分枝/死亡逻辑，`life`、`multiplier`、`seed`。
- `live` / `infinite` / `screensaver` / `print` 四种模式。
- 底座 1/2、消息框、256 色 ANSI 配色。

建议补：

- `-c` 叶子字符列表、`-k` 四色列表（原版有、Rust 版缺，Zig 版做了就是超集）。
- `-b 0` 无底座。
- 屏保模式保存/加载 `~/.cache/cbonsai`（原版特色）。

可以砍：

- `-T/--text-origin`、`-g/--geometry`（使用频率低）。
- base 3+ 的多套 ASCII 盆（原版本身也只有 1/2 两套图形）。

---

## 3. cmatrix

### 3.1 主参考：Fierthraix/rmatrix

- 仓库：<https://github.com/Fierthraix/rmatrix>
- 最后提交：2026-06-25（`c5b9c42`），crate 名 `r-matrix`
- 依赖：clap 4、crossterm、rand、signal-hook；无 ncurses

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-b` | 粗体字符，可重复计数 | `0` | **实现了参数但绘制时完全没用到**（no-op） |
| `-l, --console` | Linux 控制台字体模式 | `false` | 解析后未使用（no-op） |
| `-o, --oldstyle` | 旧式整列下移滚动 | `false` | 唯一真正影响绘制的兼容开关 |
| `-s, --screensaver` | 屏保模式，任意键退出 | `false` | 有效 |
| `-x, --xwindow` | X11 位图字体模式 | `false` | no-op |
| `-u, --update <0-10>` | 刷新延迟，单位 10ms | `4`（=40ms，约 25fps） | `0` 表示不 sleep，忙等满速 |
| `-C, --colour <NAME>` | 颜色 | `green` | 只接受 green/red/blue/white/yellow/cyan/magenta/black，不接受数字 |
| `-r, --rainbow` | 彩虹模式 | `false` | 每个新头随机 6 色之一 |
| `-h, --help` / `-V, --version` | 帮助/版本 | — | clap 自动 |

#### 交互行为

| 按键 | 行为 |
| --- | --- |
| `q` | 退出（屏保模式下任意键退出） |
| `Ctrl-C` | crossterm 捕获后退出（同时注册 SIGINT） |
| `1`–`9`, `0` | 设置 update 延迟（`0` 满速） |
| `!` `@` `#` `$` `%` `^` `&` | 红/绿/黄/蓝/洋红/青/白（即 Shift+1..7） |
| `r` | 彩虹 |
| `b` / `B` / `n` | 粗体=1/2/0 —— 但绘制未使用，实际无效 |
| `p` / `P` | 暂停 —— 只在 config 里翻转，主循环未使用，实际无效 |

- 信号：`SIGINT/SIGTERM/SIGQUIT` 退出；`SIGWINCH` 重建 Matrix；同时处理 crossterm 的 `Event::Resize`。

#### 渲染细节

- 字符集：**可打印 ASCII 33..126**（93 个），没有原版的半角片假名，也没有 `-c`。
- 每列 `VecDeque<Block>`；头部白色 `white=true`，拖尾用矩阵色；`oldstyle` 时整列下移、空位补空格。
- 颜色只有 8 种 ANSI（`Color::Green` 等），没有 256/真彩。
- 帧率靠 `sleep(update*10 ms)` 固定节拍，不做时间补偿。
- 全屏重绘，无 damage tracking。
- 屏保模式任意按键/鼠标？源码只匹配 Key 事件，鼠标事件被忽略。

#### 相对原版（cmatrix）缺什么

原版基线：`-a` 异步滚动、`-b` 粗体、`-B` 全粗体、`-c` 日文字符、`-f` 强制 linux TERM、`-l` linux 模式、`-L` 锁定模式、`-o` 旧式滚动、`-h`、`-n` 无粗体、`-s` 屏保、`-x` X 模式、`-V`、`-M 消息`、`-u 延迟 0-10`、`-C 颜色`、`-r` 彩虹、`-m` lambda 模式、`-k` 滚动时变字、`-t tty`。

| 缺失 | 影响 |
| --- | --- |
| `-c` 片假名 | 最明显的“Matrix 味”没有；Rust 版全是 ASCII |
| `-a` 异步滚动 | 所有列同步推进，观感更机械 |
| `-B` 全粗体 / `-n` | 只有 no-op 的 `-b` |
| `-M` 居中消息、`-L` 锁定 | 没有 |
| `-m` lambda 模式、`-k` 变字 | 没有 |
| `-t tty`、`-f` | 没有（crossterm 也不需要） |

#### 值得复刻的亮点

- `SIGWINCH` + `Event::Resize` 双保险重建，resize 不崩（原版 C 的痛点）。
- `oldstyle` 与默认两种滚动都保留，便于对照。
- 按键映射与原版几乎一一对应，迁移成本低。

---

### 3.2 现代参考：Tripstack-Corp/rmatrix

- 仓库：<https://github.com/Tripstack-Corp/rmatrix>
- 最后提交：2026-10-19（`227b59d`），crate 名 `rmatrix-reloaded`
- 定位：不是逐参数移植，而是“现代终端能力”版 cmatrix

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-C, --color <COLOR>` | 颜色：颜色名 / `#RRGGBB` / `rainbow` / `terminal` | `green` | `terminal` 会 OSC 4 查询终端调色板，每列分配一个色 |
| `-c, --charset <SET>` | 字符集：classic/katakana/ascii/alnum/binary/hex/greek/symbols/custom | `classic` | classic = 半角片假名 U+FF66–FF9D + 数字 |
| `--custom <GLYPHS>` | `--charset custom` 的自定义字 | `""` | 会校验每个字刚好占 1 列（拒绝宽字符/组合字符） |
| `-S, --speed <MUL>` | 速度倍率，<1 慢放 | `1.0` | 按“行/秒”对真实时间积分，不是固定 tick |
| `-d, --density <0..1>` | 同时下雨的列比例 | `0.55` | |
| `-m, --mutate <RATE>` | 字符变化率（屏/秒），0 关闭 | `0.35` | |
| `--tail-min <ROWS>` | 最短拖尾 | `6` | 必须 >0 |
| `--tail-max <ROWS>` | 最长拖尾 | `26` | 必须 ≥ tail-min |
| `--fps <N>` | 帧率上限 | `30` | 输出量近似线性，但作者说这是“弱杠杆” |
| `--levels <N\|auto>` | 拖尾亮度档数；`0` 关闭量化 | `auto` | auto = `1500/√(cells)`，clamp 6..24，resize 重算 |
| `--stats` | 启动即显示统计浮层 | `false` | 运行时 `f` 切换 |
| `-b, --bold` | 粗体 | `false` | |
| `-s, --screensaver` | 任意键/鼠标退出 | `false` | |
| `--seed <N>` | 复现同一场雨 | 无 | |
| `--color-depth <D>` | auto / truecolor / 256 / 16 | `auto` | 自动回退 |
| `--sync-io`（隐藏） | 同步写终端（A/B 测试用） | `false` | 不对外宣传 |
| `--bench`、`--bench-warmup`、`--max-step`（隐藏） | 性能测试 | — | |

#### 交互行为

| 按键 | 行为 |
| --- | --- |
| `q` / `Esc` / `Ctrl-C` | 退出 |
| `space` | 暂停 |
| `1`–`9` | 速度倍率（`3` = 1.0×，`1` = 1/3×，`9` = 3×） |
| `r` | 彩虹开关 |
| `c` | 循环字符集（classic→katakana→ascii→alnum→binary→greek） |
| `b` | 粗体开关 |
| `f` | 统计浮层（帧率、速度、每帧字节数、重绘比例，同时写窗口标题） |

#### 渲染细节

- 默认半角片假名 + 数字；ASCII 集特意选 0x21–0x7A，方便配 Matrix Code NFI 字体。
- 24 位亮度渐变，按 `levels` 量化；`auto` 随窗口大小调档，窗口越大档越少（输出越省）。
- Damage tracking：未变化的帧输出 0 字节；光标用相对移动。
- 写终端在独立线程，慢终端只掉帧、不拖慢模拟。
- 颜色深度自动检测 truecolor/256/16；`#RRGGBB`、rainbow、terminal 调色板四种来源。
- 速度按真实时间积分 + `max_step` 钳制，掉帧/挂起后不会瞬移。
- seed 可完整复现动画。

#### 相对原版缺什么 / 多什么

- 缺：`-u` 数字延迟语义（改成 speed 倍率）、`-a` 异步开关、`-M` 消息、`-L` 锁定、`-m` lambda、`-t tty`、`-n/-B/-b` 三档粗体。
- 多：24 位渐隐、8 套字符集、自定义字、真彩/256/16 回退、终端调色板查询、density/tail/mutate、seed、stats、damage tracking、异步写入。

#### 值得复刻的亮点（挑成本低的）

1. `--levels auto` 的 `1500/√cells` 经验公式：代码几行，直接解决“大窗口输出爆炸”。
2. 真彩 → 256 → 16 的三级回退。
3. seed 复现。
4. `--charset classic/katakana/ascii/binary/hex` 这套字符集，比原版 `-c` 更实用。
5. 统计浮层（至少显示 fps）对调试渲染很有帮助。

---

### 3.3 cmatrix 复刻建议

必须：

- 列式雨滴、白头部 + 拖尾、`-u 0-10` 延迟、8 色、`-s` 屏保、`q` 退出、`0-9` 调速、`!@#$%^&` 换色、`r` 彩虹、`p` 暂停、窗口 resize。
- **半角片假名**（原版 `-c` 的灵魂）；至少提供 ASCII 回退。

建议做：

- `-a` 异步滚动（原版默认行为之一）。
- `-o` 旧式滚动。
- `-b/-B/-n` 三档粗体（Rust 参考里是坏的，别照抄）。

可以砍：

- `-L` 锁定、`-m` lambda、`-k` 变字、`-t tty`、`-f`。
- 24 位渐隐/damage tracking（除非目标是现代版观感）。

---

## 4. pipes.sh

### 4.1 参考：lhvy/pipes-rs

- 仓库：<https://github.com/lhvy/pipes-rs>
- 最后提交：2025-08-21（`0183e47`）
- 结构：workspace 四 crate：`pipes-rs`（CLI/循环）、`model`（pipe/kind/color）、`rng`、`terminal`
- 配置：`$XDG_CONFIG_HOME/pipes-rs/config.toml` 或 `~/.config/pipes-rs/config.toml`

#### 命令行参数

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-c, --color-mode <MODE>` | 颜色模式 ansi/rgb/none | `ansi` | 覆盖配置文件 |
| `--palette <NAME>` | default/darker/pastel/matrix | `default` | 仅 RGB 模式生效 |
| `--rainbow <DEG>` | 每帧色相旋转角度 0–255 | `0` | 仅 RGB 模式；`0` 关闭 |
| `-d, --delay <MS>` | 每帧延迟（毫秒） | `20`（默认 50fps） | 与 `--fps` 互斥 |
| `-f, --fps <N>` | 每秒帧数，`0` 表示不限制 | 未设置 | 与 `--delay` 互斥 |
| `-r, --reset-threshold <F>` | 屏幕覆盖比例达到多少后重置 0–1 | `0.5` | `0` 表示不重置 |
| `-k, --kinds <LIST>` | 管道种类，逗号分隔 | `heavy` | heavy/light/curved/knobby/emoji/outline/dots/blocks/sus |
| `-b, --bold <BOOL>` | 粗体 true/false | `true` | 需要显式给值 |
| `-i, --inherit-style <BOOL>` | 撞边后是否保留颜色/种类 | `false` | 原版 `-K` 的对应物 |
| `-p, --pipe-num <N>` | 管道数量 | `1` | |
| `-t, --turn-chance <F>` | 每帧转向概率 0–1 | `0.15` | 原版 `-s` 的倒数概念 |
| `--license` | 打印 Blue Oak 许可证 | — | 只能单独使用 |
| `-h, --help` / `-V, --version` | 帮助/版本 | — | 只能单独使用 |

#### 配置文件（TOML，全部可选）

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `bold` | `true` | |
| `color_mode` | `"ansi"` | ansi / rgb / none |
| `palette` | `"default"` | default / darker / pastel / matrix |
| `rainbow` | `0` | 0–255 |
| `delay_ms` | `20` | 与 `fps` 互斥 |
| `fps` | 未设置 | |
| `inherit_style` | `false` | |
| `kinds` | `["heavy"]` | |
| `num_pipes` | `1` | |
| `reset_threshold` | `0.5` | `0` = 永不重置 |
| `turn_chance` | `0.15` | |

#### 交互行为

| 按键/事件 | 行为 |
| --- | --- |
| `q` | 退出 |
| `Ctrl-C` | 退出 |
| `r` | 清屏并重置所有管道 |
| 终端 resize | 重新计算屏幕并重置 |

- 进入 alternate screen、raw mode、隐藏光标；退出时恢复。
- 无鼠标处理；无屏保模式（本身即屏保）。

#### 渲染细节

- 每种 kind 8 个字符：上/下/左/右 + 四个拐角（`┃┃━━┏┓┗┛` 等）。
- dots / sus 自定义宽度 2，其余按终端显示宽度自动判断；emoji 宽度不同，混用会错位（README 明确警告）。
- 颜色模式：
  - ansi：从 12 个 ANSI 色随机（红/暗红/绿/暗绿/黄/暗黄/蓝/暗蓝/洋红/暗洋红/青/暗青）。
  - rgb：OKLCH 空间按 palette 的 hue/lightness/chroma 生成，再转 sRGB；`--rainbow` 每帧在 OKLCH 里旋转 hue。
  - none：不设色，继承终端当前色。
- 每帧对每条管道：画当前字符 → 前进一格 → 按 `turn_chance` 转向 → 撞边后按 `inherit_style` 决定“复制样式重来”还是“全新随机”。
- 帧节拍：`fps` 优先，其次 `delay_ms`，否则 50fps；单帧固定 sleep（不补帧）。
- 重置条件：已覆盖屏幕比例 ≥ `reset_threshold`（默认 50%），或按键 `r`、或 resize。

#### 相对原版（pipes.sh）缺什么 / 多什么

原版基线：`-p 1`、`-t 0`（管道类型索引/自定义 16 字符）、`-c`（颜色索引，可多次/十六进制）、`-f 75`、`-s 13`（直行概率 1/13）、`-r 2000`（字符数重置）、`-R`（随机起点/方向）、`-B`（无粗体）、`-C`（无颜色）、`-K`（撞边保留颜色/类型）、`-h`、`-v`。

| 原版能力 | pipes-rs 对应 |
| --- | --- |
| `-p` | `-p/--pipe-num` ✅ |
| `-t` 类型索引 | `-k/--kinds`（9 种固定，**不能自定义字符**） |
| `-t c[16 chars]` 自定义 | ❌ |
| `-c` 多次指定颜色 | 只能整组 palette / 随机；❌ 不能逐管指定 |
| `-f` | `-f/--fps` ✅ |
| `-s` 直行概率 | `-t/--turn-chance`（反向概念）✅ |
| `-r` 字符数重置 | `-r/--reset-threshold`（改成屏幕占比）⚠️ |
| `-R` 随机起点 | 默认即随机起点/方向（无开关） |
| `-B` 无粗体 | `-b false` ✅ |
| `-C` 无颜色 | `-c none` ✅ |
| `-K` 撞边保留 | `-i true` ✅ |
| `-v` | `-V/--version` ✅ |

多出来：TOML 配置、9 种管道（含 blocks/sus/emoji）、4 组 palette、OKLCH 色相旋转、`--license`、Windows 支持、跨平台 crossterm。

#### 值得复刻的亮点

1. 8 字符表 + 四个方向的索引方式，极容易移植。
2. `turn_chance` 直接替代“1/N 直行概率”，语义更直观。
3. palette 用 OKLCH 生成，颜色均匀且暗色背景可读；Zig 里可先做 HSV 简化版。
4. `inherit_style` 的“撞边复制 vs 重生”二选一，是原版 `-K` 的干净抽象。
5. 配置校验（delay 与 fps 互斥、0–1 范围）值得照搬。

### 4.2 pipes 复刻建议

必须：

- 8 方向字符表、转向概率、多管道、帧延迟、撞边重生、`q`/`r` 键、resize。
- 至少一种颜色模式 + `--no-color` 等价能力。

建议做：

- 2–4 种管道样式（heavy/light/curved/knobby 足够）。
- 撞边保留样式（原版 `-K`）。
- 屏幕占比重置阈值。

可以砍：

- emoji / sus / blocks 这类宽度怪异或整活的样式。
- TOML 配置文件（先命令行，后补配置）。
- OKLCH（用 HSV/HSL 足够）。

---

## 5. tty-clock

### 5.0 原版基线（xorg62/tty-clock）

Rust 参考都不完整，这一节以原版 C 的 `-h` / man page 为准，作为复刻 checklist。

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-s` | 显示秒 | 关 | |
| `-S` | 屏保模式，任意键退出 | 关 | |
| `-x` | 显示外框 | 关 | 运行时 `x` 切换 |
| `-c` | 时钟居中 | 关 | 运行时 `c` 切换 |
| `-C <0-7>` | 颜色 | 绿 | 运行时 `0`–`7` 直接换色 |
| `-b` | 粗体 | 关 | 运行时 `b` 切换 |
| `-t` | 12 小时制 | 24h | 运行时 `t` 切换 |
| `-u` | UTC | 本地时区 | |
| `-T <tty>` | 输出到指定 tty | 当前 tty | 必须是字符设备 |
| `-r` | 反弹（撞边移动/变色） | 关 | 运行时 `r` 切换；与居中互斥 |
| `-f <format>` | 日期 strftime 格式 | 内置 | |
| `-n` | 按键不退出 | 关 | |
| `-v` | 版本 | — | |
| `-i` | 版权信息 | — | |
| `-h` | 帮助 | — | |
| `-D` | 隐藏日期 | 显示 | |
| `-B` | 冒号闪烁 | 关 | |
| `-d <sec>` | 重绘间隔（秒） | `1` | 0–99 |
| `-a <ns>` | 额外纳秒延迟 | `0` | 配合 `-d 0` 做高帧率 |

交互键：`q` 退出、`s` 秒开关、`t` 12/24h、`c` 居中、`b` 粗体、`r` 反弹、`x` 外框、`0`–`7` 换色、方向键 / `hjkl` 移动（居中时禁用）、resize 重排。

### 5.1 lukeMains/tty-clock-rs（不完整参考）

- 仓库：<https://github.com/lukeMains/tty-clock-rs>
- 最后提交：2022-07-24（`a727be1`）
- 依赖：ncurses（不是 crossterm）、chrono、signal-hook

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `-h, --help` | 打印 usage | — | **唯一真正实现的参数** |
| 其它所有参数 | — | — | `usage()` 里列了 `-iuvsScbtrahDBxn -C -f -d -a -T`，`main` 里除 `-h` 外全部忽略（源码 `TODO: Add arguments form usage()`） |

#### 实际行为

- 固定 **12 小时制**（`TimeFormat::TwelveHour` 写死，源码标了 `!FIXME`）。
- 固定显示秒、固定绿色（color pair 1: 绿字默认底；pair 2 反色）。
- 日期格式写死 `%F [%p]`（如 `2026-11-08 [PM]`）。
- 7 行 × 54 列时间窗 + 3 行日期窗，画 2×2 空格的方块数字（15 段矩阵）。
- 只注册 `TERM_SIGNALS`（SIGINT/SIGTERM 等）退出；**不调用 `wgetch`**，所以 `q`/方向键都不能退出或移动。
- 不处理 `KEY_RESIZE`，窗口 resize 后不会重排。
- 无限循环按 `chrono::Local::now()` 每轮重绘，没有 sleep/延迟控制。

#### 结论

只能当“大数字点阵 + ncurses 画法”的参考，不能当功能参考。tty-clock 的 Zig 版应以原版 C 的 18 个参数为准。

### 5.2 ckaznable/tenki（时钟 + 天气）

- 仓库：<https://github.com/ckaznable/tenki>
- 最后提交：2026-07-23（`5ec909b`）
- 栈：ratatui + crossterm；定位“tty-clock with weather effect”

#### 参数表

| 参数 | 作用 | 默认值 | 备注 |
| --- | --- | --- | --- |
| `--mode <MODE>` | 背景效果 rain/snow/meteor/disable | `rain` | |
| `--timer-mode <MODE>` | 计时器模式（目前只有 `dvd`） | 无 | DVD 撞边弹跳 |
| `--timer-color <COLOR>` | 时钟颜色 | `white` | 支持 ratatui 颜色名 |
| `-f, --fps <N>` | 渲染帧率 1–240 | `60` | |
| `-t, --tps <N>` | 逻辑 tick 率 1–240 | `60` | |
| `-l, --level <N>` | 效果强度，越小越强 0–1000 | 无 | README 写 4–1000 |
| `--wind <MODE>` | random/disable/only-right/only-left/right/left | `random` | |
| `--show-fps` | 右上角显示 FPS | `false` | |
| `--blink-colon` | 冒号闪烁 | `false` | |
| `-h, --help` / `-V, --version` | 帮助/版本 | — | |

#### 行为/渲染

- `q` / `Q` / `Esc` 退出；无移动、无换色、无屏保。
- 大数字时钟 + 日期？核心是 ratatui 布局；背景 rain/snow/meteor 粒子（受 wind 影响）。
- 支持 DVD 式计时器（撞边反弹）。
- 60fps 渲染 + 60tps 逻辑，帧率可调。

#### 相对原版缺什么

- 缺 `-x` 外框、`-c` 居中、`-r` 反弹时钟、`-T` tty、`-n` 不退出、`-d/-a` 延迟、`-S` 屏保、`-s` 秒开关（tenki 默认显示秒？无开关）、`-t/-u/-D/-B` 的完整语义、`-C 0-7`、方向键/hjkl 移动、运行时换色。
- 多：天气粒子、wind、fps/tps、DVD 计时器、fps 显示。

### 5.3 maachue/ametokei（配置化时钟）

- 仓库：<https://github.com/maachue/ametokei>
- 最后提交：2026-07-10（`475f2c9`）
- 定位：tenki 的非官方分支，重点是把所有东西配置化
- 配置文件：`~/.config/ametokei/config.toml`（`directories::ProjectDirs`）

#### 配置项（TOML）

| 段/键 | 默认值 | 说明 |
| --- | --- | --- |
| `general.show_seconds` | `false` | 秒 |
| `general.format_date` | `"%Y-%m-%d"` | strftime |
| `general.blink_colon` | `false` | 冒号闪烁 |
| `general.color` | `"White"` | 时钟颜色 |
| `general.center` | `false` | 居中 |
| `general.hour12h` | `false` | 12 小时制 |
| `general.utc` | `false` | UTC |
| `general.hide_date` | `false` | 隐藏日期 |
| `general.font` | `"tenki"` | `tenki` / `digital`（tty-clock 风格）/ 自定义字体名 |
| `general.meridiem.am` / `.pm` | `" [AM]"` / `" [PM]"` | 12h 后缀字符串 |
| `general.weather.wind` | `"disable"` | |
| `general.weather.mode` | `"rain"` | |
| `performance.tps` / `.fps` | `60` / `60` | |
| `fontconfig.spacing_horizontal/vertical` | `1` / `1` | 字距 |
| `[font.NAME]` | — | 自定义点阵：`colon_width`、`num_width`、`height`、`symbol_1`、`colon`、`zero`…`nine` 的 0/1 数组 |

#### 命令行参数

`-f/--fps`、`-t/--tps`、`--hour12`、`-c/--center`、`--utc`、`--show-seconds`、`--blink-colon`、`--format-date`、`--hide-date`、`--timer-color`、`--timer-mode`、`--font`、`--wind`、`--level`、`--bg-mode`、`--config <PATH>`、`--no-config`、`--generate-config [PATH]`、`-h`、`-V`。

#### 行为/渲染

- `q` / `Q` / `Esc` 退出；`Backspace` 会 panic（源码 `panic!("panicked. Is terminal restore?")`，不要照抄）。
- 时钟字体可换成 `digital`（tty-clock 风格 5 行点阵）或完全自定义点阵，这是它最有价值的特性。
- 12h 的 AM/PM 字符串可配置，带前导空格。
- 日期格式、UTC、隐藏日期、居中、秒、闪烁冒号都可配置。

#### 相对原版缺什么

- 缺：`-x` 外框、`-r` 反弹、`-T tty`、`-n` 不退出、`-S` 屏保、`-d/-a` 延迟、运行时移动/换色/切 12h、`-C 0-7`。
- 多：天气、配置化、自定义点阵字体、AM/PM 文案、`--generate-config`。

### 5.4 tty-clock 复刻建议

必须（按原版）：

- 5×3 大数字点阵（每数字 3 列 × 5 行，双宽显示）+ 冒号 + 日期行。
- `-s` 秒、`-t` 12h、`-u` UTC、`-D` 隐藏日期、`-B` 闪烁冒号、`-f` 日期格式。
- `-C 0-7` 颜色、`-b` 粗体、`-c` 居中、`-x` 外框、`-r` 反弹。
- `-S` 屏保、`-n` 不退出、`-d/-a` 延迟、`q` 退出、方向键/hjkl 移动、resize。

建议做：

- `-T tty`（实现简单，原版特色）。
- 配置化字体（从 ametokei 借：内置 tenki/digital 两套，自定义点阵可选）。

可以砍：

- 天气粒子（tenki 的卖点，不是 tty-clock 核心）。
- DVD 计时器、wind、fps 浮层。

---

## 6. 复刻优先级速查

| 工具 | 必须做 | 建议做 | 可以砍 |
| --- | --- | --- | --- |
| lolcat | 流式 UTF-8、ANSI 透传、seed/spread/freq、真彩+256、force-color | bg、width、animate/duration/speed、invert | dialup、噪声渐变、CSS 渐变、配置文件 |
| cbonsai | 五种 BranchType、life/multiplier/seed、live/infinite/screensaver/print、base 1/2、消息框 | leaf 列表、4 色列表、base 0、屏保缓存 | text-origin、geometry、base 3+ |
| cmatrix | 列雨、白头部、-u 延迟、8 色、屏保、q/p/0-9/颜色键、resize、**片假名** | 异步滚动、oldstyle、三档粗体 | lock、lambda、tty、24 位渐隐 |
| pipes.sh | 8 字符表、转向、多管、延迟、撞边重生、q/r、resize | 4 种样式、保样式、重置阈值、palette | emoji/sus、TOML 配置、OKLCH |
| tty-clock | 大数字、秒/12h/UTC/日期/闪烁、颜色/粗体/居中/外框/反弹、屏保、移动键、resize | -T tty、配置化字体 | 天气、DVD、wind |

## 7. 一句话结论

- **lolcat**：抄 ur0 的流式/ANSI/回退，补回原版的 animate/invert；不要碰 lolcrab 的噪声渐变。
- **cbonsai**：抄 rbonsai 的生长 + 先算后画；务必补 `-c` 叶子和 `-k` 颜色，否则一眼看出是残版。
- **cmatrix**：抄 Fierthraix 的按键/信号，但**必须自己加片假名**；原版的 `-a` 异步也值得补。
- **pipes.sh**：抄 pipes-rs 的字符表/颜色/配置校验，几乎可以功能对齐；自定义管道字符是唯一明显缺口。
- **tty-clock**：Rust 参考基本不可用，直接照原版 man page 做；ametokei 的点阵字体配置可以当加分项。
