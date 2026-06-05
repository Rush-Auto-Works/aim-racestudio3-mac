#!/bin/bash
# unit-wine.sh — the native-feel Mac Driver registry file is generated correctly.
# write_macdrv_reg is pure (writes a file, runs no Wine), so we can assert its contents directly.
_T_NAME="unit-wine"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/../src"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3wine.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

# shellcheck source=/dev/null
. "$SRC_DIR/lib/wine.sh"

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

REG="$SBX/native-feel.reg"
write_macdrv_reg "$REG"

[ -f "$REG" ] && ok "reg file written" || bad "reg file missing"
grep -q '^REGEDIT4' "$REG" && ok "REGEDIT4 header" || bad "no REGEDIT4 header"
grep -qF '[HKEY_CURRENT_USER\Software\Wine\Mac Driver]' "$REG" && ok "Mac Driver key path" || bad "wrong key path"

# Both Command keys map to Ctrl so Cmd-C/V works from either, and Alt stays sendable via left Option.
grep -qF '"LeftCommandIsCtrl"="y"' "$REG"  && ok "LeftCommandIsCtrl set"  || bad "LeftCommandIsCtrl missing"
grep -qF '"RightCommandIsCtrl"="y"' "$REG" && ok "RightCommandIsCtrl set" || bad "RightCommandIsCtrl missing"
grep -qF '"LeftOptionIsAlt"="y"' "$REG"    && ok "LeftOptionIsAlt set"    || bad "LeftOptionIsAlt missing"

# Right Option is deliberately left unmapped so it still types special characters.
! grep -q 'RightOptionIsAlt' "$REG" && ok "right Option left free" || bad "right Option unexpectedly mapped"

# Classic REGEDIT4 format uses CRLF — assert the file ends with one (last two bytes are 0d 0a).
[ "$(tail -c 2 "$REG" | od -An -tx1 | tr -d ' \n')" = "0d0a" ] \
  && ok "CRLF line endings" || bad "missing CRLF line endings"

echo "unit-wine: $P passed, $F failed"
[ "$F" -eq 0 ]
