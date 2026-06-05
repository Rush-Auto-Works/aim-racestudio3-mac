#!/bin/bash
# installer-core.sh — the robust engine behind the friendly .app. All real logic lives here so
# it is independently runnable and testable WITHOUT the GUI:
#
#   installer-core.sh run            # full interactive install (CLI)
#   installer-core.sh <phase>        # one phase (the applet calls these; non-interactive)
#   installer-core.sh --dry-run run  # validate logic; NO network, NO writes outside sandbox
#   installer-core.sh --repair       # re-run from the first failed postcondition
#   installer-core.sh --reinstall    # wipe engine+prefix (never Documents data w/o confirm)
#   installer-core.sh --import <dir> # merge an external user/ folder into the data dir
#   installer-core.sh uninstall      # remove engine + launchers (data kept unless confirmed)
#
# Phases (the 8 progress steps): preflight acquire-installer download-wine make-prefix
#                                silent-install relocate-data make-launcher done
#
# Safety: targeted (NOT blanket set -e around Wine). set -u + pipefail; a single EXIT trap
# surfaces errors; every Wine call is wrapped and checked by postcondition, not $?.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "$HERE/pins.env"
for m in ui net wine ledger data preflight; do . "$HERE/lib/$m.sh"; done

# ---- overridable locations (env overrides let the dry-run test sandbox everything) ----------
[ -n "${RS3_APP_SUPPORT:-}" ] && APP_SUPPORT="$RS3_APP_SUPPORT"
[ -n "${RS3_APPS_DIR:-}" ] && APPS_DIR="$RS3_APPS_DIR"
# Default (pins.env) is /Applications/AiM. If that system folder isn't writable (non-admin account)
# and doesn't already exist, fall back to the always-writable per-user ~/Applications. No side
# effects — make_launcher creates the dir later. Tests/dry-run set RS3_APPS_DIR, which wins.
if [ -z "${RS3_APPS_DIR:-}" ] && [ "$APPS_DIR" = "/Applications/AiM" ] && [ ! -d "$APPS_DIR" ] && [ ! -w "/Applications" ]; then
  APPS_DIR="$HOME/Applications/AiM"
fi
LAUNCHER_APP="$APPS_DIR/RaceStudio 3.app"
UNINSTALL_APP="$APPS_DIR/Uninstall RaceStudio 3.app"
IMPORT_APP="$APPS_DIR/Import RaceStudio 3 Data.app"
INSTALL_ROOT="$APP_SUPPORT"
WINE_ROOT="$INSTALL_ROOT/wine"
PREFIX="$INSTALL_ROOT/prefix"
STATE_DIR="$INSTALL_ROOT/state"
LOG_DIR="$INSTALL_ROOT/logs"
INSTALLER_CACHE="$INSTALL_ROOT/installer"
CONFIG_ENV="$STATE_DIR/config.env"
LOG="$LOG_DIR/install.log"

DATA_DIR="${RS3_DATA_DIR:-$DATA_DIR_DEFAULT}"

# ---- flags ---------------------------------------------------------------------------------
DRY_RUN=0; USE_LATEST=0; SMOKE_TEST=0; ACTION=""; IMPORT_DIR=""
: "${UI_MODE:=cli}"
LAST_ERROR=""

args=()
while [ $# -gt 0 ]; do case "$1" in
  --dry-run)   DRY_RUN=1; UI_MODE=dryrun; shift;;
  --latest)    USE_LATEST=1; shift;;
  --smoke-test) SMOKE_TEST=1; shift;;
  --repair)    ACTION="repair"; shift;;
  --reinstall) ACTION="reinstall"; shift;;
  --import)    ACTION="import"; IMPORT_DIR="${2:-}"; shift 2;;
  --help|-h)   ACTION="help"; shift;;
  -* ) ui_warn "unknown flag: $1"; shift;;
  * )  args+=("$1"); shift;;
esac; done
[ "${#args[@]}" -gt 0 ] && [ -z "$ACTION" ] && ACTION="${args[0]}"
[ -z "$ACTION" ] && ACTION="run"

export UI_MODE

# ---- bootstrap dirs + logging (dry-run still writes only inside the sandboxed APP_SUPPORT) ---
mkdir -p "$STATE_DIR" "$LOG_DIR" "$INSTALLER_CACHE" 2>/dev/null || true
# recall persisted decisions (DATA_DIR may have been chosen in a prior phase)
[ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" || true

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }
die() { ui_error "$1"; log "FATAL: $1"; exit 1; }

