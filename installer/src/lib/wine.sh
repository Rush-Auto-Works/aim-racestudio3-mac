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

# write_macdrv_reg <out> : emit a REGEDIT4 file that sets the winemac.drv "native keyboard feel"
# keys under HKCU\Software\Wine\Mac Driver. Mapping BOTH Command keys to Windows Ctrl makes
# Cmd-C/V/X/A/Z behave the way a Mac user expects inside the Windows app; LeftOptionIsAlt keeps a
# usable Alt key (Wine warns that mapping both Command keys to Ctrl otherwise leaves no way to send
# Alt), while the RIGHT Option key is left unmapped so it still types special characters. AppKit
# owns Cmd-Tab / Cmd-M / the native Cmd-Opt-Q Quit and intercepts them before Wine sees the keys,
# so those are unaffected. These value names shipped since Wine 4.0 (dev release 3.17). Pure: writes
# the file and nothing else, so it is unit-testable without a real Wine prefix.
write_macdrv_reg() {
  local out="$1"
  printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n"LeftCommandIsCtrl"="y"\r\n"RightCommandIsCtrl"="y"\r\n"LeftOptionIsAlt"="y"\r\n' > "$out"
}

# apply_macdrv_keys : write the native-feel reg file into the prefix and import it with regedit.
# Best-effort (keyboard feel only, never touches data) — callers don't gate on $?. Requires PREFIX
# + WINE_BIN to be set, so it runs inside make-prefix after the prefix exists.
apply_macdrv_keys() {
  local reg="$PREFIX/drive_c/windows/temp/native-feel.reg"
  mkdir -p "$(dirname "$reg")" 2>/dev/null || true
  write_macdrv_reg "$reg"
  RUN_WINE_TIMEOUT="${WINEBOOT_TIMEOUT:-120}" run_wine regedit /S 'C:\windows\temp\native-feel.reg' \
    >> "${LOG:-/dev/null}" 2>&1 || true
  wineserver_wait
}

# drop_host_root_drive <prefix> : delete Wine's default `z: -> /` drive mapping.
#
# Z: exposes the ENTIRE Mac filesystem as a fixed disk, and RaceStudio 3 recursively walks every
# fixed drive after a configuration clone or import. Any directory-symlink cycle anywhere on the
# Mac traps that walk forever — RS3 has no depth cap, so the path grows without bound until it
# passes macOS's PATH_MAX (1024), after which every syscall returns ENAMETOOLONG. Wine maps that
# errno in neither server/file.c::file_set_error() nor ntdll's errno_to_status(), so both fall
# through to STATUS_UNSUCCESSFUL and RS3 just retries; the visible symptoms are a hung app and
# wineserver spamming "file_set_error() can't map error: File name too long" into run.log.
# Such cycles are ordinary in third-party bundles: the reported case (issue #32) was
# /Applications/calibre.app, whose QtWebEngineCore.framework helper app links back up to
# calibre.app/Contents/Frameworks, and macOS ships another via /Volumes/Macintosh HD -> /.
#
# Nothing the user needs disappears. Home folders are already mounted inside the prefix as
# C:\users\<user>\{Desktop,Documents,Downloads,Music,Pictures,Videos} (drive_c symlinks pointing at
# the real ones), and external volumes each get their own letter, so export to the host still
# works. Only browsing arbitrary system paths from RS3's file picker goes away.
#
# Narrowing Z: instead of removing it does NOT work: every host-wide mount point reintroduces a
# cycle (/Volumes contains "Macintosh HD" -> /; ~/Movies and ~/Pictures hold iMovie libraries whose
# .fcpcache links loop back). Re-typing the drive does not work either — verified on device
# 2026-07-31 that RS3 still walks Z: when it is registered as "network" in Software\Wine\Drives.
#
# Only removes the link when it actually resolves to "/". A prefix where someone deliberately
# pointed z: at, say, an external drive is left alone — that mapping is useful and is not the bug.
#
# Pure filesystem and idempotent (no Wine required), so the launchers re-run it on every start.
# That repeat is what migrates an already-installed prefix (the user does not reinstall to get the
# fix), and it is cheap insurance if anything ever re-adds a root mapping: mountmgr creates
# dosdevices entries for volumes it discovers at runtime (that is where d:/e:/f: come from).
# Note it is NOT wineboot that creates these — programs/wineboot/wineboot.c in the pinned Wine 11.9
# contains no drive-symlink code at all, so do not justify the repeat by claiming otherwise.
#
# Returns nonzero if a root-mapped z: was found and could NOT be removed, so an installer caller can
# report it. The launchers deliberately ignore the status: a prefix we cannot write is not a reason
# to refuse to start RS3.
drop_host_root_drive() {
  local prefix="$1" link="$1/dosdevices/z:"
  [ -n "$prefix" ] || return 0
  [ -L "$link" ] || return 0
  [ "$(readlink "$link")" = "/" ] || return 0     # deliberate non-root mapping: leave it
  rm -f "$link" "$prefix/dosdevices/z::" 2>/dev/null
  [ ! -L "$link" ]
}

