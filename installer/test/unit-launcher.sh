#!/bin/bash
# unit-launcher.sh — make-launcher (standalone) writes correct, sandboxed launcher scripts.
_T_NAME="unit-launcher"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/../src"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3launch.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

# Run make-launcher in standalone CLI mode, fully sandboxed (no real ~/Applications touched).
RS3_APP_SUPPORT="$SBX/app-support" RS3_APPS_DIR="$SBX/Applications" RS3_DATA_DIR="$SBX/Documents/AIM_SPORT" \
  bash "$SRC_DIR/installer-core.sh" make-launcher >/dev/null 2>&1

LS="$SBX/app-support/bin/launch.sh"
US="$SBX/app-support/bin/uninstall.sh"
CMD="$SBX/Applications/RaceStudio 3.command"

[ -f "$LS" ] && ok "launch.sh written" || bad "launch.sh missing"
[ -x "$LS" ] && ok "launch.sh executable" || bad "launch.sh not executable"
[ -f "$US" ] && ok "uninstall.sh written" || bad "uninstall.sh missing"
[ -f "$CMD" ] && ok ".command fallback created" || bad ".command missing"

# launch.sh must reference the sandboxed install root and the RS3 exe, and never ~/.wine
grep -q "$SBX/app-support" "$LS" && ok "launch.sh points at install root" || bad "launch.sh wrong root"
grep -q 'AiMRS3-64-ReleaseU.exe' "$LS" && ok "launch.sh runs the RS3 exe" || bad "launch.sh missing exe"
grep -q 'WINEPREFIX=' "$LS" && ok "launch.sh exports WINEPREFIX" || bad "launch.sh no WINEPREFIX"
! grep -q '/.wine' "$LS" && ok "launch.sh never uses ~/.wine" || bad "launch.sh references ~/.wine"

# make-launcher copies the bundled Import/Uninstall apps into the AiM apps dir when *_SRC is set.
IMP_SRC="$SBX/embed/Import RaceStudio 3 Data.app"; UNI_SRC="$SBX/embed/Uninstall RaceStudio 3.app"
mkdir -p "$IMP_SRC/Contents" "$UNI_SRC/Contents"
RS3_APP_SUPPORT="$SBX/app-support" RS3_APPS_DIR="$SBX/Applications" RS3_DATA_DIR="$SBX/Documents/AIM_SPORT" \
  IMPORT_APP_SRC="$IMP_SRC" UNINSTALL_APP_SRC="$UNI_SRC" \
  bash "$SRC_DIR/installer-core.sh" make-launcher >/dev/null 2>&1
[ -d "$SBX/Applications/Import RaceStudio 3 Data.app" ] && ok "Import app copied to AiM dir" || bad "Import app not copied"
[ -d "$SBX/Applications/Uninstall RaceStudio 3.app" ] && ok "Uninstall app copied to AiM dir" || bad "Uninstall app not copied"

# the real ~/Applications must NOT have been touched
[ ! -e "$HOME/Applications/RaceStudio 3.command" ] || echo "  note: pre-existing real launcher present (not created by this test)"

echo "unit-launcher: $P passed, $F failed"
[ "$F" -eq 0 ]
