#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
source $controlfolder/device_info.txt
source $controlfolder/tasksetter

[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

gamedir="/$directory/ports/stardewvalley"
cd "$gamedir/"

# 抓取文本输出……
$ESUDO chmod 666 /dev/tty0
printf "\033c" > /dev/tty0
echo "Loading... Please Wait." > /dev/tty0

# ---------------------------------------------------------------------------
# 性能调优。
#
# 所有数值都可以通过环境变量覆盖；各项设置的依据以及更激进的可选参数，见
# stardewvalley.md 的 "Performance"（性能）一节。
# ---------------------------------------------------------------------------

# Mono 的 SGen GC。nursery 必须正好是 2 的整数次幂（4m、8m、16m……）。
# 加大 nursery 可以减少回收次数，也让更多短命对象在年轻代里直接死掉、不必
# 晋升到老年代，代价是常驻内存增加。
#
# ",minor=simple-par" 让年轻代回收分摊到多个核心上执行，但它只在 nursery
# 达到 16m 时才真正生效（Mono 的 SGEN_PARALLEL_MINOR_MIN_NURSERY_SIZE =
# 1 << 24），所以这里必须配 16m；写 8m 再加这个选项是空转。
# 想省内存就退回 nursery-size=8m 并去掉该项，回收会变回单线程。
export MONO_GC_PARAMS="${MONO_GC_PARAMS:-nursery-size=16m,minor=simple-par}"

# gl4es：复用帧缓冲对象而不是重新分配，并跳过启动横幅。
export LIBGL_RECYCLEFBO="${LIBGL_RECYCLEFBO:-1}"
export LIBGL_NOBANNER="${LIBGL_NOBANNER:-1}"

# glibc：每个线程一个 malloc arena 会在这类设备上造成堆碎片。
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

# glibc：把"大块内存走 mmap、释放即归还内核"和"收缩堆顶"的阈值固定在 128 KB。
# 这两个变量一旦由环境给出，glibc 在运行期的动态调整就关闭了；否则它会把
# 阈值一路抬到 32 MB，加载阶段那些临时大缓冲区就一直留在堆里不还给系统。
export MALLOC_MMAP_THRESHOLD_="${MALLOC_MMAP_THRESHOLD_:-131072}"
export MALLOC_TRIM_THRESHOLD_="${MALLOC_TRIM_THRESHOLD_:-131072}"

# OpenAL Soft：本移植版使用 ALSA。显式指定驱动可以免去对当前并未运行的
# PipeWire/PulseAudio 后端的探测（以及等待）。
export ALSOFT_DRIVERS="${ALSOFT_DRIVERS:-alsa}"

# 游戏程序集的自动 AOT 预热，见 optimize.sh。它只在首次启动时运行，之后
# 仅在上一次尝试失败时才再次运行；设置 SDV_AUTO_AOT=0 可跳过。
SDV_AUTO_AOT="${SDV_AUTO_AOT:-1}"

# 配置 mono
monodir="$HOME/mono"
monofile="$controlfolder/libs/mono-6.12.0.122-aarch64.squashfs"
$ESUDO mkdir -p "$monodir"
$ESUDO umount "$monofile" || true
$ESUDO mount "$monofile" "$monodir"

# 配置存档目录
bind_directories ~/.config/StardewValley "$gamedir/savedata"

# 配置 PATH 及其他环境变量
export MONOGAME_PATCH="$gamedir/dlls/StardewPatches.dll"
export MONO_PATH="$gamedir/dlls":"$gamedir"
export PATH="$monodir/bin":"$PATH"
export LD_LIBRARY_PATH="$gamedir/libs:$LD_LIBRARY_PATH"

# 删除旧版 GL4ES 安装文件……
rm -f $gamedir/libs/libGL.so.1 $gamedir/libs/libEGL.so.1

# 向 PortMaster 请求 libGL
if [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
  source "${controlfolder}/libgl_${CFW_NAME}.txt"
else
  source "${controlfolder}/libgl_default.txt"
fi

if [[ "$LIBGL_ES" != "" ]]; then
	export SDL_VIDEO_GL_DRIVER="${gamedir}/gl4es/libGL.so.1"
	export SDL_VIDEO_EGL_DRIVER="${gamedir}/gl4es/libEGL.so.1"
fi

# 现在切换到 gamedata 目录
cd "$gamedir/gamedata"

# Linux 版本的修正：改用 mono 提供的库。
# System.Data.* 程序集除外，因为《星露谷物语》需要其中原本无法由我们
# 提供的 xxHash 类型。
if compgen -G "System.Data*.dll" > /dev/null; then
	mv System.Data*.dll "$gamedir/dlls"
fi
rm -f MonoGame.Framework.* System*.dll

# 判断是 Windows 版本还是 Linux 版本
if [[ -f "Stardew Valley.exe" ]]; then
	gameassembly="Stardew Valley.exe"

	# 复制 Windows 版《星露谷物语》的 WinAPI 兼容配置
	if ! cmp -s "${gamedir}/dlls/Stardew Valley.exe.config" "Stardew Valley.exe.config"; then
		cp "${gamedir}/dlls/Stardew Valley.exe.config" "Stardew Valley.exe.config"
	fi
else
	gameassembly="StardewValley.exe"
fi

# 在设备上对游戏程序集进行 AOT 编译，可以消除启动时以及游戏前几分钟内
# 的大部分 JIT 工作。optimize.sh 负责生成镜像，本启动脚本在需要时于游戏
# 启动前调用它。
#
# log.aot.txt 既是进度日志，也是状态记录：
#   * 最后一行的 "precompiled=" 是上一次尝试的结论：任何工作开始前先写入
#     false——这样崩溃或断电后会被重试——写出 true 表示游戏程序集已有可用
#     镜像，partial 表示只能预编译支撑程序集，因为游戏程序集需要移植版在
#     运行时才替换的引用（见 aot-shims/）；
#   * 完全没有这一行，则表示预编译从未运行过。
# optimize.sh 和本启动脚本都会带上时间戳追加各自的步骤，因此即使没有控制台
# 也能诊断启动失败。
aotlog="$gamedir/log.aot.txt"
aotimage="$gamedir/gamedata/$gameassembly.so"

# 预编译日志中 "key=value" 行的最后一个值；不存在时为空。
aot_last() {
	[ -f "$aotlog" ] || return 0
	awk -v key="$1" 'index($0, key "=") == 1 { v = substr($0, length(key) + 2) } END { print v }' "$aotlog" 2>/dev/null
}

# 追加一行；若上一行因崩溃而被截断，先把它补全。
aot_append() {
	if [ -s "$aotlog" ] && [ -n "$(tail -c 1 "$aotlog" 2>/dev/null)" ]; then
		printf '\n' >> "$aotlog" 2>/dev/null
	fi
	printf '%s\n' "$*" >> "$aotlog" 2>/dev/null
}

aot_log() {
	aot_append "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

aot_state=$(aot_last precompiled)

# 从 PC 复制来的文件在时区不同的情况下读取 SD 卡时，时间戳可能落在未来，
# 导致每次启动都被判定为过期。因此改为比较输入的指纹（文件大小，会随每次
# 游戏或移植版更新而变化），而不使用修改时间。
aot_fingerprint() {
	{
		for f in "$gamedir"/gamedata/*.exe "$gamedir"/gamedata/*.dll \
			"$gamedir/optimize.sh" "$gamedir/dlls/MonoGame.Framework.dll" "$monofile" \
			"$gamedir"/aot-refs/*; do
			[ -f "$f" ] || continue
			printf '%s %s\n' "$(ls -ln "$f" 2>/dev/null | awk '{ print $5 }')" "${f##*/}"
		done
	} 2>/dev/null | sort | md5sum | awk '{ print $1 }'
}

aot_fp=$(aot_fingerprint)
aot_fp_logged=$(aot_last fingerprint)

# 由不同运行时或其他游戏文件生成的镜像无法复用，因此指纹变化同样会强制
# 重建。若没有记录指纹（旧版日志），则直接沿用当前状态。
aot_stale=0
if [ -n "$aot_fp_logged" ] && [ "$aot_fp" != "$aot_fp_logged" ]; then
	aot_stale=1
fi

# 仅在上一次尝试未成功（从未运行、被中断或失败），或镜像已与游戏文件不再
# 匹配时才进行预编译。
# "partial" 表示支撑程序集已预编译，但游戏程序集无法预编译：它引用了移植版
# 只在运行时替换的程序集，因此重跑只会重复完全相同的工作。
aot_needed=1
case "$aot_state" in
	true)
		[ -s "$aotimage" ] && [ "$aot_stale" = "0" ] && aot_needed=0
		;;
	partial)
		if [ "$aot_stale" = "0" ] &&
		   [ -n "$(find "$gamedir/gamedata" -maxdepth 1 -name '*.so' 2>/dev/null | head -n1)" ]; then
			aot_needed=0
		fi
		;;
