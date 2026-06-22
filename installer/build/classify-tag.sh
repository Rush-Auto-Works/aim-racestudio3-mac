#!/usr/bin/env bash
# classify-tag.sh — single source of truth for how a release tag maps to two CI decisions:
#   • is_usb        — build the gated USB (WinUSB) modules into the DMG
#   • is_prerelease — publish the GitHub release as a prerelease (never "latest")
#
# WHY THIS EXISTS: the build-content gate and the publish gate used to be two independent
# expressions in release-dmg.yml (a YAML `if:` and a bash `case`). They drifted — one was
# digit-anchored, the other a substring — so a malformed tag like `v3.83.20-5-usb` would build
# USB content yet publish as the public "latest" download (unverified USB to every user). Deriving
# both flags from THIS one predicate set makes that divergence impossible, and makes it testable
# (unit-classify-tag.sh). The workflow calls this and appends the output straight to $GITHUB_OUTPUT.
#
# Tag contract (Debian/RPM-style v<rs3ver>-<pkgrev> plus an optional prerelease suffix):
#   v3.83.20-5            → stable        (is_usb=false is_prerelease=false → latest)
#   v3.83.20-5-usb1       → USB tester    (is_usb=true  is_prerelease=true)
#   v3.83.20-5-rc1/-beta1 → prerelease    (is_prerelease=true)
#   v3.83.20-5-test[...]  → prerelease    (unnumbered allowed for ad-hoc test tags)
# Numbered suffixes are digit-anchored so a stray "-usb"/"-rc" inside a longer token can't trip a
# flag; only the canonical "-usb<N>" form ever builds USB or marks USB-prerelease.
#
# Usage:
#   bash classify-tag.sh "<tag>"            # prints two GITHUB_OUTPUT lines on stdout
#   bash classify-tag.sh "<tag>" >> "$GITHUB_OUTPUT"
set -euo pipefail

tag="${1:-}"
is_usb=false
is_prerelease=false

case "$tag" in *-usb[0-9]*) is_usb=true ;; esac
case "$tag" in
  *-rc[0-9]*|*-beta[0-9]*|*-usb[0-9]*|*-test*) is_prerelease=true ;;
esac

# Invariant: a USB build is ALWAYS a prerelease. Guarantees the two gates can never disagree on the
# "USB must not ship as latest" rule even if the patterns above are edited inconsistently later.
[ "$is_usb" = true ] && is_prerelease=true

printf 'is_usb=%s\nis_prerelease=%s\n' "$is_usb" "$is_prerelease"
