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

finish