# _ver_fields <ver> : print a version's numeric fields, space-separated. Accepts every shape this
# repo ships: "3.83.39" (pins.env), "3.83.26.0" (RaceStudio3.xmv), "v3.83.39-1" (release tag,
# build-apps.sh:44) and "3.83.39.1" (CFBundleVersion, build-apps.sh:295). The tag's "-<rev>" and
# the bundle's ".<rev>" are the same field, so both collapse to a separator.
_ver_fields() {
  local v="${1#v}"
  printf '%s' "${v//-/.}" | tr '.' ' '
}

# ver_cmp <a> <b> : print lt | eq | gt. Missing trailing fields count as zero, so 3.83.39 and
# 3.83.39.0 are equal. Returns 1 printing NOTHING when either side has a non-numeric field, so a
# caller can tell "older" apart from "unparseable" and refuse to guess.
ver_cmp() {
  local -a A B
  A=($(_ver_fields "$1")); B=($(_ver_fields "$2"))
  local n="${#A[@]}" i x y
  [ "${#B[@]}" -gt "$n" ] && n="${#B[@]}"
  [ "$n" -gt 0 ] || return 1
  for (( i = 0; i < n; i++ )); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    case "$x$y" in ''|*[!0-9]*) return 1 ;; esac
    x=$((10#$x)); y=$((10#$y))          # base-10: "08" is not octal here
    if [ "$x" -gt "$y" ]; then printf 'gt'; return 0; fi
    if [ "$x" -lt "$y" ]; then printf 'lt'; return 0; fi
  done
  printf 'eq'
}

# rs3_installed_ver [xmv_path] : print the RaceStudio 3 version AiM's installer recorded in its
# own manifest (default: the one inside our prefix). That file is the source of truth because AiM
# writes it — a marker of ours would go stale the moment RS3's in-app updater ran.
#
# The manifest is CRLF; the capture stops at '<' so the \r never reaches the value. Returns 1
# printing nothing when the file is absent, the tag is absent, or the value isn't a plausible
# version — callers must treat that as "unknown", never as "up to date".
rs3_installed_ver() {
  local xmv="${1:-$PREFIX/drive_c/$RS3_REL_XMV}" v
  [ -f "$xmv" ] || return 1
  v="$(sed -nE 's|.*<p n="VERSION">([^<]*)</p>.*|\1|p' "$xmv" 2>/dev/null | head -1)"
  [ -n "$v" ] || return 1
  printf '%s' "$v" | grep -Eq '^[0-9]+(\.[0-9]+){2,3}$' || return 1
  printf '%s' "$v"
}

# rs3_installed_at_least <want> : true when the installed RaceStudio 3 is >= <want>.
#
# ">=" and not "==" on purpose. If RS3's in-app updater has moved the user to 3.84.0 and our pin
# still says 3.83.39, equality would call the install unsatisfied and reinstall the older build
# over the newer one. ledger_skip_if_done returns a boolean, so it has no way to express "newer
# than expected" — ">=" is what makes "never downgrade a user automatically" actually true.
rs3_installed_at_least() {
  local have; have="$(rs3_installed_ver)" || return 1
  case "$(ver_cmp "$have" "$1")" in
    eq|gt) return 0 ;;
    *)     return 1 ;;
  esac
}