esac

if [ "$SDV_AUTO_AOT" = "1" ] && [ "$aot_needed" = "1" ]; then
	aot_log "precompile: start (last=${aot_state:-none} stale=$aot_stale)"

	# 在改动任何东西之前先把本次尝试标记为未完成：如果在此处被中断，
	# 下次启动会再次进入预编译流程。
	aot_append "precompiled=false"

	if [ ! -f "$gamedir/optimize.sh" ]; then
		aot_log "precompile: failed, $gamedir/optimize.sh not found"
		aot_log "aot_error=launcher:optimize-missing"
		echo "Precompilation unavailable, see log.aot.txt. Starting the game..." > /dev/tty0
	else
		echo "Precompiling game files, one time only..." > /dev/tty0
		echo "This can take several minutes, please do not power off." > /dev/tty0
		MONODIR="$monodir" bash "$gamedir/optimize.sh" >> "$aotlog" 2>&1
		aot_rc=$?
		aot_state=$(aot_last precompiled)
		if [ "$aot_rc" -eq 0 ] && [ "$aot_state" = "true" ] && [ -s "$aotimage" ]; then
			aot_append "fingerprint=$aot_fp"
			aot_log "precompile: finished, images ready"
			echo "Precompilation finished. Starting the game..." > /dev/tty0
		elif [ "$aot_state" = "partial" ]; then
			aot_append "fingerprint=$aot_fp"
			aot_log "precompile: finished partially, game assembly not precompiled"
			echo "Precompilation finished. Starting the game..." > /dev/tty0
		else
			# 保持最后一次结论为 false，以便下次启动重试。
			[ "$aot_state" = "false" ] || aot_append "precompiled=false"
			aot_log "precompile: failed (exit=$aot_rc last=${aot_state:-none})"
			aot_log "aot_error=launcher:optimize-exit-$aot_rc"
			echo "Precompilation failed, see log.aot.txt. Starting the game..." > /dev/tty0
		fi
	fi
