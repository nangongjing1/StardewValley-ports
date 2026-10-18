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

# One-time AOT warm-up of the game assemblies, see optimize.sh. It only runs
# while no aot.stamp exists; set SDV_AUTO_AOT=0 to skip it.
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
# from startup and from the first minutes of play. One-time, and only tried once.
if [ "$SDV_AUTO_AOT" = "1" ] && [ ! -f "$gamedir/aot.stamp" ] && [ -f "$gamedir/optimize.sh" ]; then
	echo "Optimizing game files, one time only..." > /dev/tty0
	echo "This can take several minutes, please do not power off." > /dev/tty0
	bash "$gamedir/optimize.sh" >> "$gamedir/log.aot.txt" 2>&1
fi

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
	echo "aot: $(ls -1 "$gamedir/gamedata/"*.so 2>/dev/null | wc -l) AOT images in gamedata"
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
