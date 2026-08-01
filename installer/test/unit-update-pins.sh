#!/bin/bash
# unit-update-pins.sh — check-rs3-update.sh's pins.env rewriter fails loudly instead of silently.
#
# Regression test for issue #34. The weekly updater committed a pins.env where RS3_PINNED_SIZE still
# held the PREVIOUS version's value while every other field had moved on. download_verified checks
# size before sha256 and bails, so that half-updated file broke every install and release build off
# main. Two faults combined: a `stat` idiom that returned garbage instead of failing on Linux, and
# an ed_pins that never checked whether its sed actually matched.
#
# ed_pins lives inside check-rs3-update.sh, after a network download, so it cannot be reached by
# running the script. Extract the function body from the real source and exercise it directly — that
# keeps the test bound to the shipped code rather than to a copy that can drift.
_T_NAME="unit-update-pins"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build/check-rs3-update.sh"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3pins.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

[ -f "$SCRIPT" ] || { echo "  FAIL check-rs3-update.sh not found at $SCRIPT" >&2; exit 1; }

# --- the size idiom must not be the broken portable-looking one -------------------------------
# GNU coreutils reads `stat -f` as --file-system and EXITS 0, so `stat -f %z x || stat -c %s x`
# never falls back on Linux and yields a multi-line filesystem report. Assert it is gone.
# Strip comments first: the fix documents the old idiom in a comment, and matching that would make
# this assertion fail on a correctly-fixed script.
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE 'stat -f %z .* \|\| .*stat -c %s'; then
  bad "still uses the stat -f/-c fallback that silently succeeds on GNU"
else
  ok "no stat -f/-c fallback idiom"
fi
grep -q 'wc -c <' "$SCRIPT" && ok "sizes come from wc -c (identical on BSD and GNU)" \
  || bad "size is not read with wc -c"

# wc -c must agree with the real byte count, or the pin would be wrong in a new way.
printf 'abcde' > "$SBX/probe.bin"
[ "$(wc -c < "$SBX/probe.bin" | tr -d '[:space:]')" = "5" ] \
  && ok "wc -c yields a bare byte count" || bad "wc -c did not yield 5"

# --- ed_pins: extract the real function and exercise it ---------------------------------------
# Pull the ed_pins() { ... } block out of the script, up to the closing brace at column 0.
sed -n '/^ed_pins() {/,/^}/p' "$SCRIPT" > "$SBX/ed_pins.sh"
[ -s "$SBX/ed_pins.sh" ] && ok "extracted ed_pins from the real script" || bad "could not extract ed_pins"

# `die` is defined elsewhere in the script; stub it so a fatal path is observable as exit 9.
{ printf 'die() { echo "DIE: $*" >&2; exit 9; }\n'; cat "$SBX/ed_pins.sh"
  printf 'ed_pins "$1" "$2"\n'; } > "$SBX/harness.sh"

fresh_pins() {
  printf 'RS3_PINNED_VER="3.83.26"\nRS3_PINNED_SIZE=345795344\nRS3_PINNED_SHA256="deadbeef"\n' \
    > "$SBX/pins.env"
}

# Happy path: an existing key is rewritten and the new line is really present.
fresh_pins
PINS="$SBX/pins.env" bash "$SBX/harness.sh" "RS3_PINNED_SIZE" "RS3_PINNED_SIZE=349863872" 2>/dev/null
rc=$?
[ "$rc" -eq 0 ] && grep -qxF "RS3_PINNED_SIZE=349863872" "$SBX/pins.env" \
  && ok "rewrites an existing key" || bad "failed to rewrite an existing key (rc=$rc)"

# Other keys must be untouched — a rewriter that clobbers neighbours is its own bug.
grep -qxF 'RS3_PINNED_VER="3.83.26"' "$SBX/pins.env" \
  && ok "leaves other keys alone" || bad "clobbered a neighbouring key"

# No .bak left behind (it would get committed by the workflow's `git add`).
[ ! -f "$SBX/pins.env.bak" ] && ok "removes the sed .bak file" || bad ".bak file left behind"

# sed replacement metacharacters must survive intact. `&` means "the whole match" to sed, `\`
# escapes, and `|` is the delimiter, so an unescaped replacement writes something other than what
# was asked for while sed still exits 0. A pinned URL with a query string is the realistic case.
fresh_pins
url='RS3_PINNED_URL="https://example.test/get?file=RS3.exe&ver=1|2\3"'
printf 'RS3_PINNED_URL="https://old.example/x.exe"\n' >> "$SBX/pins.env"
PINS="$SBX/pins.env" bash "$SBX/harness.sh" "RS3_PINNED_URL" "$url" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -qxF "$url" "$SBX/pins.env" \
  && ok "& \\ and | in a value round-trip literally" || bad "metacharacters were mangled (rc=$rc)"

# A replacement that assigns a DIFFERENT key must be rejected. Otherwise ed_pins "A" "B=1" rewrites
# A's line to B=1 and the postcondition still passes, because it only checks the line is present —
# so a caller typo would silently rename a pin and drop the real one.
fresh_pins
before="$(cat "$SBX/pins.env")"
PINS="$SBX/pins.env" bash "$SBX/harness.sh" "RS3_PINNED_SIZE" "RS3_WRONG_KEY=1" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "replacement assigning a different key is fatal" || bad "key/line mismatch was accepted"
[ "$(cat "$SBX/pins.env")" = "$before" ] \
  && ok "pins.env untouched after a rejected key/line mismatch" || bad "pins.env was modified"
[ ! -f "$SBX/pins.env.bak" ] && ok "no .bak left behind" || bad ".bak left behind"
# Note: the restore-from-backup branch is defensive and not exercised here. With the replacement
# escaped and the key/line agreement enforced, there is no input that reaches sed and then fails the
# postcondition. It stays as insurance, not as tested behavior — don't claim coverage it lacks.

# THE #34 CASE: a key that does not exist must be fatal, not a silent no-op. This is the exact
# shape of the original bug — sed matched nothing and the script reported success anyway.
fresh_pins
PINS="$SBX/pins.env" bash "$SBX/harness.sh" "RS3_NOT_A_KEY" "RS3_NOT_A_KEY=1" >/dev/null 2>&1
[ $? -ne 0 ] && ok "missing key is fatal (the #34 silent no-op)" || bad "missing key silently succeeded"

# A multi-line replacement is what the broken stat produced. It must be rejected outright rather
# than fed to sed, where it produces an unterminated s command and leaves the pin stale.
fresh_pins
PINS="$SBX/pins.env" bash "$SBX/harness.sh" "RS3_PINNED_SIZE" "$(printf 'RS3_PINNED_SIZE=1\nBlock size: 4096')" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "multi-line replacement is fatal" || bad "multi-line replacement was accepted"
grep -qxF 'RS3_PINNED_SIZE=345795344' "$SBX/pins.env" \
  && ok "pins.env untouched after a rejected rewrite" || bad "pins.env was modified by a rejected rewrite"

echo "unit-update-pins: $P passed, $F failed"
[ "$F" -eq 0 ]
