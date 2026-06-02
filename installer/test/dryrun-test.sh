#!/bin/bash
# dryrun-test.sh — installer-core.sh --dry-run must validate logic with NO network calls and
# NO writes outside the sandboxed install root. CI-able.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/../src"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3dry.XXXXXX")"
trap 'rm -rf "$SBX" 2>/dev/null || true' EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

APPSUP="$SBX/app-support"
DATA="$SBX/Documents/AIM_SPORT"
APPS="$SBX/Applications"

# Snapshot the REAL locations so we can prove they are untouched.
REAL_APPSUP="$HOME/Library/Application Support/RaceStudio3"
real_before="$( [ -e "$REAL_APPSUP" ] && stat -f %m "$REAL_APPSUP" 2>/dev/null || echo none )"

out="$SBX/out.txt"
RS3_APP_SUPPORT="$APPSUP" RS3_DATA_DIR="$DATA" RS3_APPS_DIR="$APPS" \
  bash "$SRC_DIR/installer-core.sh" --dry-run run >"$out" 2>&1
rc=$?

[ "$rc" -eq 0 ] && ok "--dry-run run exits 0" || { bad "--dry-run exit $rc"; cat "$out"; }

# Must mention all 8 progress steps
for s in 1 2 3 4 5 6 7 8; do
  grep -q "\[$s/8\]" "$out" && ok "progress step $s present" || bad "progress step $s missing"
done

# Must NOT have created a Wine engine or prefix (no network/extract happened)
[ ! -d "$APPSUP/wine" ]   && ok "no wine/ created in dry-run"   || bad "wine/ created in dry-run"
[ ! -d "$APPSUP/prefix" ] && ok "no prefix/ created in dry-run" || bad "prefix/ created in dry-run"
[ ! -e "$DATA" ]          && ok "no data dir created in dry-run" || bad "data dir created in dry-run"

# Real install location must be untouched
real_after="$( [ -e "$REAL_APPSUP" ] && stat -f %m "$REAL_APPSUP" 2>/dev/null || echo none )"
[ "$real_before" = "$real_after" ] && ok "real Application Support untouched" || bad "real Application Support changed!"

# No curl/network: dry-run should not have produced any *.partial files anywhere in sandbox
[ -z "$(find "$SBX" -name '*.partial' 2>/dev/null)" ] && ok "no downloads attempted" || bad "found *.partial (network ran)"

echo "dryrun-test: $P passed, $F failed"
[ "$F" -eq 0 ]
