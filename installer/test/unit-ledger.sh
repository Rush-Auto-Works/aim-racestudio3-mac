#!/bin/bash
# unit-ledger.sh — markers + postcondition verifiers detect real on-disk state, not just markers.
_T_NAME="unit-ledger"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# mark / has / clear
ledger_mark foo
assert_true  "ledger_has foo" "mark then has"
ledger_clear foo
assert_false "ledger_has foo" "clear then not has"

# installed postcondition: needs exe with a real PE32+ header
mkdir -p "$PREFIX/drive_c/$(dirname "$RS3_REL_EXE")"
printf 'not-a-pe\n' > "$PREFIX/drive_c/$RS3_REL_EXE"
assert_false "ledger_verify installed" "installed: rejects non-PE file"

# Use a real PE32+ binary if the reference prefix has one
REFEXE="$HOME/.rs3-w11-test/drive_c/$RS3_REL_EXE"
if [ -f "$REFEXE" ]; then
  ditto "$REFEXE" "$PREFIX/drive_c/$RS3_REL_EXE"
  assert_true "ledger_verify installed" "installed: accepts real PE32+ exe"
fi

# prefix postcondition
assert_false "ledger_verify prefix" "prefix: rejects empty"
mkdir -p "$PREFIX/drive_c/windows"; : > "$PREFIX/system.reg"
assert_true "ledger_verify prefix" "prefix: accepts system.reg + drive_c/windows"

# data postcondition: SRC symlink -> DATA_DIR
SRC="$PREFIX/drive_c/$RS3_REL_USER"
mkdir -p "$(dirname "$SRC")" "$DATA_DIR"
ln -s "$DATA_DIR" "$SRC"
assert_true "ledger_verify data" "data: accepts symlink to DATA_DIR"

# ledger_skip_if_done clears a stale marker when postcondition fails
ledger_mark wine                      # marker present but no wine binary => stale
WINE_BIN=""
assert_false "ledger_skip_if_done wine" "skip_if_done: returns do-the-work when postcondition fails"
assert_false "ledger_has wine"          "skip_if_done: cleared the stale marker"

finish
