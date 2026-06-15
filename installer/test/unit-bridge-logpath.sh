#!/bin/bash
# unit-bridge-logpath.sh — the aim-bridge LaunchDaemon plist must redirect the daemon's
# stdout+stderr to a persistent, root-writable file so "Show Logs" can collect it. The path is
# /Library/Logs/aim-bridge.log (NOT a /Library/Logs/AiM/ subdir: launchd won't create a missing
# parent dir before the root daemon's first RunAtLoad launch, which would drop the first session).
_T_NAME="unit-bridge-logpath"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/harness.sh"

PLIST="$HERE/../bridge/com.rushautoworks.racestudio3.bridge.plist"
LOGPATH="/Library/Logs/aim-bridge.log"

assert_file "$PLIST"
assert_true "/usr/libexec/PlistBuddy -c 'Print' '$PLIST' >/dev/null 2>&1" "plist parses"
assert_true "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' '$PLIST' 2>/dev/null)\" = '$LOGPATH' ]" "StandardErrorPath -> $LOGPATH"
assert_true "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath'  '$PLIST' 2>/dev/null)\" = '$LOGPATH' ]" "StandardOutPath -> $LOGPATH"
assert_true "! grep -q '/Library/Logs/AiM/' '$PLIST'" "does not use a missing /Library/Logs/AiM/ subdir"

finish
