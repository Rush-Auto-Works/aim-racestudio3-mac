#!/bin/bash
# unit-winemac-patch.sh — the winemac menu patch applies cleanly to the pinned Wine source and
# introduces the new menu-item selectors + the ⌘Q-only mask. Requires the Wine source tree at
# $WINE_SRC (from Task 0); skips (77) if absent so the suite still runs without it.
_T_NAME="unit-winemac-patch"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/../wine-patch/winemac-native-menu.patch"
SRC="${WINE_SRC:-}"
[ -n "$SRC" ] && [ -f "$SRC/dlls/winemac.drv/cocoa_app.m" ] || { echo "  (WINE_SRC unset — skipping)"; exit 77; }

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winemacpatch.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC" "$WORK/src"

git -C "$WORK/src" apply --check "$PATCH" 2>/dev/null && ok "patch applies cleanly" || bad "patch does not apply"
git -C "$WORK/src" apply "$PATCH" 2>/dev/null || true
M="$WORK/src/dlls/winemac.drv/cocoa_app.m"
grep -qF 'wine_rs3ImportData:' "$M"      && ok "Import action present"    || bad "Import action missing"
grep -qF 'wine_rs3Uninstall:' "$M"       && ok "Uninstall action present" || bad "Uninstall action missing"
grep -qF 'Import RaceStudio 3 Data' "$M" && ok "Import title present"     || bad "Import title missing"
grep -qF 'Uninstall RaceStudio 3' "$M"   && ok "Uninstall title present"  || bad "Uninstall title missing"
# ⌘Q fold-in (added in Task 4): Quit mask Command-only.
grep -qE 'setKeyEquivalentModifierMask:NSEventModifierFlagCommand\]' "$M" && ok "Quit is ⌘Q (Command only)" || bad "Quit mask not folded to ⌘Q"
echo "unit-winemac-patch: $P passed, $F failed"; [ "$F" -eq 0 ]
