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
  # A valid PE is no longer enough: the version AiM recorded must be >= the pin, or an upgrade
  # would see "already installed" and skip the install that IS the upgrade.
  mkdir -p "$PREFIX/drive_c/$(dirname "$RS3_REL_XMV")"
  ditto "$(dirname "${BASH_SOURCE[0]}")/fixtures/RaceStudio3-3.83.26.xmv" "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_false "ledger_verify installed" "installed: real exe but OLDER version is not satisfied"

  printf '<p n="VERSION">%s</p>\r\n' "$RS3_PINNED_VER" > "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_true  "ledger_verify installed" "installed: real exe at the pinned version is satisfied"

  printf '<p n="VERSION">99.0.0</p>\r\n' > "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_true  "ledger_verify installed" "installed: a NEWER version is satisfied (never downgrade)"

  rm -f "$PREFIX/drive_c/$RS3_REL_XMV"
  assert_false "ledger_verify installed" "installed: unknown version is not satisfied"
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

# --- ui_forget --------------------------------------------------------------------------------
ui_persist DATA_DIR "$DATA_DIR"
ui_persist INSTALLER_EXE "/some/old/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
assert_eq "$(ui_recall INSTALLER_EXE)" "/some/old/RaceStudio3-64_38326_000000_000000_20260613_071826.exe" "persisted"
ui_forget INSTALLER_EXE
assert_false "ui_recall INSTALLER_EXE" "ui_forget drops the key"
assert_eq "$(ui_recall DATA_DIR)" "$DATA_DIR" "ui_forget keeps every OTHER key"

# --- ledger_reset_for_reinstall -----------------------------------------------------------------
# A reinstall that keeps the remembered installer and the cached exe reinstalls exactly the version
# the user is trying to get off.
ledger_mark installed; ledger_mark wine
ui_persist INSTALLER_EXE "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
: > "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
: > "$INSTALLER_CACHE/wine-staging-11.9-osx64.tar.xz"

ledger_reset_for_reinstall

assert_false "ledger_has installed" "reset: cleared the installed marker"
assert_false "ledger_has wine"      "reset: cleared the wine marker"
assert_false "ui_recall INSTALLER_EXE" "reset: forgot the remembered installer"
assert_absent "$INSTALLER_CACHE/RaceStudio3-64_38326_000000_000000_20260613_071826.exe"
assert_file   "$INSTALLER_CACHE/wine-staging-11.9-osx64.tar.xz"
assert_eq "$(ui_recall DATA_DIR)" "$DATA_DIR" "reset: kept the user's chosen data folder"

finish
