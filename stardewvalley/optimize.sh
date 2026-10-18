#!/bin/bash
#
# One-time AOT ("ahead of time") compilation of the Stardew Valley assemblies
# for the Mono 6.12 runtime of this PortMaster port.
#
# Modern Mono spends a large part of the startup and of the first minutes of
# play compiling CIL to ARM64. AOT images move that work to a one-time step:
# the code then lives in a file-backed .so next to the assembly instead of in
# anonymous JIT memory, which is both faster to start and easier for the
# kernel to reclaim under memory pressure.
#
#   bash optimize.sh           compile what is missing or out of date
#   bash optimize.sh --clean   delete every generated image again
#
# Output: <assembly>.dll.so / <assembly>.exe.so in gamedata/, plus aot.stamp.
# Mono output goes to log.aot.txt.
#
# It is safe to run more than once; only stale images are rebuilt.

PORT_DIR=$(cd "$(dirname "$0")" && pwd)
GAMEDATA="$PORT_DIR/gamedata"
STAMP="$PORT_DIR/aot.stamp"
LOG="$PORT_DIR/log.aot.txt"

ESUDO=${ESUDO:-}

say() {
	printf '%s\n' "$*"
	if [ -w /dev/tty0 ]; then
		printf '%s\n' "$*" > /dev/tty0 2>/dev/null
	fi
	return 0
}

fail() {
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
	say "AOT images removed."
}

if [ "$1" = "--clean" ]; then
	clean_images
	exit 0
fi

if [ ! -d "$GAMEDATA" ]; then
	fail "ERROR: $GAMEDATA not found."
fi

# Locate PortMaster's control files so we can reuse its privilege helper and
# find the Mono squashfs. When started from StardewValley.sh the environment is
# already set up; when started over SSH/frontend we source control.txt here.
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
	# Not a permanent failure: the runtime squashfs is only mounted while the
	# game runs, so leave no stamp and let the next launch try again.
	say "ERROR: Mono runtime not found in $monodir/bin or PATH."
	say "Start the game once so PortMaster mounts it, then run this again."
	exit 1
fi

missing_tools=
for tool in as ld; do
	command -v "$tool" > /dev/null 2>&1 || missing_tools="$missing_tools $tool"
done
if [ -n "$missing_tools" ]; then
	say "ERROR: binutils missing:$missing_tools"
	say "Mono AOT needs the native assembler and linker on the device."
	echo "status=failed reason=binutils-missing:$missing_tools $(date '+%Y-%m-%d %H:%M:%S')" > "$STAMP"
	[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
	exit 1
fi

free_kb=$(df -Pk "$PORT_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
case "$free_kb" in
	''|*[!0-9]*) ;;
	*)
		if [ "$free_kb" -lt 102400 ]; then
			say "ERROR: less than 100 MB free on the game partition."
			echo "status=failed reason=no-space $(date '+%Y-%m-%d %H:%M:%S')" > "$STAMP"
			[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
			exit 1
		fi
		;;
esac

export MONO_PATH="$PORT_DIR/dlls:$GAMEDATA"
export PATH="$monodir/bin:$PATH"

mono_version=$("$MONO" --version 2>/dev/null | head -n1)
say "Mono: $mono_version"

# Images built by a different runtime cannot be reused.
force=0
if [ -f "$STAMP" ]; then
	prev_mono=$(sed -n 's/^mono=//p' "$STAMP" | head -n1)
	if [ -n "$prev_mono" ] && [ "$prev_mono" != "$mono_version" ]; then
		say "Mono runtime changed, rebuilding all images."
		force=1
	fi
fi

say "Writing details to $LOG"
printf '\n=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

compiled=0
skipped=0

compile_one() {
	local assembly="$1"
	local name image

	name=$(basename "$assembly")
	image="$assembly.so"

	# FAT/SD cards only store timestamps to the second, so treat "not newer"
	# as current instead of requiring a strictly newer image.
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

{
	echo "status=ok"
	echo "mono=$mono_version"
	echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
	echo "compiled=$compiled"
	echo "skipped=$skipped"
} > "$STAMP"

say "Done: $compiled compiled, $skipped skipped."

[ "$mounted_here" = "1" ] && $ESUDO umount "$monodir"
exit 0
