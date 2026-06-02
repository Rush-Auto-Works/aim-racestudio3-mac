#!/bin/bash
# build-apps.sh — build the single "RaceStudio 3.app" (install-on-first-run + launcher + import
# droplet), give it a Rush-branded icon, codesign (hardened runtime), notarize+staple if creds
# are present, then wrap it in a drag-to-Applications DMG with a Rush logo + arrow background.
#
# Output (installer/dist/):
#   RaceStudio 3.app      the app (drag to /Applications)
#   RaceStudio 3.dmg      the branded, drag-to-Applications disk image (what you distribute)
#
# Codesigning is unattended once the keychain is authorized (first codesign pops a one-time
# "use this key" dialog — click Always Allow, or pre-authorize with security set-key-partition-list).
# Notarization needs an app-specific password; without it the script signs + builds the DMG and
# prints the exact notarytool commands.
#
# Usage:
#   bash installer/build/build-apps.sh                  # sign + DMG; notarize if creds
#   NOTARY_PROFILE=rush-notary bash …/build-apps.sh     # also notarize + staple (app and DMG)
#   SKIP_SIGN=1 bash …/build-apps.sh                    # compile only (no sign, no DMG)
#   NO_TIMESTAMP=1 …                                    # local sign without the TSA (NOT notarizable)
#   NO_DMG=1 …                                          # skip the DMG step

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../src"
DIST="$HERE/../dist"
ASSETS="$HERE/assets"

IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Samuel Reed (HYBSCYDCMB)}"
TEAMID="HYBSCYDCMB"
BUNDLE_ID="com.rushautoworks.racestudio3"
MIN_OS="12.0"
VERSION="1.0.0"

APP="$DIST/RaceStudio 3.app"
VOL="RaceStudio 3"
DMG="$DIST/RaceStudio 3.dmg"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---- 0. compile -----------------------------------------------------------------------------
say "Compiling RaceStudio3.applescript -> $APP"
rm -rf "$DIST"; mkdir -p "$DIST"
osacompile -o "$APP" "$SRC/RaceStudio3.applescript" || { echo "osacompile failed"; exit 1; }

# ---- 1. embed the tested engine -------------------------------------------------------------
say "Embedding engine"
RES="$APP/Contents/Resources"
mkdir -p "$RES/lib"
ditto "$SRC/installer-core.sh" "$RES/installer-core.sh"
ditto "$SRC/pins.env"          "$RES/pins.env"
ditto "$SRC/lib"               "$RES/lib"
chmod +x "$RES/installer-core.sh"

# ---- 2. icon (dark rounded square + Rush logo) ----------------------------------------------
say "Building app icon"
PYVENV="${PYVENV:-/tmp/rs3-build-venv}"
if [ ! -x "$PYVENV/bin/python" ]; then python3 -m venv "$PYVENV" && "$PYVENV/bin/python" -m pip install -q Pillow; fi
PY="$PYVENV/bin/python"
ICON_PNG="$DIST/icon-src.png"
"$PY" "$HERE/compose-icon.py" "$ASSETS/logo-square.png" "$ICON_PNG"
ICONSET="$DIST/rs3.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"   # must NOT be hidden (iconutil rejects dot-dirs)
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
  sips -z $((s*2)) $((s*2))   "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/applet.icns" || { echo "iconutil failed"; exit 1; }
rm -rf "$ICONSET" "$ICON_PNG"

# ---- 3. Info.plist --------------------------------------------------------------------------
PL="$APP/Contents/Info.plist"
pset() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $3 $2" "$PL"; }
pset CFBundleIdentifier "$BUNDLE_ID" string
pset CFBundleName "RaceStudio 3" string
pset CFBundleShortVersionString "$VERSION" string
pset LSMinimumSystemVersion "$MIN_OS" string
pset CFBundleIconFile "applet" string

if [ "${SKIP_SIGN:-0}" = 1 ]; then say "SKIP_SIGN=1 — compiled only."; exit 0; fi

