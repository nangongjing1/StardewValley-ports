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

# Grab text output...
$ESUDO chmod 666 /dev/tty0
printf "\033c" > /dev/tty0
echo "Loading... Please Wait." > /dev/tty0

# ---------------------------------------------------------------------------
# Performance tuning.
#
# Every value can be overridden from the environment; see the "Performance"
# section of stardewvalley.md for the reasoning and for optional, more
# aggressive settings.
# ---------------------------------------------------------------------------

# Mono's SGen GC. The default nursery is 4m: a larger one means fewer
# collections while walking around. Optional extra (see stardewvalley.md):
# append ",minor=simple-par" to spread each collection over several cores.
export MONO_GC_PARAMS="${MONO_GC_PARAMS:-nursery-size=8m}"

# gl4es: recycle framebuffer objects instead of reallocating them, and skip
# the startup banner.
export LIBGL_RECYCLEFBO="${LIBGL_RECYCLEFBO:-1}"
export LIBGL_NOBANNER="${LIBGL_NOBANNER:-1}"

# glibc: one malloc arena per thread fragments the heap on these devices.
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

# OpenAL Soft: this port uses ALSA. Naming the driver skips probing (and
# waiting on) the PipeWire/PulseAudio backends that are not running here.
export ALSOFT_DRIVERS="${ALSOFT_DRIVERS:-alsa}"

# Automatic AOT warm-up of the game assemblies, see optimize.sh. It runs on
# the first start and then only again while the last attempt has failed; set
# SDV_AUTO_AOT=0 to skip it.
SDV_AUTO_AOT="${SDV_AUTO_AOT:-1}"

# Setup mono
monodir="$HOME/mono"
monofile="$controlfolder/libs/mono-6.12.0.122-aarch64.squashfs"
$ESUDO mkdir -p "$monodir"
$ESUDO umount "$monofile" || true
$ESUDO mount "$monofile" "$monodir"

# Setup savedir
bind_directories ~/.config/StardewValley "$gamedir/savedata"

# Setup path and other environment variables
export MONOGAME_PATCH="$gamedir/dlls/StardewPatches.dll"
export MONO_PATH="$gamedir/dlls":"$gamedir"
export PATH="$monodir/bin":"$PATH"
export LD_LIBRARY_PATH="$gamedir/libs:$LD_LIBRARY_PATH"

# Delete older GL4ES installs...
rm -f $gamedir/libs/libGL.so.1 $gamedir/libs/libEGL.so.1

# Request libGL from Portmaster
if [ -f "${controlfolder}/libgl_${CFW_NAME}.txt" ]; then
  source "${controlfolder}/libgl_${CFW_NAME}.txt"
else
  source "${controlfolder}/libgl_default.txt"
fi

if [[ "$LIBGL_ES" != "" ]]; then
	export SDL_VIDEO_GL_DRIVER="${gamedir}/gl4es/libGL.so.1"
	export SDL_VIDEO_EGL_DRIVER="${gamedir}/gl4es/libEGL.so.1"
fi

# Jump into the gamedata dir now
cd "$gamedir/gamedata"

# Fix for the Linux builds, use mono-provided libraries instead.
# Exception for the System.Data.* assemblies, since Stardew needs
# xxHash types we would otherwise not provide.
if compgen -G "System.Data*.dll" > /dev/null; then
	mv System.Data*.dll "$gamedir/dlls"
fi
rm -f MonoGame.Framework.* System*.dll

# Check if it's the Windows or Linux version
if [[ -f "Stardew Valley.exe" ]]; then
	gameassembly="Stardew Valley.exe"

	# Copy the Windows Stardew Valley WinAPI workarounds
	if ! cmp -s "${gamedir}/dlls/Stardew Valley.exe.config" "Stardew Valley.exe.config"; then
		cp "${gamedir}/dlls/Stardew Valley.exe.config" "Stardew Valley.exe.config"
	fi
else
	gameassembly="StardewValley.exe"
fi

