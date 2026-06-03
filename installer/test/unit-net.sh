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

# 6. rs3_url_from_html (the stale-URL self-heal parser). A page that lists several versions, with
#    the pinned file served from a DIFFERENT directory than RS3_PINNED_URL (the exact prod bug).
PAGE_HTML='<html><body>
 <a href="https://www.aim-sportline.com/aim-software-betas/Software/Applications/WebUpdater/release/RaceStudio3-64_38320_000000_000000_20260528_145224.exe">latest</a>
 <a href="https://www.aim-sportline.com/aim-software-betas/Software/Applications/WebUpdater/release/RaceStudio3-64_38312_000000_000000_20260521_151606.exe">older</a>
 <a href="../pdf/racestudio3-docs-en-latest.pdf">docs</a>
</body></html>'

# exact pinned filename resolves to its real URL even though it isn't the one in pins.env's path.
assert_eq "$(rs3_url_from_html "$PAGE_HTML" "$RS3_PINNED_FILE")" \
  "https://www.aim-sportline.com/aim-software-betas/Software/Applications/WebUpdater/release/$RS3_PINNED_FILE" \
  "parser resolves pinned file to its live (moved) URL"

# the resolved URL must end in exactly the pinned filename (no other version picked up).
assert_eq "$(rs3_url_from_html "$PAGE_HTML" "$RS3_PINNED_FILE" | sed 's#.*/##')" "$RS3_PINNED_FILE" \
  "parser never returns a different version"

# a filename not on the page -> empty + nonzero (caller then falls through to manual download).
assert_eq "$(rs3_url_from_html "$PAGE_HTML" "RaceStudio3-64_99999_000000_000000_20260101_000000.exe")" "" \
  "parser returns empty for a file not on the page"

# command-injection / bogus filename is rejected by the validate_rs3_asset guard before regex use.
assert_false "rs3_url_from_html \"\$PAGE_HTML\" 'evil; rm -rf /.exe'" "parser rejects unsafe filename"
assert_false "rs3_url_from_html \"\$PAGE_HTML\" 'RaceStudio3.exe'"   "parser rejects non-matching asset name"

# the network wrapper refuses a non-HTTPS page before fetching.
assert_false "rs3_url_from_page 'http://nope.invalid/page.html' \"\$RS3_PINNED_FILE\"" "scrape refuses non-HTTPS page"

# 7. the pin's own URL must end in the pinned filename (cheap guard against a name/URL mismatch).
assert_eq "$(printf '%s' "$RS3_PINNED_URL" | sed 's#.*/##')" "$RS3_PINNED_FILE" "pinned URL ends in pinned filename"
assert_true "https_guard \"\$RS3_PINNED_URL\"" "pinned URL is https"

finish
