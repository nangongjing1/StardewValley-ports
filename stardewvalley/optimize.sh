#!/bin/bash
#
# 一次性对本 PortMaster 移植版的《星露谷物语》程序集进行 AOT（"ahead of
# time"，提前编译）编译，以适配 Mono 6.12 运行时。
#
# 新版 Mono 会把启动过程以及游戏前几分钟里的大量时间花在把 CIL 编译成 ARM64
# 上。AOT 镜像把这项工作挪到一次性步骤中完成：代码随后存在于程序集旁边的
# 文件映射 .so 中，而不再是匿名的 JIT 内存，因此启动更快，在内存紧张时内核
# 也更容易回收。
#
#   bash optimize.sh           编译缺失或已过期的内容
#   bash optimize.sh --clean   删除所有已生成的镜像
#
# 输出：gamedata/ 下的 <assembly>.dll.so / <assembly>.exe.so，以及 aot.stamp。
# Mono 的输出写入 log.aot.txt，其中还会以布尔值行的形式记录结果：
# "precompiled=true" 或 "precompiled=false"。StardewValley.sh 会读取最后
# 一行这样的记录，只有在其不为 true 时才会再次编译。
#
# 重复运行是安全的；只会重建过期的镜像。

PORT_DIR=$(cd "$(dirname "$0")" && pwd)
GAMEDATA="$PORT_DIR/gamedata"
STAMP="$PORT_DIR/aot.stamp"
LOG="$PORT_DIR/log.aot.txt"

ESUDO=${ESUDO:-}

# Mono 在无法编译的程序集上可能直接中止；运行时产生的核心转储文件在 SD 卡
# 上会有数百 MB。
ulimit -c 0 2>/dev/null || true

# 启动脚本把日志中最后一行的 "precompiled=" 当作真实状态：缺少该行或为 false
# 都表示下次启动会再次尝试。false 标记也会在工作开始前写入，因此被中断或
# 崩溃的运行不会被误认为已经完成。
record_result() {
	printf 'precompiled=%s\n' "$1" >> "$LOG"
}

record_error() {
	printf 'aot_error=%s\n' "$*" >> "$LOG"
}

say() {
	printf '%s\n' "$*"
	if [ -w /dev/tty0 ]; then
		printf '%s\n' "$*" > /dev/tty0 2>/dev/null
	fi
	return 0
}

fail() {
	record_error "$*"
	say "$*"
	exit 1
}