# AOT compiling the game assemblies on the device removes most of the JIT work
# from startup and from the first minutes of play. optimize.sh builds the
# images and this launcher runs it before the game when needed.
#
# log.aot.txt is both the progress log and the state:
#   * the last "precompiled=" line is the verdict of the last attempt: false is
#     written before any work starts - so a crash or a power loss is retried -
#     true once the game assembly has a usable image, and partial when only the
#     support assemblies could be precompiled because the game assembly needs
#     references that the port substitutes at runtime (see aot-shims/);
#   * no such line at all means the precompilation never ran.
# optimize.sh and this launcher append their steps with a timestamp, so a failed
# start can be diagnosed without a console.
aotlog="$gamedir/log.aot.txt"
aotimage="$gamedir/gamedata/$gameassembly.so"

# Last value of a "key=value" line in the precompile log; empty when there is none.
aot_last() {
	[ -f "$aotlog" ] || return 0
	awk -v key="$1" 'index($0, key "=") == 1 { v = substr($0, length(key) + 2) } END { print v }' "$aotlog" 2>/dev/null
}

# Append a line, first terminating a line that was cut short by a crash.
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

# Files copied from a PC can carry timestamps in the future once the SD card is
# read with a different timezone, which made every start look stale. Compare a
# fingerprint of the inputs (sizes, which change with every game or port update)
# instead of modification times.
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

# Images built from a different runtime or from other game files cannot be
# reused, so a changed fingerprint also forces a rebuild. Without a recorded
# fingerprint (older log) the current state is adopted as is.
aot_stale=0
if [ -n "$aot_fp_logged" ] && [ "$aot_fp" != "$aot_fp_logged" ]; then
	aot_stale=1
fi

# Precompile only when the previous attempt did not succeed (never ran, was
# interrupted, or failed) or when the images no longer match the game files.
# "partial" means the support assemblies are precompiled while the game assembly
# cannot be: it references assemblies the port only substitutes at runtime, so a
# rerun would repeat exactly the same work.
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

	# Record the attempt as unfinished before touching anything: if it is
	# interrupted here, the next start enters the precompile flow again.
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
			# Keep the last verdict at false so the next start retries.
			[ "$aot_state" = "false" ] || aot_append "precompiled=false"
			aot_log "precompile: failed (exit=$aot_rc last=${aot_state:-none})"
			aot_log "aot_error=launcher:optimize-exit-$aot_rc"
			echo "Precompilation failed, see log.aot.txt. Starting the game..." > /dev/tty0
		fi
	fi
fi

# Adopt the current inputs when skipping: a log written before fingerprints
# existed must not trigger a rebuild just because the value is missing.
if [ "$aot_needed" = "0" ] && [ -z "$aot_fp_logged" ]; then
	aot_append "fingerprint=$aot_fp"
fi

aot_result=$(aot_last precompiled)
[ -n "$aot_result" ] || aot_result=none

# Memory curve sampling: SDV_MEMLOG=1 writes log.mem.txt next to log.txt
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
			awk -v t="$(date +%s)" '/^VmRSS:/ { print t, $2 }' "/proc/$pid/status" 2>/dev/null >> "$memlog"
			sleep 5
		done
	) &
}

log="${gamedir}/log.txt"
start_ts=$(date +%s)
{
	echo "=== Stardew Valley port $(date '+%Y-%m-%d %H:%M:%S') ==="
	echo "tuning: MONO_GC_PARAMS=${MONO_GC_PARAMS} MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX}"
	echo "tuning: LIBGL_RECYCLEFBO=${LIBGL_RECYCLEFBO} ALSOFT_DRIVERS=${ALSOFT_DRIVERS}"
	echo "aot: precompiled=$aot_result stale=$aot_stale images=$(ls -1 "$gamedir/gamedata/"*.so 2>/dev/null | wc -l)"
	echo "--- game output ---"
} > "$log"

if [ -n "${SDV_MEMLOG:-}" ] && command -v pgrep > /dev/null 2>&1; then
	start_memlog
fi

$GPTOKEYB "mono" &
$TASKSET mono ../SVLoader.exe "${gameassembly}" 2>&1 | tee -a "$log"
echo "--- session length: $(( $(date +%s) - start_ts ))s ---" >> "$log"
$ESUDO kill -9 $(pidof gptokeyb)
$ESUDO systemctl restart oga_events &
$ESUDO umount "$monodir"

# Disable console
printf "\033c" >> /dev/tty1