# resolve the Wine binary if present (don't trust a stale path)
WINE_BIN=""; if [ -d "$WINE_ROOT" ]; then WINE_BIN="$(find_wine_binary "$WINE_ROOT" || true)"; fi
# Bundled-Wine mode: the app passes RS3_WINE_BIN pointing at Wine inside its own bundle.
if [ -n "${RS3_WINE_BIN:-}" ] && [ -x "${RS3_WINE_BIN}" ]; then
  WINE_BIN="$RS3_WINE_BIN"
  WINE_ROOT="$(cd "$(dirname "$RS3_WINE_BIN")/.." && pwd)"
fi

# single EXIT trap (no ERR — Wine's benign nonzero exits would double-fire it)
cleanup() {
  local rc=$?
  # reap any stray watchdog children of our group; best-effort
  jobs -p 2>/dev/null | while read -r j; do kill "$j" 2>/dev/null || true; done
  if [ "$rc" -ne 0 ] && [ "$rc" -ne "$SIG_NEEDS" ] && [ "$rc" -ne 11 ]; then
    [ -n "$LAST_ERROR" ] || ui_error "Install stopped (code $rc). See log: $LOG"
    log "exit rc=$rc"
  fi
}
trap cleanup EXIT

# ============================================================================================
# PHASES
# ============================================================================================

phase_preflight() {
  ui_progress 1 8 "Checking your Mac…"
  macos_ok || die "This installer is for macOS."

  # Rosetta (Apple Silicon only)
  if ! rosetta_present; then
    if [ "$DRY_RUN" = 1 ]; then
      ui_say "[dry-run] would install Rosetta 2 (Apple Intel translation)."
    elif [ "$UI_MODE" = applet ]; then
      printf 'NEEDS_ROSETTA\n'; exit 11          # applet runs the admin install, re-invokes
    else
      rosetta_install_cli || die "Rosetta 2 is required. An admin can run: softwareupdate --install-rosetta"
      rosetta_present || die "Rosetta 2 still not available after install."
    fi
  fi
  ledger_mark rosetta

  # Disk
  if [ "$DRY_RUN" != 1 ]; then
    enough_disk || die "Not enough free disk space — RaceStudio 3 needs about ${MIN_FREE_GB} GB free."
  else
    ui_say "[dry-run] disk free on $(dirname "$APP_SUPPORT"): $(disk_free_gb "$APP_SUPPORT") GB (need ${MIN_FREE_GB})."
  fi

  # Already running?
  if [ "$DRY_RUN" != 1 ] && rs3_already_running; then
    die "RaceStudio 3 is already running. Please quit it, then run the installer again."
  fi

  # iCloud Desktop & Documents sync -> WARN + offer a non-synced location (never destructive).
  if [ "$DRY_RUN" != 1 ] && icloud_documents_synced && [ "${DATA_DIR#"$HOME/Documents"}" != "$DATA_DIR" ]; then
    ui_choice icloud_location "$DATA_DIR" \
      "Your Documents folder syncs to iCloud. iCloud can move your telemetry off this Mac to save space, which can break the live database. Where should RaceStudio 3 keep its data?" \
      "$DATA_DIR" "$DATA_DIR_NONSYNCED"
    DATA_DIR="$CHOICE_RESULT"
  fi
  ui_persist DATA_DIR "$DATA_DIR"
  log "preflight ok; DATA_DIR=$DATA_DIR"
}

