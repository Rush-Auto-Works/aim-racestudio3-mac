#!/bin/bash
# unit-uninstall-daemon.sh — the generated uninstall.sh must tear down the aim-bridge root daemon.
# Sources installer-core.sh with the harmless `help` action (its dispatch just prints usage), then
# calls write_uninstall_script with sandbox paths and asserts the emitted script boots out the
# daemon by its exact label and still removes the engine.
_T_NAME="unit-uninstall-daemon"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

LABEL="com.rushautoworks.racestudio3.bridge"

# Define the engine's functions without running an install. `help` -> usage() only.
# shellcheck source=/dev/null
. "$SRC_DIR/installer-core.sh" help >/dev/null 2>&1 || true

assert_true "type write_uninstall_script >/dev/null 2>&1" "write_uninstall_script is defined"

# Point the generator at the sandbox (installer-core's own init set these to real paths on source).
INSTALL_ROOT="$SANDBOX/engine"; mkdir -p "$INSTALL_ROOT/bin"
LAUNCHER_APP="$SANDBOX/AiM/RaceStudio 3.app"
UNINSTALL_APP="$SANDBOX/AiM/Uninstall RaceStudio 3.app"
IMPORT_APP="$SANDBOX/AiM/Import RaceStudio 3 Data.app"
APPS_DIR="$SANDBOX/AiM"
DATA_DIR="$SANDBOX/AIM_SPORT"

write_uninstall_script
U="$INSTALL_ROOT/bin/uninstall.sh"

assert_file "$U"
assert_true "[ -x '$U' ]"                                             "uninstall.sh is executable"
assert_true "grep -Fq 'launchctl bootout system/$LABEL' '$U'"        "boots out the daemon by label"
assert_true "grep -q 'wineserver' '$U' || true; grep -q 'rm -rf' '$U'" "still removes the engine"
# bootout must precede the rm that deletes the daemon binary (stop before delete)
bo="$(grep -n 'launchctl bootout' "$U" | head -1 | cut -d: -f1)"
rmln="$(grep -n 'rm -rf "\$ROOT"' "$U" | head -1 | cut -d: -f1)"
assert_true "[ -n '$bo' ] && [ -n '$rmln' ] && [ '$bo' -lt '$rmln' ]"  "bootout runs before the engine rm"
# the generated script must be valid bash
assert_true "bash -n '$U'"                                            "generated uninstall.sh parses"

finish
