#!/bin/bash
# rs3-engine.sh — runs RaceStudio 3 under the bundled Wine. Lives in the nested helper app
# RaceStudio 3.app/Contents/Helpers/RaceStudio 3.app/Contents/Resources/ and is exec'd by that
# helper's executable (rs3-engine.swift). The launcher applet starts the helper with `open`.
#
# Why a helper app instead of the applet running wine itself: on macOS 27, LaunchServices counts
# every GUI process the applet spawns as its "subordinate". When the applet quits, loginwindow asks
# Background Task Management, gets "not allowed to run in background", and kills the subordinates
# that are hidden (explorer.exe and friends). wineserver goes down with explorer.exe and RS3's
# window freezes with no server behind it. Launched via `open`, Wine is its own app in its own
# coalition, so nothing is killed when the applet quits. Verified on device 2026-09-23.
#
# LaunchServices starts apps with launchd's environment, not the applet's, so everything Wine needs
# is set here. The pre-launch hygiene (stale wineserver, DLL refresh, z: drive, VLC vouts) stays in
# the applet, which runs it before the `open`.
RES="$(cd "$(dirname "$0")/../../../.." && pwd)/Resources"   # the OUTER app's Contents/Resources
ROOT="$HOME/Library/Application Support/RaceStudio3"
export WINEPREFIX="$ROOT/prefix" WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"
export XDG_CACHE_HOME="$ROOT/cache" XDG_CONFIG_HOME="$ROOT/xdg-config" XDG_DATA_HOME="$ROOT/xdg-data"
mkdir -p "$ROOT/logs"
# exec, not background: this process becomes RS3, so the helper app lives exactly as long as RS3.
# --disable-gpu-compositing: CEF web maps render white under Wine without it (issue #37).
exec /usr/bin/arch -x86_64 "$RES/wine/bin/wine" 'C:\AIM_SPORT\RaceStudio3\64\AiMRS3-64-ReleaseU.exe' --disable-gpu-compositing >> "$ROOT/logs/run.log" 2>&1
