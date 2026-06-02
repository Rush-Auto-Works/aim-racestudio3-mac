# test/harness.sh — shared test scaffolding. Source this from each unit test.
# Provides: sandbox dirs, assert helpers, a PASS/FAIL tally. Self-cleans via trap (rm runs
# INSIDE this subprocess — no interactive prompt).

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)"
UI_MODE=dryrun   # no osascript during tests

# sandbox root under TMPDIR (always writable, auto-pruned)
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rs3test.XXXXXX")"
trap 'rm -rf "$SANDBOX" 2>/dev/null || true' EXIT

# Load the engine libraries (pins first for constants, then libs).
# shellcheck source=/dev/null
. "$SRC_DIR/pins.env"
for m in ui net wine ledger data preflight; do . "$SRC_DIR/lib/$m.sh"; done

# Redirect every install location into the sandbox so nothing real is touched.
APP_SUPPORT="$SANDBOX/app-support"
INSTALL_ROOT="$APP_SUPPORT"
PREFIX="$INSTALL_ROOT/prefix"
WINE_ROOT="$INSTALL_ROOT/wine"
STATE_DIR="$INSTALL_ROOT/state"
CONFIG_ENV="$STATE_DIR/config.env"
DATA_DIR="$SANDBOX/Documents/AIM_SPORT"
mkdir -p "$STATE_DIR"

# ---- assertions ----------------------------------------------------------------------------
_T_PASS=0; _T_FAIL=0; _T_NAME="${_T_NAME:-test}"

_ok()   { _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "$1"; }
_fail() { _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

assert_true()   { if eval "$1"; then _ok "${2:-$1}"; else _fail "${2:-$1}"; fi; }
assert_false()  { if eval "$1"; then _fail "${2:-not($1)}"; else _ok "${2:-not($1)}"; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then _ok "${3:-eq}"; else _fail "${3:-eq}: '$1' != '$2'"; fi; }
assert_file()   { if [ -f "$1" ]; then _ok "file $1"; else _fail "file missing $1"; fi; }
assert_dir()    { if [ -d "$1" ]; then _ok "dir $1"; else _fail "dir missing $1"; fi; }
assert_symlink_to() { # <link> <target>
  if [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]; then _ok "symlink $1 -> $2";
  else _fail "symlink $1 -> $2 (got '$(readlink "$1" 2>/dev/null)')"; fi; }
assert_absent() { if [ ! -e "$1" ]; then _ok "absent $1"; else _fail "should be absent $1"; fi; }

# end-of-file summary; sets exit code
finish() {
  printf '%s: %d passed, %d failed\n' "$_T_NAME" "$_T_PASS" "$_T_FAIL"
  [ "$_T_FAIL" -eq 0 ]
}

# ---- fixtures ------------------------------------------------------------------------------
# Build a fake fresh-install user/ tree inside the prefix (what RS3 silent-install leaves).
make_fresh_user() {
  local u="$PREFIX/drive_c/$RS3_REL_USER"
  mkdir -p "$u/cfgs" "$u/system" "$u/profiles"
  printf 'default-config\n' > "$u/cfgs/default.zconfig"
  printf 'sys\n'            > "$u/system/settings.ini"
  : > "$u/profiles/.empty"          # zero-byte file (zero-byte handling test)
  printf 'me\n'            > "$u/profiles/driver.prof"
  printf '%s' "$u"
}