phase_acquire_installer() {
  ui_progress 2 8 "Getting the RaceStudio 3 installer…"
  # Already have a usable installer (verified earlier, or one the user picked via the GUI)?
  local pre; pre="$(ui_recall INSTALLER_EXE || true)"
  if [ -n "$pre" ] && [ -f "$pre" ] && [ "$DRY_RUN" != 1 ]; then ui_say "Installer ready."; return 0; fi
  local want="$INSTALLER_CACHE/$RS3_PINNED_FILE"
  validate_rs3_asset "$RS3_PINNED_FILE" || die "internal: bad pinned RS3 filename"

  if [ "$DRY_RUN" = 1 ]; then
    https_guard "$RS3_PINNED_URL" || die "RS3 URL not HTTPS"
    ui_say "[dry-run] would fetch $RS3_PINNED_FILE (${RS3_PINNED_SIZE} bytes) or use ~/Downloads."
    ui_persist INSTALLER_EXE "$want"; return 0
  fi

  if download_verified "$RS3_PINNED_URL" "$want" "$RS3_PINNED_SIZE" "$RS3_PINNED_SHA256" "$RS3_DOWNLOAD_TIMEOUT"; then
    ui_persist INSTALLER_EXE "$want"; return 0
  fi

  # Fallback 1: the pinned URL path can go stale even when the file is unchanged — AiM moves the
  # installer between directories without renaming it (this exact 404 hit a customer). Re-resolve
  # the live URL for the SAME filename off the download page and retry. Still size+sha verified,
  # so a different build can't sneak in.
  local real_url; real_url="$(rs3_url_from_page "$RS3_DOWNLOAD_PAGE" "$RS3_PINNED_FILE" 2>/dev/null || true)"
  if [ -n "$real_url" ] && [ "$real_url" != "$RS3_PINNED_URL" ]; then
    ui_say "Pinned link was stale; using AiM's current link."
    if download_verified "$real_url" "$want" "$RS3_PINNED_SIZE" "$RS3_PINNED_SHA256" "$RS3_DOWNLOAD_TIMEOUT"; then
      ui_persist INSTALLER_EXE "$want"; return 0
    fi
  fi

  # Fallback 2: a matching file already in ~/Downloads (size match preferred).
  local d
  for d in "$HOME/Downloads"/RaceStudio3-64_*.exe; do
    [ -e "$d" ] || continue
    if [ "$(file_size "$d")" = "$RS3_PINNED_SIZE" ]; then
      ditto "$d" "$want"; ui_persist INSTALLER_EXE "$want"
      ui_say "Using the installer you already have in Downloads."
      return 0
    fi
  done

  # Fallback 3: ask the user to download it from AiM, then re-detect.
  if [ "$UI_MODE" = applet ]; then
    printf 'NEEDS_INSTALLER\n'; exit "$SIG_NEEDS"
  fi
  ui_say "Couldn't download automatically. Opening the AiM download page — save the file to Downloads, then re-run."
  open "$RS3_DOWNLOAD_PAGE" 2>/dev/null || true
  die "RaceStudio 3 installer not available yet."
}

phase_download_wine() {
  ui_progress 3 8 "Downloading the engine (Wine ${WINE_PINNED_VER})…"
  # Bundled-Wine mode: the engine ships inside the app — nothing to download.
  if [ -n "${RS3_WINE_BIN:-}" ] && [ -x "${RS3_WINE_BIN}" ]; then
    ui_say "Engine is bundled with the app."; ledger_mark wine; return 0
  fi
  if ledger_skip_if_done wine; then ui_say "Engine already installed."; return 0; fi

  local asset; asset="$(basename "$WINE_PINNED_URL")"
  validate_wine_asset "$asset" || die "internal: bad pinned Wine asset name"

  if [ "$DRY_RUN" = 1 ]; then
    https_guard "$WINE_PINNED_URL" || die "Wine URL not HTTPS"
    ui_say "[dry-run] would fetch + extract $asset (${WINE_PINNED_SIZE} bytes), then glob for bin/wine."
    return 0
  fi

  local tarball="$INSTALLER_CACHE/$asset"
  download_verified "$WINE_PINNED_URL" "$tarball" "$WINE_PINNED_SIZE" "$WINE_PINNED_SHA256" "$WINE_DOWNLOAD_TIMEOUT" \
    || die "Couldn't download Wine. Check your internet connection and try again."

  mkdir -p "$WINE_ROOT"
  watchdog 600 tar -xJf "$tarball" -C "$WINE_ROOT" || die "Couldn't unpack Wine."
  # quarantine removal scoped to the wine dir only
  xattr -dr com.apple.quarantine "$WINE_ROOT" 2>/dev/null || true

  WINE_BIN="$(find_wine_binary "$WINE_ROOT" || true)"
  [ -n "$WINE_BIN" ] || die "Wine binary not found after unpacking."
  arch -x86_64 "$WINE_BIN" --version >/dev/null 2>&1 || die "Wine doesn't run (is Rosetta installed?)."
  ledger_done wine || die "Wine postcondition failed."
  log "wine ok: $WINE_BIN"
}

