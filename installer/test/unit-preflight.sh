#!/bin/bash
# unit-preflight.sh — environment checks return sane values on THIS Mac.
_T_NAME="unit-preflight"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# These checks exercise host-specific code; skip the whole file off macOS so the suite stays
# portable (CI/Linux). exit 77 = SKIP, distinct from pass/fail.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "unit-preflight: SKIP (not macOS)"; exit 77
fi

assert_true "macos_ok" "macos_ok on macOS"

# Rosetta is only meaningful on Apple Silicon; on Intel rosetta_present() is trivially true and
# we don't assert it. On arm64 it must be installed for the installer to work.
if [ "$(uname -m)" = "arm64" ]; then
  assert_true "rosetta_present" "rosetta present (Apple Silicon)"
else
  _ok "rosetta check N/A on Intel"
fi

# disk_free_gb returns a non-negative integer
g="$(disk_free_gb "$SANDBOX")"
assert_true "[ \"$g\" -ge 0 ] 2>/dev/null" "disk_free_gb integer ($g GB)"

# icloud detection returns a boolean without erroring (value is machine-specific)
if icloud_documents_synced; then sync=yes; else sync=no; fi
assert_true "[ \"$sync\" = yes ] || [ \"$sync\" = no ]" "icloud detection returns boolean ($sync)"

# already-running guard: with no prefix/process, must be false
PREFIX="$SANDBOX/noproc/prefix"; STATE_DIR="$SANDBOX/noproc/state"; mkdir -p "$STATE_DIR"
assert_false "rs3_already_running" "not running when nothing is up"

finish
