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
# Mono output goes to log.aot.txt, which also receives the result as a boolean
# line, "precompiled=true" or "precompiled=false". StardewValley.sh reads the
# last of those lines and only compiles again while it is not true.
#
# It is safe to run more than once; only stale images are rebuilt.

PORT_DIR=$(cd "$(dirname "$0")" && pwd)
GAMEDATA="$PORT_DIR/gamedata"
STAMP="$PORT_DIR/aot.stamp"
LOG="$PORT_DIR/log.aot.txt"

ESUDO=${ESUDO:-}

# Mono can abort on assemblies it cannot compile; a core file of the runtime
# would be hundreds of megabytes on the SD card.
ulimit -c 0 2>/dev/null || true

# The launcher treats the last "precompiled=" line of the log as the truth: a
# missing line or false means the next start tries again. The false marker is
# also written before the work starts, so an interrupted or crashed run is
# never mistaken for a finished one.
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

# A failing run prints the loader error for every method it cannot compile, so
# keep only the current attempt in the log and the previous one for reference.
if [ -f "$LOG" ]; then
	mv -f "$LOG" "$LOG.1" 2>/dev/null
fi

printf '\n=== %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
record_result false

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
	record_error "mono-missing:$monodir"
	say "ERROR: Mono runtime not found in $monodir/bin or PATH."
	say "Start the game once so PortMaster mounts it, then run this again."
	exit 1
fi

# PortMaster's Mono runtime carries the assembler and linker used by AOT next
# to bin/mono, and their support libraries (libbfd, libopcodes) in the sibling
# lib/ directory. That directory is not part of the default library search path,
# so as/ld would fail to start even when they are present; make both visible
# before looking for them. Resolve symlinks so the runtime root is right when
# mono is a link.
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
	# Last resort: a runtime that keeps its toolchain in a subdirectory.
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

# Mono runs the tools by name, so their directories have to come first, and
# their own support libraries are looked for next to them.
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

# The Windows build references XNA 4.0 (Microsoft.Xna.Framework*), which the
# port only substitutes at runtime: SVLoader relinks those references to
# MonoGame. AOT resolves references while compiling, so it needs assemblies with
# those names. Mono does not verify the assembly identity behind a file name
# (strict name checking is off by default), and MonoGame is version 0.0.0.0 and
# unsigned, so copies of MonoGame under the XNA names resolve every reference to
# exactly the code the game binds to at runtime - same types, same layouts.
# These copies are only in MONO_PATH while compiling; the game never sees them.
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

# Extra reference assemblies supplied by hand take precedence over the shims.
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

# The game assembly is the image that has to be there for AOT to be worth
# anything: if it compiled, the toolchain works and Mono picks the images up on
# the next start. Files that are not managed assemblies (steam_api.dll and
# friends) are skipped by design and do not count as a failure.
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
	# Deterministic: the game assembly references assemblies the port only
	# substitutes at runtime, so no amount of retrying produces its image.
	# The support assemblies are compiled, which is all this device can get.
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
