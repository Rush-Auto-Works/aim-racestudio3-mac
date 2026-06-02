#!/bin/bash
# unit-validators.sh — string validators, HTTPS guard, size/sha helpers.
_T_NAME="unit-validators"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# version
assert_true  "validate_version 11.9"        "version 11.9"
assert_true  "validate_version 3.83.20"     "version 3.83.20"
assert_false "validate_version 11"          "reject bare major"
assert_false "validate_version '11.9; rm'"  "reject injection"
assert_false "validate_version ''"          "reject empty"

# wine asset
assert_true  "validate_wine_asset wine-staging-11.9-osx64.tar.xz" "wine staging asset"
assert_true  "validate_wine_asset wine-stable-10.0-osx64.tar.xz"  "wine stable asset"
assert_false "validate_wine_asset wine-staging-11.9-osx64.tar.xz.evil" "reject trailing"
assert_false "validate_wine_asset 'wine-11.tar.xz'"               "reject malformed"

# rs3 asset
assert_true  "validate_rs3_asset RaceStudio3-64_38320_000000_000000_20260528_145224.exe" "rs3 asset"
assert_false "validate_rs3_asset 'evil.exe'"                      "reject non-rs3"
assert_false "validate_rs3_asset 'RaceStudio3-64_38320.exe; rm -rf'" "reject injection"

# https guard
assert_true  "https_guard https://example.com/x" "allow https"
assert_false "https_guard http://example.com/x"  "reject http"
assert_false "https_guard 'file:///etc/passwd'"  "reject file://"
assert_false "https_guard 'ftp://x/y'"           "reject ftp"

# size + sha against real pinned artifacts if present (best-effort, skipped if absent)
WT="/tmp/claude/wine11.tar.xz"
if [ -f "$WT" ]; then
  assert_eq "$(file_size "$WT")" "$WINE_PINNED_SIZE" "wine tarball size matches pin"
  assert_eq "$(sha256 "$WT")" "$WINE_PINNED_SHA256"  "wine tarball sha matches pin"
fi
RS="$HOME/Downloads/RaceStudio3-64_38320.exe"
if [ -f "$RS" ]; then
  assert_eq "$(file_size "$RS")" "$RS3_PINNED_SIZE"  "rs3 installer size matches pin"
  assert_eq "$(sha256 "$RS")" "$RS3_PINNED_SHA256"   "rs3 installer sha matches pin"
fi

# download_verified short-circuits when dest already verified (no network)
mkdir -p "$SANDBOX/dl"
printf 'abc' > "$SANDBOX/dl/file"
SZ="$(file_size "$SANDBOX/dl/file")"; SH="$(sha256 "$SANDBOX/dl/file")"
assert_true "download_verified https://nope.invalid/x \"$SANDBOX/dl/file\" $SZ $SH 5" \
  "download_verified skips network when dest pre-verified"

finish
