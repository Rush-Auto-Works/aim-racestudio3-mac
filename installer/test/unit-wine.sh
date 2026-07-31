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

# --- drop_host_root_drive: removes Wine's `z: -> /` mapping (issue #32). Pure filesystem, so it is
# testable against a fake prefix with no Wine involved.
PFX="$SBX/prefix"
mkdir -p "$PFX/dosdevices" "$PFX/drive_c"
ln -s / "$PFX/dosdevices/z:"
ln -s /dev/null "$PFX/dosdevices/z::"
ln -s ../drive_c "$PFX/dosdevices/c:"
ln -s /Volumes/SomeStick "$PFX/dosdevices/d:"        # dangling on purpose: an unplugged volume

drop_host_root_drive "$PFX"

[ ! -L "$PFX/dosdevices/z:" ]  && ok "z: mapping removed"        || bad "z: mapping still present"
[ ! -L "$PFX/dosdevices/z::" ] && ok "z:: device link removed"   || bad "z:: device link still present"
# Only Z: goes. C: is the prefix itself and D:/E:/… are how external volumes reach RS3, so removing
# any of them would take away the host export path this fix is supposed to preserve.
[ -L "$PFX/dosdevices/c:" ] && ok "c: left alone" || bad "c: was removed"
[ -L "$PFX/dosdevices/d:" ] && ok "d: left alone (dangling volume link survives)" || bad "d: was removed"

# Idempotent: the launchers re-run this on every start, so a second call must be a no-op, not an error.
drop_host_root_drive "$PFX" && ok "second call succeeds (idempotent)" || bad "second call returned nonzero"

# A dangling z: (target unmounted) must still be removed — `[ -e ]` is false for those, so the
# implementation must not gate on the target existing.
# rm first: if the fix ever regresses, z: is still a live symlink to / and `ln -s` would follow it
# and try to create the link on the real root filesystem instead of inside the sandbox.
rm -f "$PFX/dosdevices/z:"
ln -s /nonexistent-mount "$PFX/dosdevices/z:"
drop_host_root_drive "$PFX"
[ ! -L "$PFX/dosdevices/z:" ] && ok "dangling z: removed" || bad "dangling z: survived"

# Empty argument must be a safe no-op rather than an rm against /dosdevices/z:.
drop_host_root_drive "" && ok "empty prefix arg is a no-op" || bad "empty prefix arg returned nonzero"

echo "unit-wine: $P passed, $F failed"
[ "$F" -eq 0 ]
