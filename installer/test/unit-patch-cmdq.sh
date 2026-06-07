#!/bin/bash
# unit-patch-cmdq.sh — patch-wine-cmdq.py flips ONLY the Quit ⌘⌥Q site to ⌘Q, is idempotent,
# and fails loudly when the expected pattern is absent or ambiguous. The real winemac.so is
# downloaded at build time, so we exercise the patcher against synthetic Mach-O-like fixtures
# carrying the two distinguishable 0x180000 instruction sequences (Quit vs Hide Others).
_T_NAME="unit-patch-cmdq"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$HERE/../build/patch-wine-cmdq.py"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3cmdq.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

# Build a fixture. $1=output, $2=number of Quit sites (0/1/2). Always includes one Hide-Others site.
mkfix() {
python3 - "$1" "$2" <<'PY'
import sys
out, nquit = sys.argv[1], int(sys.argv[2])
tail = bytes.fromhex("4889C7")                                            # mov rdi, rax
quit_seq = bytes.fromhex("BA00001800") + tail + bytes.fromhex("488B35") + b"\x10\x20\x30\x40"  # ...mov rsi,[rip+disp]
hide_seq = bytes.fromhex("BA00001800") + tail + bytes.fromhex("41FFD4")   # ...call *r12
blob = b"\xcf\xfa\xed\xfe" + b"\x00" * 60 + hide_seq + b"\x90" * 32
for _ in range(nquit):
    blob += quit_seq + b"\x90" * 16
open(out, "wb").write(blob)
PY
}

# assert_bytes <file> — Quit run is patched to 0x100000 exactly once, Hide-Others stays 0x180000.
assert_bytes() {
python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
quit_patched = bytes.fromhex("BA00001000") + bytes.fromhex("4889C7") + bytes.fromhex("488B35")
hide_un      = bytes.fromhex("BA00001800") + bytes.fromhex("4889C7") + bytes.fromhex("41FFD4")
assert d.count(quit_patched) == 1, "Quit not patched to 0x100000"
assert d.count(hide_un) == 1, "Hide Others must remain 0x180000"
PY
}

# --- happy path: exactly one Quit site ---
FIX="$SBX/one.bin"; mkfix "$FIX" 1
python3 "$PATCHER" "$FIX" >/dev/null 2>&1 && ok "patches a single Quit site (exit 0)" || bad "patch failed on valid fixture"
assert_bytes "$FIX" && ok "Quit -> ⌘Q and Hide Others untouched" || bad "Quit/Hide bytes wrong after patch"

# --- idempotency: re-run is a clean no-op ---
python3 "$PATCHER" "$FIX" 2>&1 | grep -q 'already patched' && ok "idempotent re-run (no-op)" || bad "second run not idempotent"

# --- fail-loud: no Quit site ---
FIX0="$SBX/none.bin"; mkfix "$FIX0" 0
python3 "$PATCHER" "$FIX0" >/dev/null 2>&1 && bad "should fail when no Quit site present" || ok "fails loudly with zero Quit sites"

# --- fail-loud: ambiguous (two Quit sites) ---
FIX2="$SBX/two.bin"; mkfix "$FIX2" 2
python3 "$PATCHER" "$FIX2" >/dev/null 2>&1 && bad "should fail when Quit site ambiguous" || ok "fails loudly with two Quit sites"

# --- fail-loud: mixed state (one unpatched + one already-patched = total 2) ---
FIXM="$SBX/mixed.bin"
python3 - "$FIXM" <<'PY'
import sys
un  = bytes.fromhex("BA00001800") + bytes.fromhex("4889C7") + bytes.fromhex("488B35")
pat = bytes.fromhex("BA00001000") + bytes.fromhex("4889C7") + bytes.fromhex("488B35")
open(sys.argv[1], "wb").write(b"\xcf\xfa\xed\xfe" + b"\x00" * 40 + un + b"\x90" * 16 + pat + b"\x90" * 16)
PY
python3 "$PATCHER" "$FIXM" >/dev/null 2>&1 && bad "should fail on mixed patched+unpatched" || ok "fails loudly on mixed state (total 2)"

echo "unit-patch-cmdq: $P passed, $F failed"
[ "$F" -eq 0 ]
