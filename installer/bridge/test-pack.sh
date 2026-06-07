#!/bin/bash
# test-pack.sh — packaging + cross-file consistency for the root daemon. Catches the rename/path
# drift that would silently break registration or uninstall: the daemon Label, the plist filename,
# aim-bridge-ctl's PLIST constant, the launchctl bootout label, and BundleProgram must all agree,
# and build-apps.sh must place the binaries + plist exactly where the plist + ctl expect them.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HERE/com.rushautoworks.racestudio3.bridge.plist"
CTL_SRC="$HERE/aim-bridge-ctl.swift"
BUILD_APPS="$HERE/../build/build-apps.sh"
CORE="$HERE/../src/installer-core.sh"
LAUNCHER="$HERE/../src/RaceStudio3.applescript"
LABEL="com.rushautoworks.racestudio3.bridge"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq()  { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: '$2' != '$3'"; }

echo "== plist is valid + has the right keys =="
plutil -lint "$PLIST" >/dev/null 2>&1 && ok "plutil -lint" || bad "plutil -lint"
get() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null; }
eq "Label"         "$(get Label)"         "$LABEL"
eq "BundleProgram" "$(get BundleProgram)" "Contents/MacOS/aim-bridge"
eq "RunAtLoad"     "$(get RunAtLoad)"     "true"
eq "KeepAlive"     "$(get KeepAlive)"     "true"

echo "== filename / label / constant all agree =="
eq "plist filename" "$(basename "$PLIST")" "$LABEL.plist"
grep -Fq "let PLIST = \"$LABEL.plist\"" "$CTL_SRC" && ok "aim-bridge-ctl PLIST constant matches" || bad "ctl PLIST constant != $LABEL.plist"
grep -Fq "launchctl bootout system/$LABEL" "$CORE" && ok "uninstall bootout label matches" || bad "uninstall bootout label != $LABEL"

echo "== build-apps places binaries + plist where plist/ctl expect =="
# BundleProgram = Contents/MacOS/aim-bridge -> build-apps must cp aim-bridge there
grep -Fq 'cp "$HERE/../bridge/build/aim-bridge"     "$APP/Contents/MacOS/aim-bridge"' "$BUILD_APPS" && ok "daemon -> Contents/MacOS/aim-bridge" || bad "daemon copy path"
grep -Fq 'cp "$HERE/../bridge/build/aim-bridge-ctl" "$APP/Contents/MacOS/aim-bridge-ctl"' "$BUILD_APPS" && ok "ctl -> Contents/MacOS/aim-bridge-ctl" || bad "ctl copy path"
grep -Fq 'Contents/Library/LaunchDaemons' "$BUILD_APPS" && ok "plist -> Contents/Library/LaunchDaemons" || bad "plist dest"
grep -Fq 'codesign --force --options runtime $TS --sign "$IDENTITY" "$APP/Contents/MacOS/aim-bridge"' "$BUILD_APPS" && ok "daemon is signed (hardened)" || bad "daemon not signed in hardened path"

echo "== launcher invokes the ctl at the right path =="
grep -Fq 'Contents/MacOS/aim-bridge-ctl' "$LAUNCHER" && ok "launcher calls Contents/MacOS/aim-bridge-ctl" || bad "launcher ctl path"
grep -Fq 'sw_vers -productVersion' "$LAUNCHER" && ok "launcher gates on macOS version" || bad "launcher missing version gate"

echo "pack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