# ---- 4. codesign ----------------------------------------------------------------------------
# NOTE (one-time): the first codesign with your Developer ID key pops a keychain dialog — click
# "Always Allow". Headless pre-auth: security unlock-keychain + set-key-partition-list
#   -S apple-tool:,apple:,codesign: -s -k "<pw>" ~/Library/Keychains/login.keychain-db
have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAMID"; }
if ! have_identity; then say "No Developer ID ($TEAMID) in keychain — compiled only in $DIST."; exit 0; fi
TS="--timestamp"; [ "${NO_TIMESTAMP:-0}" = 1 ] && TS=""
say "Codesigning (hardened runtime)"
# shellcheck disable=SC2086
codesign --force --options runtime $TS --sign "$IDENTITY" "$APP" || { echo "codesign failed"; exit 1; }
codesign --verify --deep --strict "$APP" && say "signature verifies"

# ---- 5. notarize + staple (if creds) --------------------------------------------------------
NOTARY_ARGS=""
if [ -n "${NOTARY_PROFILE:-}" ]; then NOTARY_ARGS="--keychain-profile $NOTARY_PROFILE"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS="--apple-id $NOTARY_APPLE_ID --password $NOTARY_PASSWORD --team-id $TEAMID"; fi
notarize_staple() { # <path>
  [ -n "$NOTARY_ARGS" ] || return 2
  local t="$1" zip="$1.notarize.zip"
  say "Notarizing $(basename "$t") (waits for Apple)…"
  if [ "${t##*.}" = "app" ]; then ditto -c -k --keepParent "$t" "$zip"; else cp "$t" "$zip"; fi
  # shellcheck disable=SC2086
  if xcrun notarytool submit "$zip" $NOTARY_ARGS --wait; then
    [ "${t##*.}" = "app" ] && rm -f "$zip"
    xcrun stapler staple "$t" && say "stapled $(basename "$t")"
  else echo "notarytool failed for $t"; rm -f "$zip"; return 1; fi
}
notarize_staple "$APP" || true

# ---- 6. branded drag-to-Applications DMG ----------------------------------------------------
if [ "${NO_DMG:-0}" = 1 ]; then say "NO_DMG=1 — skipping DMG."; exit 0; fi
say "Composing DMG background"
BG="$DIST/.bg.png"
"$PY" "$HERE/compose-dmg-bg.py" "$ASSETS/logo-wide-black.png" "$BG"

say "Staging DMG contents"
STAGE="$DIST/.dmgstage"; rm -rf "$STAGE"; mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/RaceStudio 3.app"
ln -s /Applications "$STAGE/Applications"
cp "$BG" "$STAGE/.background/bg.png"

RW="$DIST/.rw.dmg"; rm -f "$RW" "$DMG"
# a stale mount of the same volume name makes `hdiutil create` fail "Resource busy" — detach first
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null || { echo "hdiutil create failed"; exit 1; }
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOL"
sleep 1
# hygiene: drop volume cruft so it never shows (matters for users who enable hidden files)
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true

# Lay out the Finder window. NOTE: this scripts Finder and may pop a one-time macOS Automation
# permission prompt ("…wants to control Finder") — approve it. If it fails, the DMG is still
# functional (white background blends, just without fixed icon positions).
osascript <<OSA || say "Finder layout skipped (automation not permitted) — DMG still works."
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {220, 140, 860, 563}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 12
    set background picture of vo to file ".background:bg.png"
    set position of item "RaceStudio 3.app" of container window to {160, 190}
    set position of item "Applications" of container window to {480, 190}
    try
      set position of item ".background" of container window to {999, 999}
    end try
    close
    open
    delay 1
    update without registering applications
    delay 2
  end tell
end tell
OSA
sync; sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
say "Compressing DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW" "$BG"; rm -rf "$STAGE"

# sign + (optionally) notarize the DMG itself so it's stapled for offline Gatekeeper
codesign --force --sign "$IDENTITY" $TS "$DMG" 2>/dev/null && say "DMG signed"
notarize_staple "$DMG" || true

say "Built: $DMG"
if [ -z "$NOTARY_ARGS" ]; then cat <<EOF

$(say "Signed but NOT notarized — no notarytool credential found.")
Create an app-specific password at https://appleid.apple.com, then:
  xcrun notarytool store-credentials rush-notary --apple-id "<you>" --team-id $TEAMID --password "<app-specific>"
  NOTARY_PROFILE=rush-notary bash installer/build/build-apps.sh
That notarizes + staples the app AND the DMG (no Gatekeeper prompt on download).
EOF
fi
ls -1 "$DIST"
