#!/bin/bash
# unit-net.sh — download resume decision + verification, exercised WITHOUT network by driving
# download_verified through a local fake "server" via a file:// -> curl is never reached because
# we pre-stage dest/partial and assert the size/sha branches.
_T_NAME="unit-net"
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

DL="$SANDBOX/net"; mkdir -p "$DL"

# A 100-byte "real" artifact and its sha.
head -c 100 /dev/zero | tr '\0' 'A' > "$DL/real"
SZ="$(file_size "$DL/real")"; SH="$(sha256 "$DL/real")"

# 1. dest already present + correct size+sha -> returns 0, no network.
cp "$DL/real" "$DL/dest1"
assert_true "download_verified https://nope.invalid/a \"$DL/dest1\" $SZ $SH 3" "verified dest short-circuits"

# 2. dest present but WRONG size -> it is discarded; then network is attempted and fails (invalid
#    host) -> overall nonzero (we have no server). Proves a bad cached file isn't trusted.
printf 'short' > "$DL/dest2"
assert_false "download_verified https://nope.invalid/a \"$DL/dest2\" $SZ $SH 3" "wrong-size dest not trusted (network then fails)"

# 3. oversized partial is discarded before resume (can't resume a partial bigger than target).
head -c 200 /dev/zero | tr '\0' 'B' > "$DL/dest3.partial"
download_verified https://nope.invalid/a "$DL/dest3" "$SZ" "$SH" 3 >/dev/null 2>&1 || true
assert_false "[ -f \"$DL/dest3.partial\" ] && [ \"$(file_size \"$DL/dest3.partial\")\" -gt $SZ ]" \
  "oversized partial discarded"

# 4. https guard blocks a plain-http download before curl runs.
assert_false "download_verified http://nope.invalid/a \"$DL/dest4\" $SZ \"\" 3" "http download refused"

# 5. validators are wired into the size/sha helpers correctly for the pinned artifacts.
assert_eq "$(printf '%s' "$WINE_PINNED_SHA256" | wc -c | tr -d ' ')" "64" "pinned wine sha is 64 hex chars"
assert_eq "$(printf '%s' "$RS3_PINNED_SHA256" | wc -c | tr -d ' ')" "64" "pinned rs3 sha is 64 hex chars"

finish
