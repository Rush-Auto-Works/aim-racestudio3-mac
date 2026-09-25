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
# Every launch appends to run.log. Past 10 MB, keep it as run.log.1 and start fresh, so a crash
# log survives one relaunch without growing forever (one +winsock debug session made it 234 MB).
[ "$(stat -f %z "$ROOT/logs/run.log" 2>/dev/null || echo 0)" -gt 10485760 ] && mv -f "$ROOT/logs/run.log" "$ROOT/logs/run.log.1"
# Foreground wait, not exec: on a clean quit wine reaps its own services. But on 2026-09-24,
# after this session was closed, RS3 and wineserver were both gone while Wine's services
# (services.exe, winedevice.exe, explorer.exe) had survived as reparented orphans (ppid 1).
# The log captured the aftermath, not the killer. Orphans keep this app's LaunchServices
# record alive and render in the Dock as "RaceStudio 3 — Running in Background". Since the
# helper outlives wine, it can tear them down.
# --disable-gpu-compositing: CEF web maps render white under Wine without it (issue #37).
/usr/bin/arch -x86_64 "$RES/wine/bin/wine" 'C:\AIM_SPORT\RaceStudio3\64\AiMRS3-64-ReleaseU.exe' --disable-gpu-compositing >> "$ROOT/logs/run.log" 2>&1
rc=$?
# Pass 1: a live wineserver reaps all of its clients in one shot (fast, exact). macOS ships no
# GNU timeout; bound it with a background killer instead (mirrors lib/wine.sh's watchdog intent).
if [ -x "$RES/wine/bin/wineserver" ]; then
    WINEPREFIX="$WINEPREFIX" "$RES/wine/bin/wineserver" -k >/dev/null 2>&1 &
    kpid=$!
    ( sleep 10; kill -9 "$kpid" 2>/dev/null ) & wp=$!
    wait "$kpid" 2>/dev/null || true
    kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
fi
# Pass 2 (orphans whose wineserver died with the session): ps shows these clients with rewritten
# argv ("C:\windows\system32\winedevice.exe", bundle path invisible), so scope by argv shape
# FIRST, then confirm the process really is ours via its text mappings into the bundle's wine
# tree. Both must hit; never a bare pkill. SIGKILL is required: an orphaned Wine service ignores
# SIGTERM (proven on device 2026-09-25, winedevice.exe survived plain kill for minutes). PPID
# must be 1, and no RS3 process may be alive: Wine's services also show PPID 1 during a live
# session, so the ordering (wine already returned) plus this guard is what keeps a running
# session safe. Retried a few times because one pass can race a late-spawned service.
# Verified on device 2026-09-25 (scratch bundle + forced quit): every orphan of this bundle died.
# The guard pattern is the full exe name on purpose: a bare "AiMRS3-64" also matches the
# launcher applet's own hygiene shell, which would silently suppress this sweep.
if ! pgrep -f 'AiMRS3-64-ReleaseU' >/dev/null 2>&1; then
    for _ in 1 2 3 4 5; do
        left=0
        for pid in $(ps -axww -o pid=,ppid=,args= | awk '$2 == 1 && $3 ~ /^C:\\/ {print $1}'); do
            if lsof -p "$pid" 2>/dev/null | grep -qF "$RES/wine/"; then
                kill -9 "$pid" 2>/dev/null && left=1
            fi
        done
        [ "$left" = 0 ] && break
        sleep 1
    done
fi
exit "$rc"
