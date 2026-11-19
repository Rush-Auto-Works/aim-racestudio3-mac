#!/bin/bash
# unit-skip-codes.sh — check-rs3-update.sh ignores RaceStudio 3 builds listed in RS3_SKIP_CODES.
# A held build (3.85.12 hangs at startup under Wine, issue 89) must never be picked by the weekly
# auto-bump, and the newest build that is not held still wins.
_T_NAME="unit-skip-codes"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build/check-rs3-update.sh"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3skip.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

BASE="https://www.aim-sportline.com/x"
mkdir -p "$SBX/bin" "$SBX/build" "$SBX/src"
cat > "$SBX/page.html" <<EOF
<a href="$BASE/RaceStudio3-64_38408_000000_000000_20261021_105754.exe">a</a>
<a href="$BASE/RaceStudio3-64_38502_000000_000000_20261102_040502.exe">b</a>
<a href="$BASE/RaceStudio3-64_38512_000000_000000_20261112_124608.exe">c</a>
EOF
printf '#!/bin/bash\ncat "%s"\n' "$SBX/page.html" > "$SBX/bin/curl"; chmod +x "$SBX/bin/curl"
cp "$SCRIPT" "$SBX/build/check-rs3-update.sh"

write_pins() {
  cat > "$SBX/src/pins.env" <<EOF
RS3_PINNED_VER="$1"
RS3_PINNED_FILE="RaceStudio3-64_$2_000000_000000_20261102_040502.exe"
RS3_DOWNLOAD_PAGE="https://www.aim-sportline.com/page.html"
AIM_HTTP_UA="test"
$3
EOF
}
run() { PATH="$SBX/bin:$PATH" bash "$SBX/build/check-rs3-update.sh" 2>/dev/null; }

write_pins 3.85.02 38502 'RS3_SKIP_CODES="38512"'
out="$(run)"
grep -qx 'updated=false' <<<"$out" && ok "held 38512 is not offered over pinned 38502" \
  || bad "held 38512 offered anyway: $out"

write_pins 3.84.08 38408 'RS3_SKIP_CODES="38512"'
out="$(run)"
grep -qx 'version=3.85.02' <<<"$out" && grep -qx 'updated=true' <<<"$out" \
  && ok "newest build that is not held (38502) still wins" || bad "wrong pick with a hold: $out"

write_pins 3.85.02 38502 ''
out="$(run)"
grep -qx 'version=3.85.12' <<<"$out" && ok "no hold: newest build (38512) is offered" \
  || bad "no-hold pick wrong: $out"

echo "$_T_NAME: $P passed, $F failed"
[ "$F" -eq 0 ]
