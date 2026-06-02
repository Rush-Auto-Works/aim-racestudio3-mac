#!/bin/bash
# e2e-local.sh — REAL end-to-end install with NO network, by pre-seeding the installer cache
# with the locally-present, sha-verified Wine tarball + RS3 installer. Runs real wineboot, real
# silent RS3 install, real data relocation, and a --repair resume — all into a TMPDIR sandbox so
# nothing real is touched. This is the unattended Phase 2 + Phase 3 verification.
#
# Requires (verified this session):
#   /tmp/claude/wine11.tar.xz                  (Gcenx wine-staging 11.9, sha-pinned)
#   ~/Downloads/RaceStudio3-64_38320.exe       (RS3 3.83.20, sha-pinned)
# Run it directly:  bash installer/test/e2e-local.sh   (takes several minutes under Rosetta)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HERE/../src"
. "$SRC_DIR/pins.env"

WINE_TARBALL="/tmp/claude/wine11.tar.xz"
RS3_EXE="$HOME/Downloads/RaceStudio3-64_38320.exe"

SBX="$(mktemp -d "${TMPDIR:-/tmp}/rs3e2e.XXXXXX")"
KEEP="${RS3_E2E_KEEP:-0}"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$SBX" 2>/dev/null || true; }
trap cleanup EXIT

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }
bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

echo "e2e sandbox: $SBX"
# exit 77 = SKIP (distinct from a passing run) so "didn't run" never looks like success.
[ -f "$WINE_TARBALL" ] || { echo "SKIP: missing $WINE_TARBALL"; exit 77; }
[ -f "$RS3_EXE" ]      || { echo "SKIP: missing $RS3_EXE"; exit 77; }

APPSUP="$SBX/app-support"
DATA="$SBX/Documents/AIM_SPORT"
APPS="$SBX/Applications"
CACHE="$APPSUP/installer"
mkdir -p "$CACHE"

# Pre-seed the cache with VERIFIED files under the exact pinned names so download_verified()
# size+sha checks pass and the network is never touched.
echo "==> pre-seeding cache (no network will be used)"
ditto "$WINE_TARBALL" "$CACHE/$(basename "$WINE_PINNED_URL")"
ditto "$RS3_EXE"      "$CACHE/$RS3_PINNED_FILE"

core() { RS3_APP_SUPPORT="$APPSUP" RS3_DATA_DIR="$DATA" RS3_APPS_DIR="$APPS" \
         bash "$SRC_DIR/installer-core.sh" "$@"; }

echo "==> phase: acquire-installer (should use cached, no net)"
core acquire-installer || bad "acquire-installer failed"

echo "==> phase: download-wine (extract cached tarball, glob binary)"
core download-wine || bad "download-wine failed"
WB="$(find "$APPSUP/wine" -type f \( -name wine -o -name wine64 \) -path '*/bin/*' 2>/dev/null | head -1)"
[ -n "$WB" ] && ok "wine binary present: $WB" || bad "wine binary missing"
arch -x86_64 "$WB" --version >/dev/null 2>&1 && ok "wine --version runs" || bad "wine --version failed"

echo "==> phase: make-prefix (real wineboot --init under Rosetta — slow)"
core make-prefix || bad "make-prefix failed"
[ -f "$APPSUP/prefix/system.reg" ] && ok "prefix created" || bad "prefix missing"

echo "==> phase: silent-install (real RS3 /exenoui /qn — several minutes)"
core silent-install || bad "silent-install failed"
EXE="$APPSUP/prefix/drive_c/AIM_SPORT/RaceStudio3/64/AiMRS3-64-ReleaseU.exe"
[ -f "$EXE" ] && ok "RS3 exe installed" || bad "RS3 exe missing"
file "$EXE" | grep -q 'PE32+ executable' && ok "RS3 exe valid PE32+" || bad "RS3 exe bad header"

echo "==> phase: relocate-data (atomic, into $DATA)"
core relocate-data || bad "relocate-data failed"
USERLINK="$APPSUP/prefix/drive_c/AIM_SPORT/RaceStudio3/user"
[ -L "$USERLINK" ] && [ "$(readlink "$USERLINK")" = "$DATA" ] && ok "user/ symlinked to data dir" || bad "user/ not symlinked"
[ -d "$DATA" ] && ok "data dir populated" || bad "data dir missing"

echo "==> phase: make-launcher"
core make-launcher || bad "make-launcher failed"
[ -f "$APPSUP/bin/launch.sh" ] && ok "launch.sh written" || bad "launch.sh missing"

echo "==> resume test: delete the 'installed' marker, run --repair, confirm it recovers"
rm -f "$APPSUP/state/installed.ok"
core --repair || bad "--repair failed"
[ -f "$APPSUP/state/installed.ok" ] && ok "--repair re-verified install" || bad "--repair did not restore marker"

echo "==> no ~/.wine created by the run"
[ ! -d "$HOME/.wine" ] && ok "no ~/.wine" || echo "  note: ~/.wine exists (may predate this test)"

echo "==> data-preservation on reinstall: drop a user file, reinstall engine, confirm data kept"
printf 'my-lap\n' > "$DATA/keep.xrk"
if RS3_ASSUME_YES=1 core --reinstall >/dev/null 2>&1; then ok "--reinstall succeeded"; else bad "--reinstall failed"; fi
[ -f "$DATA/keep.xrk" ] && ok "reinstall kept user data" || bad "reinstall LOST user data"

echo "e2e-local: $P passed, $F failed   (sandbox: $SBX, KEEP=$KEEP)"
[ "$F" -eq 0 ]