phase_make_prefix() {
  ui_progress 4 8 "Setting up the Windows environment…"
  if ledger_skip_if_done prefix; then ui_say "Environment already set up."; return 0; fi
  [ "$DRY_RUN" = 1 ] && { ui_say "[dry-run] would run wineboot --init into $PREFIX"; return 0; }
  [ -n "$WINE_BIN" ] || die "internal: Wine not installed before make-prefix"

  RUN_WINE_TIMEOUT="$WINEBOOT_TIMEOUT" run_wine wineboot --init >> "$LOG" 2>&1 || true
  wineserver_wait                 # drain async prefix creation before checking (avoids a race)
  # postcondition, not $? (wineboot prints benign errors); poll briefly in case of slow FS flush.
  local tries=0
  until ledger_verify prefix; do
    tries=$((tries+1)); [ "$tries" -ge 15 ] && die "Couldn't create the Windows environment."
    sleep 1
  done
  write_wineserver_pid
  wineserver_kill
  ledger_mark prefix
  log "prefix ok"
}

phase_silent_install() {
  ui_progress 5 8 "Installing RaceStudio 3 (this can take several minutes)…"
  if ledger_skip_if_done installed; then ui_say "RaceStudio 3 already installed."; return 0; fi
  [ "$DRY_RUN" = 1 ] && { ui_say "[dry-run] would run: wine <installer> /exenoui /qn"; return 0; }

  local exe; exe="$(ui_recall INSTALLER_EXE || echo "$INSTALLER_CACHE/$RS3_PINNED_FILE")"
  [ -f "$exe" ] || die "internal: installer exe missing: $exe"

  # copy installer into the prefix so it runs from C: (avoids odd Z: path quoting)
  local cexe="$PREFIX/drive_c/rs3-installer.exe"
  ditto "$exe" "$cexe"
  RUN_WINE_TIMEOUT="$SILENT_INSTALL_TIMEOUT" run_wine 'C:\rs3-installer.exe' /exenoui /qn >> "$LOG" 2>&1 || true
  wineserver_kill
  rm -f "$cexe" 2>/dev/null || true

  # success = STRUCTURAL: exe exists + valid PE header (NOT a live launch)
  ledger_verify installed || die "RaceStudio 3 didn't install correctly. See the log: $LOG"
  ledger_mark installed
  log "installed ok"

  # optional manual-QA smoke test (off by default): launch >= 60s under watchdog, then kill.
  if [ "$SMOKE_TEST" = 1 ]; then
    ui_say "[smoke-test] launching RS3 briefly…"
    RUN_WINE_TIMEOUT=90 run_wine "$RS3_WIN_EXE" >> "$LOG" 2>&1 || true
    wineserver_kill
  fi
}

phase_relocate_data() {
  ui_progress 6 8 "Securing your data folder…"
  if ledger_skip_if_done data; then ui_say "Data folder already set up."; return 0; fi
  [ "$DRY_RUN" = 1 ] && { ui_say "[dry-run] would relocate user/ -> $DATA_DIR (copy→verify→symlink, never clobber)"; return 0; }

  # TCC: the first Documents-touch pops "Wine wants to access Documents" — surface the note.
  if [ "$UI_MODE" = cli ]; then
    ui_say "Note: macOS may ask \"Wine wants to access Documents\" — click Allow (it says Wine, not RaceStudio 3)."
  fi
  ensure_wine_idle
  data_relocate_safe || die "Couldn't set up the data folder safely. Your existing data was left untouched."
  log "data ok -> $DATA_DIR"
}

# ensure no Wine process holds the prefix before we relocate (round-2 res 3).
ensure_wine_idle() { wineserver_kill; }

phase_make_launcher() {
  ui_progress 7 8 "Creating your RaceStudio 3 app…"
  if [ "$DRY_RUN" = 1 ]; then ui_say "[dry-run] would write launch.sh + ~/Applications/RaceStudio 3 launcher"; return 0; fi

  mkdir -p "$INSTALL_ROOT/bin" "$APPS_DIR"
  write_launch_script
  write_uninstall_script

  # If the applet bundled prebuilt (notarized) launcher/uninstaller apps, copy them in.
  if [ -n "${LAUNCHER_APP_SRC:-}" ] && [ -d "$LAUNCHER_APP_SRC" ]; then
    rm -rf "$LAUNCHER_APP"; ditto "$LAUNCHER_APP_SRC" "$LAUNCHER_APP"
  fi
  if [ -n "${UNINSTALL_APP_SRC:-}" ] && [ -d "$UNINSTALL_APP_SRC" ]; then
    rm -rf "$UNINSTALL_APP"; ditto "$UNINSTALL_APP_SRC" "$UNINSTALL_APP"
  fi
  if [ -n "${IMPORT_APP_SRC:-}" ] && [ -d "$IMPORT_APP_SRC" ]; then
    rm -rf "$IMPORT_APP"; ditto "$IMPORT_APP_SRC" "$IMPORT_APP"
  fi
  # Standalone fallback (no applet): a .command that calls launch.sh.
  # Skipped in single-app mode (the RaceStudio 3.app IS the launcher).
  if [ "${RS3_SINGLE_APP:-0}" != 1 ] && [ -z "${LAUNCHER_APP_SRC:-}" ] && [ ! -d "$LAUNCHER_APP" ]; then
    local cmd="$APPS_DIR/RaceStudio 3.command"
    printf '#!/bin/bash\nexec "%s/bin/launch.sh"\n' "$INSTALL_ROOT" > "$cmd"
    chmod +x "$cmd"
  fi
  ledger_mark launcher
  log "launcher ok"
}

