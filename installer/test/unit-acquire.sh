#!/bin/bash
# unit-acquire.sh — phase_acquire_installer must accept a remembered installer only when it IS the
# pinned one. Before this, `[ -f "$pre" ]` meant a config.env left over from an older app kept
# pointing at the previous RaceStudio 3 and every DMG upgrade reinstalled the version it already
# had. Hermetic: src/ is copied, pins.env is rewritten to tiny fixtures, and both remote URLs point
# at a closed local port so every network path fails immediately.
_T_NAME="unit-acquire"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/harness.sh"

SRC="$SANDBOX/src"
ditto "$HERE/../src" "$SRC"

FILE="RaceStudio3-64_39999_000000_000000_20260101_000000.exe"
ASSET="$SANDBOX/$FILE"
printf 'pinned-installer-payload' > "$ASSET"
SIZE="$(file_size "$ASSET")"; SHA="$(sha256 "$ASSET")"
DEAD="https://127.0.0.1:1"       # connection refused, instantly

# Rewrite the pins the phase reads. Everything else in pins.env is left alone. BSD sed, so -i
# takes an explicit empty suffix. No python3 here on purpose: an end-user Mac has no Xcode CLT.
sed -i '' -E \
  -e "s|^RS3_PINNED_FILE=.*|RS3_PINNED_FILE=\"$FILE\"|" \
  -e "s|^RS3_PINNED_SIZE=.*|RS3_PINNED_SIZE=$SIZE|" \
  -e "s|^RS3_PINNED_SHA256=.*|RS3_PINNED_SHA256=\"$SHA\"|" \
  -e "s|^RS3_PINNED_URL=.*|RS3_PINNED_URL=\"$DEAD/$FILE\"|" \
  -e "s|^RS3_DOWNLOAD_PAGE=.*|RS3_DOWNLOAD_PAGE=\"$DEAD/page\"|" \
  -e "s|^RS3_DOWNLOAD_TIMEOUT=.*|RS3_DOWNLOAD_TIMEOUT=5|" \
  "$SRC/pins.env"
grep -q "^RS3_PINNED_FILE=\"$FILE\"$" "$SRC/pins.env" && \
grep -q '^RS3_DOWNLOAD_TIMEOUT=5$' "$SRC/pins.env" || { echo "pins rewrite failed"; exit 2; }

ROOT="$SANDBOX/root"
CACHE="$ROOT/installer"
mkdir -p "$CACHE" "$ROOT/state"

run_acquire() {   # -> prints output, returns the phase's exit code
  ( cd "$SANDBOX" && http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= all_proxy= no_proxy='*' \
      HOME="$SANDBOX/fakehome" RS3_APP_SUPPORT="$ROOT" UI_MODE=applet \
      bash "$SRC/installer-core.sh" acquire-installer 2>&1 )
}
mkdir -p "$SANDBOX/fakehome/Downloads"

# --- case 1: remembered installer IS the pinned one -> accepted, no network ------------------
ditto "$ASSET" "$CACHE/$FILE"
printf 'INSTALLER_EXE=%q\n' "$CACHE/$FILE" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 0 ]" "valid remembered installer: phase succeeds"
assert_true "printf '%s' \"\$out\" | grep -q 'Installer ready'" "valid remembered installer: accepted"

# --- case 2: remembered installer is a DIFFERENT (older) build -> rejected -------------------
rm -f "$CACHE/$FILE"          # case 1 left a valid pinned installer here; download_verified
                               # would short-circuit on it and mask what this case tests
STALE="RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
ditto "$ASSET" "$CACHE/$STALE"
printf 'INSTALLER_EXE=%q\n' "$CACHE/$STALE" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "stale basename: phase does NOT succeed (asks for the installer)"
assert_true "printf '%s' \"\$out\" | grep -q 'NEEDS_INSTALLER: $FILE'" \
  "stale basename: names the file it needs"

assert_absent "$CACHE/$FILE"
# --- case 3: right name, wrong size -> rejected ----------------------------------------------
rm -f "$CACHE/$FILE"          # case 1 left a valid pinned installer here; download_verified
                               # would short-circuit on it and mask what this case tests
BAD="$SANDBOX/badsize/$FILE"; mkdir -p "$SANDBOX/badsize"
printf 'short' > "$BAD"
printf 'INSTALLER_EXE=%q\n' "$BAD" > "$ROOT/state/config.env"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "wrong size: phase does NOT succeed"

# --- case 4: the pinned installer is sitting in ~/Downloads -> used --------------------------
rm -f "$ROOT/state/config.env" "$CACHE/$FILE"
ditto "$ASSET" "$SANDBOX/fakehome/Downloads/$FILE"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 0 ]" "pinned file in Downloads: phase succeeds"
assert_true "printf '%s' \"\$out\" | grep -q 'Downloads'" "pinned file in Downloads: used it"

# --- case 5: a DIFFERENT build in ~/Downloads -> not used ------------------------------------
rm -f "$ROOT/state/config.env" "$CACHE/$FILE" "$SANDBOX/fakehome/Downloads/$FILE"
ditto "$ASSET" "$SANDBOX/fakehome/Downloads/$STALE"
out="$(run_acquire)"; rc=$?
assert_true "[ $rc -eq 10 ]" "wrong build in Downloads: not accepted"

finish
