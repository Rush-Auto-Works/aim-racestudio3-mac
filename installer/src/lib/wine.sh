# lib/wine.sh — Wine process control. macOS has no GNU `timeout`, so we run a watchdog.
#
# Design rules baked in (from the reviewer debate):
#   - NO blanket `set -e` around Wine: it returns nonzero for benign diagnostics. Callers
#     check the real postcondition (a file exists, --version works), not $?.
#   - Every Wine invocation runs in its OWN process group under the watchdog, so a timeout
#     kills the whole job tree (round-3 resolution 14), not just the front process.
#   - WINEDLLOVERRIDES is exported as a variable (it contains ';' — never inline it).
#   - Env is redirected into the install root so no ~/.wine and minimal stray writes.

# watchdog <secs> <cmd...> : run cmd in a new process group; kill the group if it overruns.
# Returns the command's exit status, or 124 on timeout (mirrors GNU timeout).
watchdog() {
  local secs="$1"; shift
  # New process group via `set -m` in a subshell so we can signal the whole tree.
  set -m
  ( exec "$@" ) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      # kill the process group (negative pid)
      kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
      set +m
      return 124
    fi
    sleep 1; waited=$((waited+1))
  done
  wait "$pid"; local rc=$?
  set +m
  return "$rc"
}

# Export the Wine environment that every call shares. Requires PREFIX + WINE_BIN + INSTALL_ROOT.
wine_env_export() {
  export WINEPREFIX="$PREFIX"
  export WINEARCH="win64"
  export WINEDLLOVERRIDES="mscoree=d;mshtml=d"   # skip Mono/Gecko prompt+hang (RS3 is native+CEF)
  export WINEDEBUG="-all"
  export WINEPROFILE="$INSTALL_ROOT/wineprofile"
  export XDG_CACHE_HOME="$INSTALL_ROOT/cache"
  export XDG_CONFIG_HOME="$INSTALL_ROOT/xdg-config"
  export XDG_DATA_HOME="$INSTALL_ROOT/xdg-data"
  export TMPDIR_WINE="$INSTALL_ROOT/tmp"
  mkdir -p "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$TMPDIR_WINE"
}

# find_wine_binary <wine_root> : glob for the binary; never hardcode the bundle path
# (it changed across versions: `wine` vs `wine64`). Echoes the path, returns nonzero if absent.
find_wine_binary() {
  local root="$1" w
  w="$(find "$root" -type f \( -name wine -o -name wine64 \) -path '*/bin/*' 2>/dev/null | head -1)"
  [ -n "$w" ] && [ -x "$w" ] || return 1
  printf '%s' "$w"
}

# wineserver_path : the wineserver next to the wine binary (same bin dir).
wineserver_path() {
  local bindir; bindir="$(dirname "$WINE_BIN")"
  if [ -x "$bindir/wineserver" ]; then printf '%s' "$bindir/wineserver"; return 0; fi
  find "$WINE_ROOT" -type f -name wineserver -path '*/bin/*' 2>/dev/null | head -1
}

# wineserver_kill : tear down any Wine process holding OUR prefix, under the watchdog
# (wineserver -k can itself hang). Best-effort.
wineserver_kill() {
  local ws; ws="$(wineserver_path)" || return 0
  [ -n "$ws" ] || return 0
  WINEPREFIX="$PREFIX" watchdog 30 "$ws" -k 2>/dev/null || true
}

# wineserver_wait : block until wineserver finishes all pending work and exits. wineboot --init
# returns BEFORE the registry/drive_c are fully written (wineserver finishes async), so we must
# drain it before checking a prefix postcondition — otherwise the check races and false-fails.
wineserver_wait() {
  local ws; ws="$(wineserver_path)" || return 0
  [ -n "$ws" ] || return 0
  WINEPREFIX="$PREFIX" watchdog 180 "$ws" -w 2>/dev/null || true
}

# run_wine <args...> : run the Wine binary with array argv under the watchdog. Echoes nothing
# special; callers verify the postcondition. $1 of the env var RUN_WINE_TIMEOUT sets the limit.
run_wine() {
  : "${RUN_WINE_TIMEOUT:=600}"
  wine_env_export
  # arch -x86_64 forces the x86-64 slice (RS3 + this Wine are Intel; Rosetta translates).
  watchdog "$RUN_WINE_TIMEOUT" arch -x86_64 "$WINE_BIN" "$@"
}