# the real launcher logic, installed into APP_SUPPORT/bin (the .app just execs this).
write_launch_script() {
  local f="$INSTALL_ROOT/bin/launch.sh"
  cat > "$f" <<LAUNCH
#!/bin/bash
# RaceStudio 3 launcher — resolves absolute paths (a .app's CWD is not its dir), exports the
# Wine env so it never falls back to a default home prefix, runs RS3 detached.
ROOT="$INSTALL_ROOT"
WB="\$(find "\$ROOT/wine" -type f \\( -name wine -o -name wine64 \\) -path '*/bin/*' 2>/dev/null | head -1)"
if [ -z "\$WB" ] || [ ! -d "\$ROOT/prefix" ]; then
  osascript -e 'display dialog "RaceStudio 3 isn'\''t installed yet. Please run the installer first." buttons {"OK"} default button 1 with icon caution' >/dev/null 2>&1
  exit 1
fi
export WINEPREFIX="\$ROOT/prefix" WINEARCH=win64 WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"
export XDG_CACHE_HOME="\$ROOT/cache" XDG_CONFIG_HOME="\$ROOT/xdg-config" XDG_DATA_HOME="\$ROOT/xdg-data"
mkdir -p "\$ROOT/logs" "\$ROOT/bin"
# The macOS app-menu name ("RaceStudio 3" vs "Wine") comes from the CFBundleName in each Wine
# unix-loader's embedded __info_plist, which build-apps.sh patches at build time
# (patch-wine-appname.py) — NOT from argv[0], which winemac.drv ignores. So just run Wine directly.
nohup arch -x86_64 "\$WB" '$RS3_WIN_EXE' >> "\$ROOT/logs/run.log" 2>&1 &
disown
LAUNCH
  chmod +x "$f"
}

write_uninstall_script() {
  local f="$INSTALL_ROOT/bin/uninstall.sh"
  cat > "$f" <<UNINST
#!/bin/bash
# Removes the engine + launchers. Your telemetry in \$DATA is kept unless --remove-data is passed.
ROOT="$INSTALL_ROOT"
LAUNCH_APP="$LAUNCHER_APP"
UNINST_APP="$UNINSTALL_APP"
IMPORT_APP="$IMPORT_APP"
APPS="$APPS_DIR"
DATA="$DATA_DIR"
REMOVE_DATA=0; [ "\${1:-}" = "--remove-data" ] && REMOVE_DATA=1
# stop any Wine first
WS="\$(find "\$ROOT/wine" -type f -name wineserver -path '*/bin/*' 2>/dev/null | head -1)"
[ -n "\$WS" ] && WINEPREFIX="\$ROOT/prefix" "\$WS" -k 2>/dev/null || true
rm -rf "\$ROOT" "\$LAUNCH_APP" "\$IMPORT_APP" "\$APPS/RaceStudio 3.command" 2>/dev/null || true
[ "\$REMOVE_DATA" = 1 ] && rm -rf "\$DATA" 2>/dev/null || true
# delete the uninstaller app last, detached (it can't delete itself mid-run), and take the whole
# AiM folder with it. rm -rf (not rmdir) so a Finder-dropped .DS_Store / folder Icon can't keep
# /Applications/AiM alive — the folder is exclusively ours (only our apps + .command ever live here).
( sleep 2; rm -rf "\$APPS" ) >/dev/null 2>&1 &
echo "Removed RaceStudio 3.\${REMOVE_DATA:+ (data removed)}"
UNINST
  chmod +x "$f"
}

phase_done() {
  ui_progress 8 8 "Done."
  ui_say "RaceStudio 3 is installed."
  ui_say "  • Apps:   $APPS_DIR  (RaceStudio 3, Import, Uninstall)"
  ui_say "  • Engine: $INSTALL_ROOT"
  ui_say "  • Data:   $DATA_DIR"
  ui_say "Connect AiM devices over WiFi (USB isn't supported under Wine)."
}

