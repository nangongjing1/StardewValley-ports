## 说明

感谢 [MonoGame](https://github.com/MonoGame/MonoGame) 项目提供的框架，本移植才得以实现。
感谢 JohnnyonFlame 完成的移植工作。

## 详细安装步骤

你需要一份 Stardew Valley 的[兼容版本（compatibility version）](https://www.stardewvalley.net/compatibility/)。

1. **安装 Stardew Valley 兼容版本**
    
    *Steam：*
    
    1. 在 Steam 库中右键 “Stardew Valley”
    2. 选择 “属性”
    3. 切换到 “测试版（Betas）” 选项卡
    4. 打开下拉菜单，选择 “Compatibility”
    5. 游戏会自动开始更新
    
    *GOG（Galaxy 客户端）：*
    
    1. 在游戏列表中右键 “Stardew Valley”
    2. 把鼠标悬停在 “管理安装（Manage Installation）” 上，选择 “配置（Configure）”
    3. 打开 “Beta Channels” 下拉菜单，选择 “Compatibility”
    4. 确认 “自动更新（Auto-updates）” 中选择的是最新版本
    5. 游戏会自动开始更新
  
    *GOG（Heroic 客户端）：*
    
    1. 需要重新安装一次才能选择兼容版本
    2. 在游戏列表中右键 “Stardew Valley”
    3. 点击 “安装（Install）”
    4. 安装对话框弹出后，打开 “Select beta channel” 下拉菜单，选择 “compatibility”
    5. 点击 “安装”
    
2. **通过 PortMaster 安装 Stardew Valley**
    1. 打开 PortMaster 应用
    2. 选择 All Ports
    3. 找到 Stardew Valley
    4. 按 A 安装
    5. 退出 PortMaster

3. **把游戏数据复制到 ports 目录（不是 ROMS/ports）**
    1. 把 SD 卡插入电脑的读卡器
    2. 进入 ports > stardewvalley > gamedata
    3. 打开第 1 步装好的 Steam 或 GOG 版 Stardew Valley 的安装目录
    4. 把安装目录里的全部文件复制到 SD 卡的 /ports/stardewvalley/gamedata 目录
    
4. **开始游戏**
    1. 把 SD 卡插回设备
    2. 进入 content，再进入 ports
    3. 运行 StardewValley

## 性能调优(南宫镜做的工作)

本包是在 PortMaster 原版移植的基础上加了若干调优。
所有改动都只是 `StardewValley.sh` 里的环境变量，因此可以逐条删除或覆盖，不必改动游戏数据。

| 设置 | 作用 | 原因 |
| --- | --- | --- |
| `MONO_GC_PARAMS=nursery-size=12m` | 把 Mono 的年轻代从默认的 4 MB 提升到 12 MB | 减少游玩过程中的 GC 停顿，代价是额外占用约 8 MB 内存 |
| `LIBGL_RECYCLEFBO=1` | 复用帧缓冲对象（FBO），而不是反复创建、销毁 | 减少光照与昼夜渲染目标带来的分配开销 |
| `LIBGL_NOBANNER=1` | 隐藏 gl4es 的启动横幅 | 启动略快，`log.txt` 更干净 |
| `MALLOC_ARENA_MAX=2` | 把 glibc 的 malloc arena 限制为 2 个 | 在 4 核掌机上降低常驻内存 |
| `ALSOFT_DRIVERS=alsa` | 把 OpenAL Soft 固定到 ALSA 后端 | 本机使用 ALSA（见下方说明），直接指定可跳过 PipeWire/PulseAudio 的探测与等待。若你的固件基于 PulseAudio 且出现无声，请删掉这一行 |

启动阶段的清理动作也改成了幂等操作：`System.Data.*` 的搬移、重复程序集的清理、
`Stardew Valley.exe.config` 的复制，现在只在确实需要时才执行；
`log.txt` 开头会记录本次生效的调优参数，结尾记录本次运行时长。

### 一次性 AOT 预编译

Stardew 启动时的大部分时间都花在 Mono 把 CIL 编译成 ARM64 代码上。
`optimize.sh` 把这步提前做一次，结果保存在 `gamedata/*.dll.so` 中：

```sh
bash /roms/ports/stardewvalley/optimize.sh
```

首次启动时会自动执行（控制台显示进度，详情见 `log.aot.txt`）。
预编译的结果以 `precompiled=` 写在 `log.aot.txt` 里，共有三种取值：

```
precompiled=true
precompiled=partial
precompiled=false
```

* `true`：主程序集和依赖都已生成镜像，之后不再重复预编译；
* `partial`：工具链正常、能编译的依赖都已编译，但主程序集缺少它引用的 XNA 程序集而无法
  生成镜像（见下文 `aot-refs/`）。这是确定性结果，不会每次启动重试；
* `false`：上次失败、被中断或工具链不可用，下次启动会再次尝试。

启动脚本只读取最后一条 `precompiled=`：`true` 或 `partial` 时跳过，没有这一行（从未执行过、
或执行到一半断电）或值为 `false`（上次失败）时，下次启动会再次尝试。

启动脚本同样会在动手前先写入 `precompiled=false`，并在日志里追加带时间戳的过程行，
因此即使 `optimize.sh` 根本没能启动（文件丢失、脚本报错），也不会被当成已经预编译：

```
2026-10-19 21:30:12 precompile: start (last=none stale=0)
...
2026-10-19 21:34:05 precompile: finished, images ready
2026-10-19 21:40:11 precompile: start (last=false stale=0)
2026-10-19 21:40:11 precompile: failed (exit=1 last=false)
2026-10-19 21:40:11 aot_error=launcher:optimize-exit-1
```

`precompile: finished partially, game assembly not precompiled` 表示这次按 `partial` 收尾。

### 主程序集与 `aot-shims/`

Windows 版的主程序集 `Stardew Valley.exe` 引用 XNA 4.0（`Microsoft.Xna.Framework*`），
而本移植在运行时用 MonoGame 加 `SVLoader.exe` 把这些引用重定向掉。AOT 在编译期解析引用，
拿不到对应程序集时 Mono 的 `collect_methods()` 会在第一个无法加载的方法上放弃整张主程序集镜像
（日志里是 `Failed to load method ... Microsoft.Xna.Framework.Game ...` 加 `AOT of image ... failed.`）。

预编译开始前，脚本会自动把 `dlls/MonoGame.Framework.dll` 复制成四个 XNA 文件名放进
`stardewvalley/aot-shims/`：

```
Microsoft.Xna.Framework.dll  Microsoft.Xna.Framework.Game.dll
Microsoft.Xna.Framework.Graphics.dll  Microsoft.Xna.Framework.Xact.dll
```

这可行的原因是：Mono 默认不校验文件背后的程序集身份（`check_assembly_names_strictly = FALSE`，
只看 `MONO_PATH` 里的文件名），而 MonoGame 的程序集版本是 `0.0.0.0` 且没有强名称，因此
被引用为 `Microsoft.Xna.Framework, Version=4.0.0.0` 时也会被接受。这样 AOT 编译期解析到的
就是 MonoGame 本身的类型与布局，和运行时（SVLoader 重定向到 MonoGame）完全一致，
既不需要真正的 XNA 程序集，也没有“按 XNA 布局编译、按 MonoGame 运行”的风险。

这些副本只在预编译期间加入 `MONO_PATH`，游戏运行时不会加载它们。
`aot-refs/` 仍然保留给需要手动指定引用程序集的场景，它会排在 `aot-shims/` 之前。

每次预编译都会把上一次的日志保存为 `log.aot.txt.1`，避免失败时逐方法的报错把日志撑大；
预编译期间还会关闭 core dump（`ulimit -c 0`），防止 Mono 在个别程序集上崩溃时在 SD 卡留下巨大的 core 文件。

它需要设备上有 `as` 和 `ld`（binutils）、约 100 MB 可用空间、运行时几百 MB 内存，以及几分钟的耐心。
PortMaster 的 mono 运行时自带这两个工具，脚本会从实际使用的 mono 所在目录推断运行时根目录，
并把旁边的 `lib/`（放着 `libopcodes`、`libbfd`）加入 `LD_LIBRARY_PATH`——否则 `as`/`ld`
会因为找不到这些库而起不来。查找顺序是：`PATH` → 运行时 `bin/` → 运行时 `libexec/` →
`stardewvalley/tools/bin/` → 运行时目录内的有限深度搜索。
如果设备上确实没有这两件工具，可以自己放一份到 `stardewvalley/tools/bin/`（可执行文件即可）。

任何一项不满足时，脚本会把原因写进 `log.aot.txt`（`aot_error=...`），并附上 mono 路径、
运行时目录内容等诊断信息，游戏照旧启动，下次启动再试；
在 `StardewValley.sh` 中设置 `SDV_AUTO_AOT=0` 可完全跳过该步骤。

AOT 生成的代码位于文件映射的共享库中，而不是匿名的 JIT 内存，因此还能降低游戏所需的 RSS，
并让内核在内存紧张时回收冷代码页。

如需删除这些镜像：`bash /roms/ports/stardewvalley/optimize.sh --clean`
（它同时写入 `precompiled=false`，下次启动会重新预编译）。
判断“输入是否变了”用的是**文件指纹**（`gamedata` 里的程序集、`optimize.sh`、
`MonoGame.Framework.dll`、Mono 运行时和 `aot-refs/` 的大小经 md5 汇总），不是修改时间：
从 PC 拷贝到 SD 卡的文件时间戳可能位于设备当前时间之后，用时间比较会让每次启动都误判为需要重编。
指纹记录在 `log.aot.txt` 的 `fingerprint=` 行；因此把新的游戏文件复制进 `gamedata`、更新 Mono
运行时、替换为新版 `optimize.sh`、或向 `aot-refs/` 放入新的引用程序集之后，启动脚本只会重新预编译一次。
删除 `log.aot.txt` 或执行 `optimize.sh --clean` 可以强制重来。

### 可选的更激进设置

只有确认在你自己设备上可用之后，再把下面这些加入调优块：

* `export MONO_GC_PARAMS="${MONO_GC_PARAMS},minor=simple-par"` —— 并行年轻代回收。
  配合较大的年轻代能进一步缩短 GC 停顿，但只适用于编译时启用了并发回收器的 Mono（几乎所有构建都启用了）。
* `export MONO_THREADS_SUSPEND=coop` —— 协作式线程挂起，避免每次回收都做信号往返。
  只有在 Mono 构建支持时才生效。
* `export MONO_GC_PARAMS="${MONO_GC_PARAMS},soft-heap-limit=320m"` —— 让 GC 在托管堆接近上限时更积极回收。
  适合 1 GB 内存的设备，代价是一些 CPU 时间。
* `export LIBGL_SHRINK=2` —— 把所有大于 512 px 的纹理尺寸减半。能省下大量内存，但像素画会变模糊。

有一项是刻意**没有**开启的：`LIBGL_BATCH`。对 `SpriteBatch` 类游戏它看起来很有吸引力，
但 MonoGame 是用顶点缓冲（VBO）绘制的，而 gl4es 的批处理会通过 `copy_gl_pointer_*` 复制每个顶点数组，
在这套驱动栈上相当于 GPU 到 CPU 的回读，通常会让本游戏更慢。

注意：从 PortMaster 重新安装该移植会覆盖 `StardewValley.sh`，
如果你依赖自己的改动，请另存一份副本。

> [协议](/LICENSE)只作用于我对项目做出的改动