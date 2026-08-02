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
run_silent_install() {   # -> prints output, returns the real phase's exit code
  ( cd "$SANDBOX" && http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= all_proxy= no_proxy='*' \
      HOME="$SANDBOX/fakehome" RS3_APP_SUPPORT="$ROOT" UI_MODE=applet \
      bash "$SRC/installer-core.sh" silent-install 2>&1 )
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

# --- installed-state: a satisfying newer RS3 must skip even without our marker ---------------
# This exercises phase_silent_install itself. Before the fix, the missing marker sends the phase
# past the valid installed postcondition and into the installer-exe check below.
REFEXE="$HOME/.rs3-w11-test/drive_c/$RS3_REL_EXE"
if [ -f "$REFEXE" ]; then
  mkdir -p "$ROOT/prefix/drive_c/$(dirname "$RS3_REL_EXE")"
  ditto "$REFEXE" "$ROOT/prefix/drive_c/$RS3_REL_EXE"
  mkdir -p "$ROOT/prefix/drive_c/$(dirname "$RS3_REL_XMV")"

  printf '<p n="VERSION">99.0.0</p>\r\n' > "$ROOT/prefix/drive_c/$RS3_REL_XMV"
  rm -f "$ROOT/state/installed.ok"
  assert_absent "$ROOT/state/installed.ok"
  out="$(run_silent_install)"; rc=$?
  assert_true "[ $rc -eq 0 ]" "newer RS3 without marker: phase succeeds"
  assert_true "printf '%s' \"\$out\" | grep -qi 'already installed'" \
    "newer RS3 without marker: phase skips"
  assert_file "$ROOT/state/installed.ok"

  # Mirror the real upgrade path: an older installed build is not satisfying, so it must try the
  # pinned installer. No installer is staged in this case; its internal missing-installer error is
  # the expected proof that it proceeded instead of printing the skip message.
  printf '<p n="VERSION">3.83.26.0</p>\r\n' > "$ROOT/prefix/drive_c/$RS3_REL_XMV"
  rm -f "$ROOT/state/installed.ok"
  out="$(run_silent_install)"; rc=$?
  assert_true "[ $rc -ne 0 ]" "older RS3 without marker: phase attempts install"
  assert_false "printf '%s' \"\$out\" | grep -qi 'already installed'" \
    "older RS3 without marker: phase does not skip"
else
  echo "NOTE: skipped newer/older silent-install marker cases; reference PE is absent: $REFEXE"
fi

# --- install-state ------------------------------------------------------------------------------
# The launcher needs three states, not two: a prefix holding an OLDER RaceStudio 3 is neither
# "ready to launch" nor "never set up", and telling an upgrading user "the first time you open it…"
# is wrong.
state_of() { ( cd "$SANDBOX" && HOME="$SANDBOX/fakehome" RS3_APP_SUPPORT="$ROOT" UI_MODE=applet \
                 bash "$SRC/installer-core.sh" install-state 2>/dev/null ); }

assert_eq "$(state_of)" "RS3_ABSENT" "no prefix at all: absent"

mkdir -p "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/64" "$ROOT/bin"
: > "$ROOT/bin/launch.sh"; chmod +x "$ROOT/bin/launch.sh"
: > "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe"
# "Outdated" needs a READABLE manifest older than the pin; write one explicitly so this case does
# not depend on a leftover xmv from an earlier (REFEXE-gated) scenario that CI never runs.
printf '<p n="VERSION">3.83.26.0</p>\r\n' > "$ROOT/prefix/drive_c/$RS3_REL_XMV"
assert_eq "$(state_of)" "RS3_OUTDATED" "RS3 present but not at the pinned version: outdated"

# An install whose manifest is unreadable is UNKNOWN, not outdated: routing it into the update
# flow could downgrade a newer build, so install-state must not claim OUTDATED without evidence.
rm -f "$ROOT/prefix/drive_c/$RS3_REL_XMV"
assert_eq "$(state_of)" "RS3_INSTALLED" "exe present but unreadable manifest: unknown, not outdated"

finish