clean_images() {
	local f
	for f in "$GAMEDATA"/*.so; do
		[ -e "$f" ] || continue
		case "$f" in
			*.dll.so|*.exe.so)
				rm -f "$f" && say "removed $(basename "$f")"
				;;
		esac
	done
	rm -f "$STAMP"
	record_result false
	say "AOT images removed. The next start prepares them again."
}

if [ "$1" = "--clean" ]; then
	clean_images
	exit 0
fi

# 运行失败时，加载器会为每个无法编译的方法打印错误，因此日志中只保留本次
# 尝试，另留上一次作为参考。
if [ -f "$LOG" ]; then
	mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

printf '\n=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
record_result false

if [ ! -d "$GAMEDATA" ]; then
	fail "ERROR: $GAMEDATA not found."
fi

# 定位 PortMaster 的控制文件，以便复用其提权辅助脚本并找到 Mono 的 squashfs。
# 从 StardewValley.sh 启动时环境已配置好；通过 SSH/前端启动时则在此处加载
# control.txt。
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

if [ -z "$ESUDO" ] && [ -f "$controlfolder/control.txt" ]; then
	# shellcheck disable=SC1090,SC1091
	source "$controlfolder/control.txt"
	cd "$PORT_DIR" || exit 1
fi

monodir="${MONODIR:-$HOME/mono}"
monofile="$controlfolder/libs/mono-6.12.0.122-aarch64.squashfs"
mounted_here=0

if [ ! -x "$monodir/bin/mono" ]; then
	$ESUDO mkdir -p "$monodir" 2>/dev/null
	if $ESUDO mount "$monofile" "$monodir" 2>/dev/null; then
		mounted_here=1
	fi
fi

MONO="$monodir/bin/mono"
if [ ! -x "$MONO" ]; then
	MONO=$(command -v mono 2>/dev/null)
fi

if [ -z "$MONO" ] || [ ! -x "$MONO" ]; then
	# 并非永久性失败：运行时 squashfs 只在游戏运行时才挂载，因此不写标记，
	# 让下次启动再试一次。
	record_error "mono-missing:$monodir"
	say "ERROR: Mono runtime not found in $monodir/bin or PATH."
	say "Start the game once so PortMaster mounts it, then run this again."
	exit 1
fi

# PortMaster 的 Mono 运行时把 AOT 所用的汇编器和链接器放在 bin/mono 旁边，
# 并把它们的支撑库（libbfd、libopcodes）放在同级的 lib/ 目录中。该目录不在
# 默认的库搜索路径里，因此即使文件存在，as/ld 也会启动失败；在查找它们之前
# 先将两者加入搜索路径。解析符号链接，以便在 mono 是链接时得到正确的运行时
# 根目录。
mono_real=$(readlink -f "$MONO" 2>/dev/null)
[ -n "$mono_real" ] || mono_real="$MONO"
mono_bin_dir=$(dirname "$mono_real")
mono_root=$(dirname "$mono_bin_dir")

add_libdir() {
	[ -d "$1" ] || return 0
	case ":$LD_LIBRARY_PATH:" in
		*":$1:"*) ;;
		*)
			if [ -n "${LD_LIBRARY_PATH:-}" ]; then
				LD_LIBRARY_PATH="$1:$LD_LIBRARY_PATH"
			else
				LD_LIBRARY_PATH="$1"
			fi
			export LD_LIBRARY_PATH
			;;
	esac
}

export PATH="$mono_bin_dir:$PATH"
for libdir in "$mono_root/lib" "$mono_bin_dir/../lib" "$mono_root/usr/lib"; do
	add_libdir "$libdir"
done

find_binutil() {
	local name="$1" candidate
	candidate=$(command -v "$name" 2>/dev/null)
	if [ -n "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	for candidate in "$mono_bin_dir/$name" "$mono_root/bin/$name" "$mono_root/libexec/$name" \
		"$PORT_DIR/tools/bin/$name" "$controlfolder/bin/$name"; do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	# 最后的尝试：某些运行时会把工具链放在子目录里。
	if [ "$mono_root" != "/" ]; then
		find "$mono_root" -maxdepth 4 -type f -name "$name" 2>/dev/null | while IFS= read -r candidate; do
			if [ -x "$candidate" ]; then
				printf '%s\n' "$candidate"
				break
			fi
		done
	fi
}

as_bin=$(find_binutil as)
ld_bin=$(find_binutil ld)

if [ -z "$as_bin" ] || [ -z "$ld_bin" ]; then
	missing_tools=
	[ -z "$as_bin" ] && missing_tools="$missing_tools as"
	[ -z "$ld_bin" ] && missing_tools="$missing_tools ld"

	record_error "binutils-missing:$missing_tools"
	say "ERROR: binutils missing:$missing_tools"
	say "Mono AOT needs the native assembler and linker on the device."
	printf 'mono=%s\nmono_root=%s\nmono_bin_dir=%s\nld_library_path=%s\npath=%s\n' \
		"$mono_real" "$mono_root" "$mono_bin_dir" "${LD_LIBRARY_PATH:-}" "$PATH" >> "$LOG"
	for dir in "$mono_root" "$mono_bin_dir"; do
		[ -d "$dir" ] || continue
		printf 'contents of %s:\n' "$dir" >> "$LOG"
		ls -la "$dir" >> "$LOG" 2>&1
	done
	echo "status=failed reason=binutils-missing:$missing_tools $(date '+%Y-%m-%d %H:%M:%S')" > "$STAMP"
	[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
	exit 1
fi

# Mono 是按名称调用这些工具的，因此它们的目录必须排在最前面，而其自身的
# 支撑库则在它们旁边查找。
as_dir=$(dirname "$as_bin")
ld_dir=$(dirname "$ld_bin")
export PATH="$as_dir:$ld_dir:$PATH"
add_libdir "$as_dir/../lib"
add_libdir "$ld_dir/../lib"
as_version=$("$as_bin" --version 2>&1 | head -n1)
ld_version=$("$ld_bin" --version 2>&1 | head -n1)
printf 'as=%s (%s)\nld=%s (%s)\n' "$as_bin" "$as_version" "$ld_bin" "$ld_version" >> "$LOG"
say "Assembler: $as_bin"
say "Linker:    $ld_bin"

free_kb=$(df -Pk "$PORT_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
case "$free_kb" in
	''|*[!0-9]*) ;;
	*)
		if [ "$free_kb" -lt 102400 ]; then
			record_error "no-space:${free_kb}kb"
			say "ERROR: less than 100 MB free on the game partition."
			echo "status=failed reason=no-space $(date '+%Y-%m-%d %H:%M:%S')" > "$STAMP"
			[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
			exit 1
		fi
		;;
esac

export MONO_PATH="$PORT_DIR/dlls:$GAMEDATA"

# Windows 版本引用的是 XNA 4.0（Microsoft.Xna.Framework*），而移植版只在运行时
# 才替换这些引用：SVLoader 会把它们重定向到 MonoGame。AOT 在编译时就要解析
# 引用，因此需要有这些名称的程序集。Mono 不校验文件名背后的程序集标识（严格
# 名称检查默认关闭），而 MonoGame 的版本为 0.0.0.0 且未签名，所以用 XNA 的
# 名称复制一份 MonoGame，就能让每个引用解析到游戏运行时实际绑定的同一份代码
# ——类型相同、布局相同。
# 这些副本只在编译期间出现在 MONO_PATH 中；游戏本身永远不会看到它们。
aot_shims="$PORT_DIR/aot-shims"
monogame="$PORT_DIR/dlls/MonoGame.Framework.dll"
if [ -f "$monogame" ]; then
	mkdir -p "$aot_shims" 2>/dev/null
	for shim in Microsoft.Xna.Framework Microsoft.Xna.Framework.Game \
		Microsoft.Xna.Framework.Graphics Microsoft.Xna.Framework.Xact; do
		if [ ! -f "$aot_shims/$shim.dll" ] || [ "$monogame" -nt "$aot_shims/$shim.dll" ]; then
			cp -f "$monogame" "$aot_shims/$shim.dll" 2>/dev/null
		fi
	done
	printf 'shims=%s\n' "$aot_shims" >> "$LOG"
fi

# 手工提供的额外引用程序集优先于 shim。
aot_refs=
[ -d "$PORT_DIR/aot-refs" ] && aot_refs="$PORT_DIR/aot-refs"
[ -d "$aot_shims" ] && aot_refs="${aot_refs:+$aot_refs:}$aot_shims"
if [ -n "$aot_refs" ]; then
	export MONO_PATH="$aot_refs:$MONO_PATH"
	say "References: $aot_refs"
	printf 'refs=%s\n' "$aot_refs" >> "$LOG"
fi

export PATH="$monodir/bin:$PATH"

mono_version=$("$MONO" --version 2>/dev/null | head -n1)
say "Mono: $mono_version"
printf 'mono=%s\n' "$mono_version" >> "$LOG"

# 由不同运行时生成的镜像无法复用。
force=0
if [ -f "$STAMP" ]; then
	prev_mono=$(sed -n 's/^mono=//p' "$STAMP" | head -n1)
	if [ -n "$prev_mono" ] && [ "$prev_mono" != "$mono_version" ]; then
		say "Mono runtime changed, rebuilding all images."
		force=1
	fi
fi

say "Writing details to $LOG"

compiled=0
skipped=0

compile_one() {
	local assembly="$1"
	local name image

	name=$(basename "$assembly")
	image="$assembly.so"

	# FAT/SD 卡的时间戳只精确到秒，因此把 "不比镜像新" 也视为最新，
	# 而不要求镜像严格更新。
	if [ "$force" = "0" ] && [ -f "$image" ] && [ ! "$assembly" -nt "$image" ]; then
		say "current:   $name"
		return 0
	fi

	say "compiling: $name ..."
	rm -f "$image"
	if "$MONO" --aot=full "$assembly" >> "$LOG" 2>&1 && [ -s "$image" ]; then
		compiled=$((compiled + 1))
		say "compiled:  $name"
		return 0
	fi

	rm -f "$image"
	skipped=$((skipped + 1))
	say "skipped:   $name (not a managed assembly, or the AOT compiler refused it)"
	return 1
}

for assembly in "$GAMEDATA"/*.exe "$GAMEDATA"/*.dll; do
	[ -e "$assembly" ] || continue
	compile_one "$assembly"
done

# 游戏程序集是决定 AOT 是否有价值的镜像：如果它编译成功，说明工具链可用，
# Mono 会在下次启动时加载这些镜像。非托管程序集（steam_api.dll 之类）按设计
# 会被跳过，不计为失败。
gameassembly=
for candidate in "Stardew Valley.exe" "StardewValley.exe"; do
	if [ -f "$GAMEDATA/$candidate" ]; then
		gameassembly="$candidate"
		break
	fi
done

missing_refs=0
if [ ! -s "$GAMEDATA/$gameassembly.so" ] &&
   grep -q "from '[^']*/$gameassembly' due to Could not load file or assembly 'Microsoft.Xna.Framework" "$LOG" 2>/dev/null; then
	missing_refs=1
fi

if [ -z "$gameassembly" ]; then
	aot_result=false
	aot_status=failed
	aot_reason=game-assembly-missing
elif [ -s "$GAMEDATA/$gameassembly.so" ]; then
	aot_result=true
	aot_status=ok
	aot_reason=ready
elif [ "$missing_refs" = "1" ]; then
	# 这是确定性的：游戏程序集引用了移植版只在运行时替换的程序集，无论
	# 重试多少次都无法生成它的镜像。
	# 支撑程序集仍会编译，这已是该设备能得到的全部。
	aot_result=partial
	aot_status=partial
	aot_reason=missing-xna-refs
else
	aot_result=false
	aot_status=failed
	aot_reason=core-image-missing
fi

{
	echo "status=$aot_status"
	echo "precompiled=$aot_result"
	echo "reason=$aot_reason"
	echo "mono=$mono_version"
	echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
	echo "compiled=$compiled"
	echo "skipped=$skipped"
	echo "seconds=$SECONDS"
} > "$STAMP"

record_result "$aot_result"

case "$aot_result" in
	true)
		say "Done: $compiled compiled, $skipped skipped. AOT images ready."
		;;
	partial)
		say "Done: $compiled compiled, $skipped skipped."
		say "The game assembly references assemblies the port substitutes at runtime,"
		say "so it could not be resolved through $PORT_DIR/aot-shims."
		say "See log.aot.txt; the next start will not retry before."
		;;
	*)
		record_error "$aot_reason"
		say "Done: $compiled compiled, $skipped skipped - no usable AOT image."
		say "The next start will try again."
		;;
esac

[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
[ "$aot_result" = "true" ] || [ "$aot_result" = "partial" ]