fi

# 跳过预编译时采用当前的输入指纹：早于指纹机制的日志不能仅因缺少该值
# 就触发重建。
if [ "$aot_needed" = "0" ] && [ -z "$aot_fp_logged" ]; then
	aot_append "fingerprint=$aot_fp"
fi

aot_result=$(aot_last precompiled)
[ -n "$aot_result" ] || aot_result=none

# 内存曲线采样：SDV_MEMLOG=1 会在 log.txt 旁写入 log.mem.txt，
# 每行是"时间戳 当前 RSS(kB) 峰值 RSS(kB)"，游戏退出后峰值会追加到 log.txt。
start_memlog() {
	local memlog="${gamedir}/log.mem.txt"
	local pid=

	: > "$memlog"
	(
		for _ in $(seq 1 60); do
			pid=$(pgrep -f SVLoader.exe 2>/dev/null | head -n1)
			[ -n "$pid" ] && break
			sleep 2
		done
		while [ -n "$pid" ] && [ -r "/proc/$pid/status" ]; do
			awk -v t="$(date +%s)" '
				/^VmRSS:/ { rss = $2 }
				/^VmHWM:/ { hwm = $2 }
				END { if (rss) print t, rss, hwm }
			' "/proc/$pid/status" 2>/dev/null >> "$memlog"
			sleep 5
		done
	) &
}

log="${gamedir}/log.txt"
start_ts=$(date +%s)
{
	echo "=== Stardew Valley port $(date '+%Y-%m-%d %H:%M:%S') ==="
	echo "tuning: MONO_GC_PARAMS=${MONO_GC_PARAMS} MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX}"
	echo "tuning: MALLOC_MMAP_THRESHOLD_=${MALLOC_MMAP_THRESHOLD_} MALLOC_TRIM_THRESHOLD_=${MALLOC_TRIM_THRESHOLD_}"
	echo "tuning: LIBGL_RECYCLEFBO=${LIBGL_RECYCLEFBO} ALSOFT_DRIVERS=${ALSOFT_DRIVERS}"
	echo "aot: precompiled=$aot_result stale=$aot_stale images=$(ls -1 "$gamedir/gamedata/"*.so 2>/dev/null | wc -l)"
	echo "--- game output ---"
} > "$log"

memlog_started=0
if [ -n "${SDV_MEMLOG:-}" ] && command -v pgrep > /dev/null 2>&1; then
	start_memlog
	memlog_started=1
fi

$GPTOKEYB "mono" &
$TASKSET mono ../SVLoader.exe "${gameassembly}" 2>&1 | tee -a "$log"
echo "--- session length: $(( $(date +%s) - start_ts ))s ---" >> "$log"
if [ "$memlog_started" = "1" ] && [ -s "$gamedir/log.mem.txt" ]; then
	awk '{ if ($3 + 0 > peak) peak = $3 + 0 }
		END { if (peak) printf "--- peak RSS: %d MB ---\n", peak / 1024 }' \
		"$gamedir/log.mem.txt" >> "$log"
fi
$ESUDO kill -9 $(pidof gptokeyb)
$ESUDO systemctl restart oga_events &
$ESUDO umount "$monodir"

# 关闭控制台
printf "\033c" >> /dev/tty1
