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
| `MONO_GC_PARAMS=nursery-size=8m` | 把 Mono 的年轻代从默认的 4 MB 提升到 8 MB | 减少游玩过程中的 GC 停顿，代价是额外占用约 4 MB 内存 |
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

首次启动时会自动尝试（控制台显示进度，详情见 `log.aot.txt`），之后由 `aot.stamp` 阻止重复执行。
它需要设备上有 `as` 和 `ld`（binutils）、约 100 MB 可用空间、运行时几百 MB 内存，以及几分钟的耐心。
任何一项不满足时，脚本会说明原因，游戏照旧启动；在 `StardewValley.sh` 中设置 `SDV_AUTO_AOT=0` 可完全跳过该步骤。

AOT 生成的代码位于文件映射的共享库中，而不是匿名的 JIT 内存，因此还能降低游戏所需的 RSS，
并让内核在内存紧张时回收冷代码页。

如需删除这些镜像：`bash /roms/ports/stardewvalley/optimize.sh --clean`。
删除 `aot.stamp` 可以让启动器再次尝试（例如装好 `binutils` 之后，或复制进游戏更新之后）。

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