#!/bin/bash
# unit-classify-tag.sh — the release-tag classifier maps tags to (is_usb, is_prerelease) correctly.
# This is the regression guard for the divergence bug the debate caught: the USB-build gate and the
# publish prerelease gate must agree, and a USB build must NEVER be publishable as a stable "latest"
# release. classify-tag.sh is the single predicate both CI gates consume.
_T_NAME="unit-classify-tag"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLS="$HERE/../build/classify-tag.sh"

P=0; F=0
ok(){ P=$((P+1)); echo "  ok   $1"; }; bad(){ F=$((F+1)); echo "  FAIL $1" >&2; }

[ -f "$CLS" ] || { echo "  FAIL classify-tag.sh not found at $CLS" >&2; exit 1; }

# expect <tag> <want_usb> <want_prerelease>
expect() {
  local tag="$1" wu="$2" wp="$3" out gu gp
  out="$(bash "$CLS" "$tag")" || { bad "$tag: classifier exited nonzero"; return; }
  gu="$(printf '%s\n' "$out" | sed -n 's/^is_usb=//p')"
  gp="$(printf '%s\n' "$out" | sed -n 's/^is_prerelease=//p')"
  [ "$gu" = "$wu" ] && ok "$tag → is_usb=$gu" || bad "$tag → is_usb=$gu (want $wu)"
  [ "$gp" = "$wp" ] && ok "$tag → is_prerelease=$gp" || bad "$tag → is_prerelease=$gp (want $wp)"
  # Cross-cutting invariant: a USB build is always a prerelease.
  if [ "$gu" = true ] && [ "$gp" != true ]; then bad "$tag → USB build NOT marked prerelease (would ship as latest!)"; fi
}

#       tag                     usb     prerelease
expect  "v3.83.20-5"            false   false      # stable → latest
expect  "v3.83.20-5-usb1"       true    true       # canonical USB tester build
expect  "v3.83.20-usb1"         true    true       # USB without an explicit pkg-rev suffix
expect  "v3.83.20-5-rc1"        false   true       # release candidate
expect  "v3.83.20-5-beta1"      false   true       # beta
expect  "v3.83.20-5-test"       false   true       # bare test tag (unnumbered allowed)
expect  "v3.83.20-5-test2"      false   true       # numbered test tag
# The divergence cases the debate flagged: a malformed/unnumbered -usb must NOT build USB and must
# NOT be a USB build masquerading as latest. Unnumbered -usb/-rc/-beta are simply not USB and not
# prerelease (they fall through to stable) — but crucially never "USB content shipped as latest".
expect  "v3.83.20-5-usb"        false   false      # no digit → not a USB build (so latest is safe)
expect  "v3.83.20-5-usbX"       false   false      # non-digit suffix → not a USB build
expect  "v3.83.20-1usb1"        false   false      # no dash before usb → not USB

echo "$_T_NAME: $P passed, $F failed"
[ "$F" -eq 0 ]