# ============================================================================================
# ACTIONS
# ============================================================================================

run_all() {
  phase_preflight
  phase_acquire_installer
  phase_download_wine
  phase_make_prefix
  phase_silent_install
  phase_relocate_data
  phase_make_launcher
  phase_done
}

do_repair() {
  ui_say "Repair: re-running from the first incomplete step…"
  local s
  for s in rosetta wine prefix installed data launcher; do
    if ! ledger_verify "$s" 2>/dev/null; then ui_say "first incomplete: $s"; break; fi
  done
  run_all
}

do_reinstall() {
  ui_confirm reinstall_confirm no "This wipes the Wine engine and Windows environment (your data in $DATA_DIR is kept). Continue?" \
    || die "Reinstall cancelled."
  wineserver_kill 2>/dev/null || true
  rm -rf "$WINE_ROOT" "$PREFIX" "$STATE_DIR"/*.ok 2>/dev/null || true
  WINE_BIN=""
  run_all
}

do_import() {
  local p="$IMPORT_DIR"
  [ -n "$p" ] || die "Import: nothing to import"
  mkdir -p "$DATA_DIR"
  case "$p" in
    *.zip|*.ZIP)
      [ -f "$p" ] || die "Import: zip not found: $p"
      local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/rs3import.XXXXXX")"
      ui_say "Unzipping…"
      ditto -x -k "$p" "$tmp" 2>/dev/null || unzip -q "$p" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "Import: couldn't unzip $p"; }
      local u; u="$(find "$tmp" -type d -name user -path '*RaceStudio3*' 2>/dev/null | head -1)"
      [ -n "$u" ] || u="$tmp"
      import_merge "$u"; local rc=$?
      rm -rf "$tmp"
      [ "$rc" -eq 0 ] || die "Import failed."
      ;;
    *.xrk|*.XRK)
      [ -f "$p" ] || die "Import: file not found: $p"
      local dest="$DATA_DIR/data/dropped-$(date +%Y%m%d)"
      mkdir -p "$dest"
      [ -e "$dest/$(basename "$p")" ] || ditto "$p" "$dest/$(basename "$p")"
      ui_say "Imported session: $(basename "$p") -> $dest"
      ;;
    *)
      [ -d "$p" ] || die "Import: folder not found: $p"
      # A RaceStudio3 user tree merges; otherwise a folder of loose .xrk sessions is imported.
      if [ -n "$(_find_user_tree "$p")" ]; then
        import_merge "$p"
      elif _dir_has_xrk "$p"; then
        import_xrk_dir "$p"
      else
        die "Import: '$p' has no RaceStudio3 user folder and no .xrk files."
      fi
      ;;
  esac
}

do_uninstall() {
  if [ -x "$INSTALL_ROOT/bin/uninstall.sh" ]; then
    "$INSTALL_ROOT/bin/uninstall.sh" "$@"
  else
    wineserver_kill 2>/dev/null || true
    rm -rf "$INSTALL_ROOT" "$APPS_DIR" 2>/dev/null || true   # whole AiM folder, incl .DS_Store/Icon
    ui_say "Removed RaceStudio 3 (data in $DATA_DIR kept)."
  fi
}

usage() {
  sed -n '2,20p' "$HERE/installer-core.sh"
}

# ============================================================================================
# DISPATCH
# ============================================================================================
case "$ACTION" in
  run)               run_all ;;
  preflight)         phase_preflight ;;
  acquire-installer) phase_acquire_installer ;;
  download-wine)     phase_download_wine ;;
  make-prefix)       phase_make_prefix ;;
  silent-install)    phase_silent_install ;;
  relocate-data)     phase_relocate_data ;;
  make-launcher)     phase_make_launcher ;;
  done)              phase_done ;;
  repair)            do_repair ;;
  reinstall)         do_reinstall ;;
  import)            do_import ;;
  uninstall)         do_uninstall "${args[@]:1}" ;;
  set-config)        ui_persist "${args[1]:?key}" "${args[2]:-}" ;;
  is-installed)      if ledger_verify installed && [ -x "$INSTALL_ROOT/bin/launch.sh" ]; then echo RS3_INSTALLED; else echo RS3_ABSENT; fi ;;
  help)              usage ;;
  *) die "unknown action: $ACTION" ;;
esac
