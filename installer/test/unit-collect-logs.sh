#!/bin/bash
# unit-collect-logs.sh — collect-logs.sh copies the logs that exist into a fresh Desktop folder,
# writes system-info.txt + README.txt, opens the folder, and never fails when a log is absent.
# Everything is sandboxed via env overrides (RS3_APP_SUPPORT, RS3_DESKTOP_DIR, RS3_OPEN_CMD).
_T_NAME="unit-collect-logs"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

SCRIPT="$HERE/../src/collect-logs.sh"
assert_file "$SCRIPT"
assert_true "bash -n '$SCRIPT'" "collect-logs.sh parses"

# Fixture: an INSTALL_ROOT with run.log present but install.log ABSENT (tests the skip path).
ROOT="$SANDBOX/appsupport"
mkdir -p "$ROOT/logs"
printf 'run-log-marker\n' > "$ROOT/logs/run.log"

DESK="$SANDBOX/desktop"; mkdir -p "$DESK"
OPENLOG="$SANDBOX/open-called.txt"

# RS3_OPEN_CMD records its argument instead of launching Finder.
cat > "$SANDBOX/fake-open.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" > "$OPENLOG"
EOF
chmod +x "$SANDBOX/fake-open.sh"

RS3_APP_SUPPORT="$ROOT" RS3_DESKTOP_DIR="$DESK" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
rc=$?
assert_true "[ $rc -eq 0 ]" "collect-logs.sh exits 0 even with install.log absent"

OUT="$(find "$DESK" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
assert_true "[ -n '$OUT' ]" "a dated AiM-Logs-* folder was created"
assert_true "[ -f '$OUT/run.log' ]"          "present run.log was copied"
assert_true "grep -q run-log-marker '$OUT/run.log'" "run.log content intact"
assert_true "[ ! -f '$OUT/install.log' ]"    "absent install.log was skipped (not faked)"
assert_true "[ -f '$OUT/system-info.txt' ]"  "system-info.txt written"
assert_true "[ -f '$OUT/README.txt' ]"       "README.txt written"
assert_true "grep -q 'install.log' '$OUT/README.txt'" "README notes the missing install.log"
assert_true "grep -q 'aim-bridge.log' '$OUT/README.txt'" "README notes the missing aim-bridge.log"
assert_true "[ \"\$(cat '$OPENLOG' 2>/dev/null)\" = '$OUT' ]" "open was called on the output folder"

# --- version reporting ----------------------------------------------------------------------
# The old report printed only RS3_PINNED_VER, so a support log claimed the pinned version no
# matter what was installed. That is what hid the "DMG upgrade doesn't update RS3" bug.
FIX="$HERE/fixtures/RaceStudio3-3.83.26.xmv"
mkdir -p "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3"
ditto "$FIX" "$ROOT/prefix/drive_c/AIM_SPORT/RaceStudio3/RaceStudio3.xmv"

DESK2="$SANDBOX/desktop2"; mkdir -p "$DESK2"
RS3_APP_SUPPORT="$ROOT" RS3_DESKTOP_DIR="$DESK2" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
OUT2="$(find "$DESK2" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
SI="$OUT2/system-info.txt"
assert_true "grep -q 'RS3 version (installed): 3.83.26.0' '$SI'" "reports the INSTALLED version"
assert_true "grep -q 'RS3 version (pinned):' '$SI'"               "reports the pinned version too"
assert_true "grep -q 'installed differs from pinned' '$SI'"       "flags the mismatch"

# With no manifest, it says unknown — it must never fall back to claiming the pin.
ROOT3="$SANDBOX/appsupport3"; mkdir -p "$ROOT3/logs"
DESK3="$SANDBOX/desktop3"; mkdir -p "$DESK3"
RS3_APP_SUPPORT="$ROOT3" RS3_DESKTOP_DIR="$DESK3" RS3_OPEN_CMD="$SANDBOX/fake-open.sh" \
  bash "$SCRIPT"
OUT3="$(find "$DESK3" -maxdepth 1 -type d -name 'AiM-Logs-*' | head -1)"
assert_true "grep -q 'RS3 version (installed): unknown' '$OUT3/system-info.txt'" \
  "no manifest reports unknown, not the pin"

finish
