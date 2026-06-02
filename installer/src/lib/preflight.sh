# lib/preflight.sh — environment checks that must pass before any Wine call.

# macos_ok : require macOS (Darwin). Returns 0/1.
macos_ok() { [ "$(uname -s)" = "Darwin" ]; }

# is_apple_silicon : true on arm64.
is_apple_silicon() { [ "$(uname -m)" = "arm64" ]; }

# rosetta_present : x86-64 binaries can run. On Intel this is trivially true.
rosetta_present() {
  is_apple_silicon || return 0
  arch -x86_64 /usr/bin/true 2>/dev/null
}

# rosetta_install_cmd : the command an admin must run. We don't run it here (the applet runs it
# `with administrator privileges`); CLI mode runs it directly if interactive.
rosetta_install_cli() {
  ui_say "Installing Rosetta 2 (Apple's Intel translation layer) — you may be asked for your password."
  softwareupdate --install-rosetta --agree-to-license
}

# disk_free_gb <path> : integer GB free on the volume holding <path> (nearest existing ancestor).
disk_free_gb() {
  local p="$1"; while [ ! -e "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  local kb; kb="$(df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}')"
  [ -n "$kb" ] && echo $(( kb / 1024 / 1024 )) || echo 0
}

# enough_disk : MIN_FREE_GB on the Application Support volume.
enough_disk() {
  local g; g="$(disk_free_gb "$APP_SUPPORT")"
  [ "$g" -ge "$MIN_FREE_GB" ] 2>/dev/null
}

# ---- already-running guard (round-3 res 15: mandatory PID file, anchored to OUR prefix) -----

PIDFILE_path() { echo "$STATE_DIR/wineserver.pid"; }

# write_wineserver_pid : record OUR wineserver PID at prefix creation so we can detect a live
# instance later without trying to read another process's WINEPREFIX (macOS can't).
write_wineserver_pid() {
  local ws pid
  ws="$(wineserver_path)" || return 0
  [ -n "$ws" ] || return 0
  # Find a running wineserver whose argv/cwd is our prefix is unreliable; instead we record the
  # pid right after we start one. Callers invoke this immediately post-wineboot.
  pid="$(pgrep -f "$ws" | head -1)"
  [ -n "$pid" ] && echo "$pid" > "$(PIDFILE_path)" || true
}

# rs3_already_running : true only if OUR RS3/wineserver is live. Anchored to our prefix path so a
# migrating user's RS3 inside a Parallels VM never false-triggers.
rs3_already_running() {
  # (1) our recorded wineserver pid still alive?
  local pf; pf="$(PIDFILE_path)"
  if [ -f "$pf" ]; then
    local p; p="$(cat "$pf" 2>/dev/null)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
    rm -f "$pf"   # stale
  fi
  # (2) an AiMRS3-64 process whose command line references OUR prefix path.
  pgrep -f "$PREFIX" 2>/dev/null | while read -r _; do :; done
  if pgrep -f "AiMRS3-64" >/dev/null 2>&1; then
    # only count it if its open files include our prefix (best-effort; never fatal if lsof slow)
    local pids; pids="$(pgrep -f 'AiMRS3-64' 2>/dev/null)"
    for p in $pids; do
      if lsof -p "$p" 2>/dev/null | grep -q "$PREFIX"; then return 0; fi
    done
  fi
  return 1
}

# ---- iCloud Desktop & Documents sync detection (WARN + OFFER only, never destructive) -------

# icloud_documents_synced : best-effort detection that ~/Documents is managed by iCloud
# Desktop & Documents sync. Detection only WARNS; it never drives a destructive action.
icloud_documents_synced() {
  # The synced Documents are exposed under Mobile Documents when the feature is on.
  [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] || return 1
  # If the real Documents path is a symlink/managed location, or brctl reports it, treat as synced.
  if /usr/bin/brctl status 2>/dev/null | grep -qi 'desktop'; then return 0; fi
  # Heuristic: a .com.apple.mobile_container_manager or the iCloud Documents shadow exists.
  [ -e "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents" ]
}
