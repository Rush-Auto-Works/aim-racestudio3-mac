# lib/ledger.sh — a real resume ledger. Each step writes a marker AND has a postcondition
# checker that re-verifies the actual on-disk result (not merely "a marker exists"), so a
# truncated wine/ or a half-moved user/ is detected and redone, never skipped.
#
# Markers live in $STATE_DIR (…/Application Support/RaceStudio3/state/).

ledger_mark()  { mkdir -p "$STATE_DIR"; : > "$STATE_DIR/$1.ok"; }
ledger_clear() { rm -f "$STATE_DIR/$1.ok" 2>/dev/null || true; }
ledger_has()   { [ -f "$STATE_DIR/$1.ok" ]; }

# ledger_verify <step> : returns 0 only if the step's POSTCONDITION currently holds.
# Used by --repair / resume to find the first genuinely-incomplete step.
ledger_verify() {
  case "$1" in
    rosetta)
      # Intel Macs: trivially satisfied. Apple Silicon: x86-64 must run.
      [ "$(uname -m)" != "arm64" ] || arch -x86_64 /usr/bin/true 2>/dev/null ;;
    wine)
      [ -n "${WINE_BIN:-}" ] && [ -x "${WINE_BIN:-/nonexistent}" ] \
        && arch -x86_64 "$WINE_BIN" --version >/dev/null 2>&1 ;;
    prefix)
      [ -f "$PREFIX/system.reg" ] && [ -d "$PREFIX/drive_c/windows" ] ;;
    installed)
      # Structural AND version. The old check was "the exe exists and is a PE32+", which is true
      # of any RaceStudio 3 — so after a DMG upgrade phase_silent_install saw the marker satisfied,
      # skipped, and left the user on the old build. ">=" not "==": if RS3's own updater has moved
      # the user ahead of our pin, that is satisfied too, so nothing here downgrades anyone.
      # An unreadable version counts as NOT satisfied — reinstalling the pinned build over an
      # unknown one is safe (user data lives outside the prefix, symlinked to $DATA_DIR).
      [ -f "$PREFIX/drive_c/$RS3_REL_EXE" ] \
        && file "$PREFIX/drive_c/$RS3_REL_EXE" | grep -q 'PE32+ executable' \
        && rs3_installed_at_least "$RS3_PINNED_VER" ;;
    data)
      # the user dir inside the prefix is a symlink to the chosen DATA_DIR, which exists
      local src="$PREFIX/drive_c/$RS3_REL_USER"
      [ -L "$src" ] && [ -d "$DATA_DIR" ] \
        && [ "$(readlink "$src")" = "$DATA_DIR" ] ;;
    launcher)
      [ -d "$LAUNCHER_APP" ] ;;
    *) return 1 ;;
  esac
}

# ledger_done <step> : verify postcondition, then mark. Returns nonzero if postcondition fails.
ledger_done() { if ledger_verify "$1"; then ledger_mark "$1"; else return 1; fi; }

# ledger_skip_if_done <step> : echo "skip" (and return 0) when both the marker exists AND the
# postcondition still holds; otherwise clears any stale marker and returns 1 (=> do the work).
ledger_skip_if_done() {
  if ledger_has "$1" && ledger_verify "$1"; then return 0; fi
  ledger_clear "$1"; return 1
}

# ledger_reset_for_reinstall : put the ledger back to "nothing done" for --reinstall.
#
# Clearing the markers alone was not enough: the remembered INSTALLER_EXE and the cached exe both
# survived, so "reinstall" faithfully reinstalled the same old RaceStudio 3. Keeps the rest of
# config.env (DATA_DIR above all) and keeps the Wine tarball, which is sha-verified on reuse —
# no reason to make every reinstall re-download 190 MB.
ledger_reset_for_reinstall() {
  rm -f "$STATE_DIR"/*.ok 2>/dev/null || true
  ui_forget INSTALLER_EXE
  rm -f "$INSTALLER_CACHE"/RaceStudio3-64_*.exe 2>/dev/null || true
}
