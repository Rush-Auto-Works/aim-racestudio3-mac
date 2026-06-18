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
# Version stamped into the app/DMG = the embedded RaceStudio 3 version (from pins.env), so the
# bundle version matches the release tag. Override with RS3_VERSION if ever needed.
# (sed, not source: VERSION is needed here for Info.plist, before pins.env is sourced below.)
VERSION="${RS3_VERSION:-$(sed -nE 's/^RS3_PINNED_VER="(.*)"/\1/p' "$SRC/pins.env")}"
VERSION="${VERSION:-1.0.0}"
# Downstream packaging revision (Debian/RPM-style): increments on each rebuild of the SAME
# upstream RS3 version (new installer features/fixes), resets to 1 when AiM ships a new version.
# CFBundleShortVersionString stays the clean upstream VERSION; the rev rides in CFBundleVersion
# and the DMG filename, and the release is tagged v<VERSION>-<PKG_REV>.
PKG_REV="${RS3_PKG_REV:-$(sed -nE 's/^RS3_PKG_REV="(.*)"/\1/p' "$SRC/pins.env")}"
PKG_REV="${PKG_REV:-1}"
FULLVER="${VERSION}-${PKG_REV}"          # e.g. 3.83.20-2

APP="$DIST/RaceStudio 3.app"
VOL="RaceStudio 3"                       # mounted volume label (stays human-friendly)
DMG="$DIST/RaceStudio3-${FULLVER}.dmg"   # filename carries upstream+rev, e.g. RaceStudio3-3.83.20-2.dmg

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

# ---- 1b. bundle the Wine engine INSIDE the app ----------------------------------------------
# Bundling Wine lets first launch skip the ~190 MB Wine download. Extract the bare wine/ tree,
# NOT the Gcenx "Wine Staging.app" wrapper (we only want bin/, lib/, share/).
# NOTE: bundling alone does NOT rename the menu bar — the Wine GUI process runs unbundled
# (its image is lib/wine/<arch>-unix/wine), so macOS reads its app name from the Mach-O
# __TEXT,__info_plist section embedded in that loader, which ships CFBundleName="Wine".
# We rebrand the app menu by patching that embedded plist below (step 1c).
say "Bundling Wine engine (this is the big step)"
. "$SRC/pins.env"   # WINE_PINNED_URL / SIZE / SHA256
WINE_TARBALL="${WINE_TARBALL:-/tmp/claude/wine11.tar.xz}"
if [ ! -f "$WINE_TARBALL" ]; then
  WINE_TARBALL="$DIST/wine.tar.xz"
  say "downloading pinned Wine…"
  curl -fSL --proto '=https' -o "$WINE_TARBALL" "$WINE_PINNED_URL" || { echo "wine download failed"; exit 1; }
fi
TMPW="$DIST/winetmp"; rm -rf "$TMPW"; mkdir -p "$TMPW"
tar -xJf "$WINE_TARBALL" -C "$TMPW" || { echo "wine extract failed"; exit 1; }
WBIN="$(find "$TMPW" -type f -name wine -path '*/bin/wine' | head -1)"
[ -n "$WBIN" ] || { echo "wine binary not found in tarball"; exit 1; }
WTREE="$(dirname "$(dirname "$WBIN")")"   # .../wine  (the dir containing bin/, lib/, share/)
ditto "$WTREE" "$RES/wine"
xattr -dr com.apple.quarantine "$RES/wine" 2>/dev/null || true
rm -rf "$TMPW"
# RS3 is native + CEF — it never uses .NET (Wine-Mono) or the HTML engine (Wine-Gecko), and we
# disable both via WINEDLLOVERRIDES anyway. Dropping them cuts ~290 MB from the bundle.
rm -rf "$RES/wine/share/wine/gecko" "$RES/wine/share/wine/mono" 2>/dev/null || true
[ -x "$RES/wine/bin/wine" ] && say "bundled wine: Contents/Resources/wine/bin/wine" || { echo "bundled wine missing"; exit 1; }

# ---- 1c. rebrand the Wine app menu to "RaceStudio 3" ----------------------------------------
# Patch CFBundleName in every unix loader's embedded __info_plist (Wine ships "Wine"). This is
# what the bold top-left app menu reads, since the GUI process runs unbundled. Must run BEFORE
# signing (it edits the Mach-O, invalidating any signature — the sign pass below re-signs it).
say "Rebranding Wine app menu -> RaceStudio 3"
patched=0
while IFS= read -r loader; do
  python3 "$HERE/patch-wine-appname.py" "$loader" "RaceStudio 3" || { echo "appname patch failed for $loader"; exit 1; }
  patched=$((patched+1))
done < <(find "$RES/wine/lib/wine" -type f -name wine -path '*-unix/wine')
# fail fast: zero loaders means the Wine layout changed and the menu would still read "Wine".
[ "$patched" -gt 0 ] || { echo "no Wine unix loaders found to rebrand (looked for *-unix/wine under $RES/wine/lib/wine)"; exit 1; }

# ---- 1d. native app-menu: swap in the from-source winemac.so --------------------------------
# winemac.drv builds the bold "RaceStudio 3" app menu in compiled Cocoa. We rebuild that one unix
# module from a source patch (installer/wine-patch/winemac-native-menu.patch) so RS3's app menu
# gains Import / Uninstall / Show Logs items above a ⌘Q Quit, then swap it for the bundle's stock
# winemac.so. The patch also folds in the ⌘Q remap that used to be a post-build binary edit
# (patch-wine-cmdq.py, now retired). The module is x86_64 (built under Rosetta) to match the
# osx64 bundle; build with installer/wine-patch/build-winemac-so.sh (CI does this). Like 1c/1e,
# must run BEFORE signing — it replaces a Mach-O the app-bundle seal then covers.
WINEMAC_SO_DIR="${WINEMAC_SO_DIR:-$HERE/../wine-patch/build/winemac}"
say "Native app menu: swapping patched winemac.so (Import/Uninstall/Show Logs + ⌘Q)"
WINEMAC_SWAPPED=0
src_so="$WINEMAC_SO_DIR/x86_64-unix/winemac.so"
if [ -f "$src_so" ]; then
  # plain grep + redirect (NOT grep -q): under `set -o pipefail` grep -q SIGPIPEs strings.
  strings "$src_so" | grep -F 'wine_rs3OpenAuxApp' >/dev/null || { echo "patched winemac.so missing marker 'wine_rs3OpenAuxApp'" >&2; exit 1; }
  lipo -archs "$src_so" 2>/dev/null | grep -qw x86_64 || { echo "patched winemac.so is not x86_64" >&2; exit 1; }
  while IFS= read -r dst; do
    # explicit failure check: this script has no `set -e`, so a silent cp failure must not be
    # mistaken for a successful swap (which would ship the stock winemac.so + no menu items).
    cp "$src_so" "$dst" || { echo "failed to copy patched winemac.so to $dst" >&2; exit 1; }
    say "  swapped $(echo "$dst" | sed "s#$RES/wine/lib/wine/##")"
    WINEMAC_SWAPPED=1
  done < <(find "$RES/wine/lib/wine" -type f -name 'winemac.so' -path '*x86_64-unix/*')
fi
if [ "$WINEMAC_SWAPPED" != 1 ]; then
  if [ "${HARDENED_RUNTIME:-0}" = 1 ]; then
    echo "missing patched winemac.so at $WINEMAC_SO_DIR — native menu items + ⌘Q are REQUIRED for release."
    echo "run: bash installer/wine-patch/build-winemac-so.sh"; exit 1
  fi
  say "  (patched winemac.so absent — native menu/⌘Q not applied; dev build ships stock Wine menu)"
fi

# ---- 1e. WiFi loopback redirect: swap in the patched Wine DLLs ------------------------------
# RS3 reaches AiM dashes over WiFi, which the macOS 15+/26 Local Network gate silently drops for
# the Wine guest. Two patched Wine PE DLLs fix it (both REQUIRED):
#   wlanapi.dll — presents one synthetic connected Wi-Fi interface so RS3 starts dash discovery
#                 (Wine's wlanapi reports zero interfaces, so RS3 never tries).
#   ws2_32.dll  — redirects the dash subnet + the 0.0.0.0:36002 discovery target to 127.0.0.1
#                 (port 36002->36003) and rewrites the relay's reply source back to 10.0.0.1.
# The root aim-bridge daemon relays loopback <-> the real dash. Build both with
# installer/bridge/wine-patch/build-wine-dlls.sh (CI does this). Like 1c/1d, must run BEFORE
# signing (it replaces bundle resources). PE DLLs aren't Mach-O, so they're not codesigned
# individually — the app-bundle seal covers them, hence the swap must precede step 4.
WINEDLL_DIR="${WINE_PATCHED_DLL_DIR:-${WS2_32_PATCHED_DIR:-$HERE/../bridge/wine-patch/build/wine-dlls}}"
say "WiFi: swapping patched Wine DLLs (ws2_32 redirect + wlanapi synthetic interface)"
# <dll> <arch> <marker> -> returns 0 if swapped
swap_winedll() {
  local dll="$1" arch="$2" marker="$3"
  local src="$WINEDLL_DIR/$arch-windows/$dll.dll" dst="$RES/wine/lib/wine/$arch-windows/$dll.dll"
  [ -f "$src" ] && [ -f "$dst" ] || return 1
  # plain grep + redirect (NOT grep -q): under `set -o pipefail` grep -q exits early and SIGPIPEs
  # strings, which would report the pipeline as failed even when the marker is present.
  strings "$src" | grep -F "$marker" >/dev/null || { echo "patched $dll ($arch) missing marker '$marker'" >&2; exit 1; }
  cp "$src" "$dst"; say "  swapped $arch-windows/$dll.dll"
}
swap_winedll ws2_32 x86_64 'AiM: redirecting' && X64_SWAPPED=1 || X64_SWAPPED=0
swap_winedll ws2_32 i386   'AiM: redirecting' || true   # 32-bit is best-effort (RS3 main is 64-bit)
swap_winedll wlanapi x86_64 'AiM synthetic' && WLAN64_SWAPPED=1 || WLAN64_SWAPPED=0
swap_winedll wlanapi i386   'AiM synthetic' || true
if [ "$X64_SWAPPED" != 1 ] || [ "$WLAN64_SWAPPED" != 1 ]; then
  if [ "${HARDENED_RUNTIME:-0}" = 1 ]; then
    echo "missing patched x86_64 Wine DLLs at $WINEDLL_DIR — the WiFi redirect is REQUIRED for release."
    echo "run: bash installer/bridge/wine-patch/build-wine-dlls.sh"; exit 1
  fi
  say "  (patched Wine DLLs incomplete — WiFi not applied; dev build only)"
fi

# ---- 1f. USB (WinUSB) support: add the libusb-backed wineusb bus driver ----------------------
# AiM devices (notably the USB-only PDM) are vendor-class WinUSB (Class=USBDevice, VID 0x11CC). RS3
# opens them via WinUsb_Initialize -> winusb.dll (already bundled) -> wineusb.sys, the raw-USB *bus*
# driver whose unixlib (wineusb.so) is libusb-backed. The stock Gcenx bundle was built WITHOUT
# libusb, so wineusb.{sys,so} are absent and winusb.dll has nothing to bind. We add them here (plus
# an x86_64 libusb dylib loaded via @loader_path), built by installer/wine-patch/build-wineusb-so.sh.
# Mach-O modules, so like 1d they must land BEFORE signing. Verified locally: a FRESH prefix
# self-registers the wineusb bus via wineboot --init and enumerates host USB through libusb (no
# launcher code needed). Existing prefixes stay inert-but-safe (the driver only loads once
# registered, which a from-scratch init does) — so a clean install is required to get USB today.
# GATED behind INCLUDE_USB=1 and still UNVERIFIED on AiM hardware (the PDM handshake) — kept out of
# stable releases until validated; CI sets the flag only for -usb prerelease tags. See memory
# usb-pdm-winusb-path and installer/wine-patch/README.md.
WINEUSB_DIR="${WINEUSB_DIR:-$HERE/../wine-patch/build/wineusb}"
usb_unix_src="$WINEUSB_DIR/x86_64-unix/wineusb.so"
if [ "${INCLUDE_USB:-0}" = 1 ] && [ -f "$usb_unix_src" ]; then
  say "USB: adding libusb-backed wineusb bus driver (WinUSB for AiM devices) [INCLUDE_USB=1]"
  lipo -archs "$usb_unix_src" 2>/dev/null | grep -qw x86_64 || { echo "wineusb.so is not x86_64" >&2; exit 1; }
  otool -L "$usb_unix_src" | grep -q '@loader_path/libusb-1.0.0.dylib' || { echo "wineusb.so does not load bundled libusb" >&2; exit 1; }
  ud="$RES/wine/lib/wine/x86_64-unix"
  cp "$usb_unix_src" "$ud/wineusb.so" || { echo "failed to copy wineusb.so" >&2; exit 1; }
  cp "$WINEUSB_DIR/x86_64-unix/libusb-1.0.0.dylib" "$ud/libusb-1.0.0.dylib" || { echo "failed to copy libusb dylib" >&2; exit 1; }
  say "  added x86_64-unix/{wineusb.so,libusb-1.0.0.dylib}"
  # x86_64 wineusb.sys is REQUIRED (RS3 is 64-bit) — fail loud rather than ship a USB-labelled
  # bundle that can't bind. i386 stays optional (RS3 has no 32-bit path here).
  [ -f "$WINEUSB_DIR/x86_64-windows/wineusb.sys" ] || { echo "missing required $WINEUSB_DIR/x86_64-windows/wineusb.sys (INCLUDE_USB=1)" >&2; exit 1; }
  for usb_arch in x86_64 i386; do
    usb_sys_src="$WINEUSB_DIR/$usb_arch-windows/wineusb.sys"
    usb_sys_dst="$RES/wine/lib/wine/$usb_arch-windows/wineusb.sys"
    if [ -f "$usb_sys_src" ] && [ -d "$RES/wine/lib/wine/$usb_arch-windows" ]; then
      cp "$usb_sys_src" "$usb_sys_dst" || { echo "failed to copy wineusb.sys ($usb_arch)" >&2; exit 1; }
      say "  added $usb_arch-windows/wineusb.sys"
    fi
  done
  # wineusb.inf lets wineboot register the root\wineusb bus device + service on a fresh prefix
  # (wine.inf already references it). Without it the driver files are present but never loaded —
  # REQUIRED, so fail loud rather than silently ship an unregisterable USB bundle.
  [ -f "$WINEUSB_DIR/wineusb.inf" ] || { echo "missing required $WINEUSB_DIR/wineusb.inf (INCLUDE_USB=1)" >&2; exit 1; }
  [ -d "$RES/wine/share/wine" ] || { echo "missing destination $RES/wine/share/wine" >&2; exit 1; }
  cp "$WINEUSB_DIR/wineusb.inf" "$RES/wine/share/wine/wineusb.inf" || { echo "failed to copy wineusb.inf" >&2; exit 1; }
  say "  added share/wine/wineusb.inf"
elif [ "${INCLUDE_USB:-0}" = 1 ]; then
  say "USB: INCLUDE_USB=1 but wineusb.so absent — run installer/wine-patch/build-wineusb-so.sh first"
fi

# ---- 1g. aim-bridge root daemon + SMAppService control tool ---------------------------------
# The 1e redirect sends RS3's dash traffic to 127.0.0.1; this root daemon (registered at first
# launch via SMAppService -> the user enables it once in Login Items) relays loopback <-> the
# real dash, exempt from the Local Network gate because it runs as root. The launcher
# (RaceStudio3.applescript) calls aim-bridge-ctl to register/health-check it on macOS 15+.
say "Building aim-bridge daemon + control tool"
SKIP_SIGN=1 bash "$HERE/../bridge/build-bridge.sh" >/dev/null || { echo "bridge build failed"; exit 1; }
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$HERE/../bridge/build/aim-bridge"     "$APP/Contents/MacOS/aim-bridge"
cp "$HERE/../bridge/build/aim-bridge-ctl" "$APP/Contents/MacOS/aim-bridge-ctl"
cp "$HERE/../bridge/com.rushautoworks.racestudio3.bridge.plist" "$APP/Contents/Library/LaunchDaemons/"
chmod +x "$APP/Contents/MacOS/aim-bridge" "$APP/Contents/MacOS/aim-bridge-ctl"

# ---- 2. icon (dark rounded square + Rush logo) ----------------------------------------------
say "Building app icon"
PYVENV="${PYVENV:-/tmp/rs3-build-venv}"
if [ ! -x "$PYVENV/bin/python" ]; then python3 -m venv "$PYVENV" && "$PYVENV/bin/python" -m pip install -q Pillow; fi
PY="$PYVENV/bin/python"
# Icon source: the RaceStudio 3 wordmark (sourced from a local RS3 install, gitignored), else the
# Rush square logo as a fallback so the build still works without it.
ICON_LOGO="$ASSETS/rs3-logo.png"; [ -f "$ICON_LOGO" ] || ICON_LOGO="$ASSETS/logo-square.png"
# build_icns <badge> <out.icns> — compose a 1024² PNG (optional import/uninstall badge), then icns.
build_icns() {
  local badge="$1" out="$2" s
  local png="$DIST/icon-$badge.png" iconset="$DIST/icon-$badge.iconset"
  "$PY" "$HERE/compose-icon.py" "$ICON_LOGO" "$png" "$badge" || { echo "compose-icon.py ($badge) failed"; exit 1; }
  rm -rf "$iconset"; mkdir -p "$iconset"   # must NOT be hidden (iconutil rejects dot-dirs)
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"         "$png" --out "$iconset/icon_${s}x${s}.png"    >/dev/null || { echo "sips $badge ${s} failed"; exit 1; }
    sips -z $((s*2)) $((s*2)) "$png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null || { echo "sips $badge ${s}@2x failed"; exit 1; }
  done
  iconutil -c icns "$iconset" -o "$out" || { echo "iconutil $badge failed"; exit 1; }
  rm -rf "$iconset" "$png"
}
build_icns none      "$DIST/rs3.icns"            # main app: plain RS3 logo
build_icns import    "$DIST/rs3-import.icns"     # Import: + orange file-into-RS3 badge (bottom-left)
build_icns uninstall "$DIST/rs3-uninstall.icns"  # Uninstall: + red trash-can badge (bottom-left)
# osacompile made a DROPLET (because of `on open`), so it uses droplet.icns — overwrite BOTH.
cp "$DIST/rs3.icns" "$RES/applet.icns"
[ -f "$RES/droplet.icns" ] && cp "$DIST/rs3.icns" "$RES/droplet.icns"
# keep $DIST/rs3*.icns — the Import/Uninstall applets reuse them (removed after 3b)

# ---- 3. Info.plist --------------------------------------------------------------------------
PL="$APP/Contents/Info.plist"
pset() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 $3 $2" "$PL"; }
pset CFBundleIdentifier "$BUNDLE_ID" string
pset CFBundleName "RaceStudio 3" string
pset CFBundleShortVersionString "$VERSION" string
# CFBundleVersion = upstream version + packaging revision (e.g. 3.83.20.2), monotonic per build;
# CFBundleShortVersionString stays the clean upstream version users see.
pset CFBundleVersion "${VERSION}.${PKG_REV}" string
pset LSMinimumSystemVersion "$MIN_OS" string
pset CFBundleIconFile "applet" string
# osacompile droplets set CFBundleIconName=droplet, which OVERRIDES CFBundleIconFile and forces the
# generic system droplet icon. Remove it so our applet.icns (the RS3 icon) is used.
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PL" 2>/dev/null || true

# ---- 3b. standalone Import / Uninstall apps -------------------------------------------------
# AppleScript applets that ship as SIBLINGS of RaceStudio 3.app inside the DMG's "AiM" folder, so
# the whole folder drops into /Applications/AiM in one drag. Wine owns the macOS menu bar while RS3
# runs and that menu can't host custom items, and the old NSStatusItem menu-bar helper proved
# unreliable (Bartender/Tahoe), so these standalone apps are the reachable Import/Uninstall surface.
say "Building helper apps (Import / Uninstall / Show Logs)"
IMPORT_APP_BUILT="$DIST/Import RaceStudio 3 Data.app"
UNINSTALL_APP_BUILT="$DIST/Uninstall RaceStudio 3.app"
rm -rf "$IMPORT_APP_BUILT" "$UNINSTALL_APP_BUILT"
osacompile -o "$IMPORT_APP_BUILT"    "$SRC/import-app.applescript"    || { echo "osacompile import failed"; exit 1; }
osacompile -o "$UNINSTALL_APP_BUILT" "$SRC/uninstall-app.applescript" || { echo "osacompile uninstall failed"; exit 1; }
SHOWLOGS_APP_BUILT="$DIST/Show RaceStudio 3 Logs.app"
rm -rf "$SHOWLOGS_APP_BUILT"
osacompile -o "$SHOWLOGS_APP_BUILT" "$SRC/show-logs-app.applescript" || { echo "osacompile show-logs failed"; exit 1; }

# Import merges data, so it needs the engine — embed installer-core.sh + lib + pins.env (same
# layout as RaceStudio 3.app's Resources). Uninstall calls the self-contained uninstall.sh at run
# time, so it needs nothing extra.
IMP_RES="$IMPORT_APP_BUILT/Contents/Resources"
ditto "$SRC/installer-core.sh" "$IMP_RES/installer-core.sh"
ditto "$SRC/pins.env"          "$IMP_RES/pins.env"
ditto "$SRC/lib"               "$IMP_RES/lib"
chmod +x "$IMP_RES/installer-core.sh"

# Show Logs runs collect-logs.sh, which reads pins.env for the version. Embed both (no lib/ — the
# collector is standalone and shells to the sibling RaceStudio 3.app for aim-bridge-ctl).
SL_RES="$SHOWLOGS_APP_BUILT/Contents/Resources"
ditto "$SRC/collect-logs.sh" "$SL_RES/collect-logs.sh"
ditto "$SRC/pins.env"        "$SL_RES/pins.env"
chmod +x "$SL_RES/collect-logs.sh"

# brand each applet: RS3 icon + identity/version. osacompile makes a droplet (uses droplet.icns)
# when the script has `on open`, else an applet (applet.icns) — overwrite whichever exists.
brand_applet() { # <app> <bundle-id> <name> <icns>
  local bid="$2" nm="$3" icns="$4" pl="$1/Contents/Info.plist" r="$1/Contents/Resources"
  [ -f "$r/applet.icns" ]  && cp "$icns" "$r/applet.icns"
  [ -f "$r/droplet.icns" ] && cp "$icns" "$r/droplet.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bid" "$pl" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bid" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $nm" "$pl" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $nm" "$pl"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$pl" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MIN_OS" "$pl" 2>/dev/null || true
  # osacompile sets CFBundleIconName=applet/droplet, which OVERRIDES CFBundleIconFile and points at a
  # non-existent asset-catalog icon -> blank icon. Remove it so our overwritten .icns is used.
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$pl" 2>/dev/null || true
}
brand_applet "$IMPORT_APP_BUILT"    "$BUNDLE_ID.import"    "Import RaceStudio 3 Data" "$DIST/rs3-import.icns"
brand_applet "$UNINSTALL_APP_BUILT" "$BUNDLE_ID.uninstall" "Uninstall RaceStudio 3"   "$DIST/rs3-uninstall.icns"
brand_applet "$SHOWLOGS_APP_BUILT"  "$BUNDLE_ID.showlogs" "Show RaceStudio 3 Logs"   "$DIST/rs3.icns"
rm -f "$DIST/rs3.icns" "$DIST/rs3-import.icns" "$DIST/rs3-uninstall.icns"

if [ "${SKIP_SIGN:-0}" = 1 ]; then say "SKIP_SIGN=1 — compiled only."; exit 0; fi

# ---- 4. codesign ----------------------------------------------------------------------------
# NOTE (one-time): the first codesign with your Developer ID key pops a keychain dialog — click
# "Always Allow". Headless pre-auth: security unlock-keychain + set-key-partition-list
#   -S apple-tool:,apple:,codesign: -s -k "<pw>" ~/Library/Keychains/login.keychain-db
have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAMID"; }
if ! have_identity; then say "No Developer ID ($TEAMID) in keychain — compiled only in $DIST."; exit 0; fi
# Now that Wine is bundled, the app has hundreds of mach-o files -> --deep signs them all.
# Hardened runtime is OFF by default: Wine needs JIT/unsigned-memory entitlements to run under it,
# which we add in the notarization pass (HARDENED_RUNTIME=1). Timestamp only with hardened runtime
# (per-file TSA calls across all of Wine are slow + only needed for notarization).
ENT="$HERE/wine.entitlements.plist"
TS=""   # timestamp flag; only set under hardened runtime (below). Must be defined for the DMG
        # signing step in the default --deep path too, else `set -u` aborts with TS: unbound.
if [ "${HARDENED_RUNTIME:-0}" = 1 ]; then
  # Notarization-grade: hardened runtime needs EVERY Mach-O signed individually (the --deep
  # shortcut is rejected by notarytool). Sign all of Wine's binaries first, then the app bundle.
  TS="--timestamp"; [ "${NO_TIMESTAMP:-0}" = 1 ] && TS=""
  # Sibling helper apps (no special entitlements — they bundle no Mach-O of their own).
  say "Signing the helper apps (Import / Uninstall / Show Logs)…"
  codesign --force --options runtime $TS --sign "$IDENTITY" "$IMPORT_APP_BUILT"    || { echo "import codesign failed"; exit 1; }
  codesign --force --options runtime $TS --sign "$IDENTITY" "$UNINSTALL_APP_BUILT" || { echo "uninstall codesign failed"; exit 1; }
  codesign --force --options runtime $TS --sign "$IDENTITY" "$SHOWLOGS_APP_BUILT" || { echo "show-logs codesign failed"; exit 1; }
  say "Signing nested Wine binaries individually (notarization-grade — slow)…"
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$f" 2>/dev/null || \
                say "  warn: could not sign $f" ;;
    esac
  done < <(find "$RES/wine" -type f)
  # Sign the bridge daemon + control tool (inside-out: before the app bundle). Plain hardened
  # Developer ID — no special entitlements (a socket relay + an SMAppService client).
  say "Signing aim-bridge daemon + control tool…"
  # shellcheck disable=SC2086
  codesign --force --options runtime $TS --sign "$IDENTITY" "$APP/Contents/MacOS/aim-bridge"     || { echo "aim-bridge codesign failed"; exit 1; }
  # shellcheck disable=SC2086
  codesign --force --options runtime $TS --sign "$IDENTITY" "$APP/Contents/MacOS/aim-bridge-ctl" || { echo "aim-bridge-ctl codesign failed"; exit 1; }
  say "Signing the app bundle…"
  # shellcheck disable=SC2086
  codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$APP" || { echo "codesign failed"; exit 1; }
else
  # Fast local signing (not notarizable): --deep, no hardened runtime so bundled Wine still runs.
  say "Codesigning (deep — Wine has many binaries, takes a minute)…"
  codesign --deep --force --sign "$IDENTITY" "$APP" || { echo "codesign failed"; exit 1; }
  codesign --deep --force --sign "$IDENTITY" "$IMPORT_APP_BUILT"    || { echo "import codesign failed"; exit 1; }
  codesign --deep --force --sign "$IDENTITY" "$UNINSTALL_APP_BUILT" || { echo "uninstall codesign failed"; exit 1; }
  codesign --deep --force --sign "$IDENTITY" "$SHOWLOGS_APP_BUILT" || { echo "show-logs codesign failed"; exit 1; }
fi
codesign --verify --strict "$APP" && say "signature verifies"

# ---- 5. notarize + staple (if creds) --------------------------------------------------------
NOTARY_ARGS=""
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS="--keychain-profile $NOTARY_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  # App Store Connect API key (.p8) — preferred; doesn't need account.apple.com
  NOTARY_ARGS="--key $NOTARY_KEY --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER"
elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  NOTARY_ARGS="--apple-id $NOTARY_APPLE_ID --password $NOTARY_PASSWORD --team-id $TEAMID"
fi
notarize_staple() { # <path>
  [ -n "$NOTARY_ARGS" ] || return 2
  local t="$1" submitpath
  say "Notarizing $(basename "$t") (waits for Apple)…"
  # .app must be zipped for upload; .dmg/.pkg are submitted directly (zipping a DMG makes
  # notarytool try to unpack it -> "no signed executables / could not be unpacked").
  if [ "${t##*.}" = "app" ]; then submitpath="$t.notarize.zip"; ditto -c -k --keepParent "$t" "$submitpath"; else submitpath="$t"; fi
  # shellcheck disable=SC2086
  if xcrun notarytool submit "$submitpath" $NOTARY_ARGS --wait; then
    [ "${t##*.}" = "app" ] && rm -f "$submitpath"
    xcrun stapler staple "$t" && say "stapled $(basename "$t")"
  else echo "notarytool failed for $t"; [ "${t##*.}" = "app" ] && rm -f "$submitpath"; return 1; fi
}
# rc 2 = no notarytool credentials configured (fine — signed-only build); any other nonzero is
# a real upload/staple failure that must fail the build (this is the release artifact path).
# Staple each app individually so they pass Gatekeeper OFFLINE after being dragged out of the DMG.
notarize_staple "$APP"                 || { rc=$?; [ "$rc" -eq 2 ] || { echo "app notarization failed (rc=$rc)"; exit "$rc"; }; }
notarize_staple "$IMPORT_APP_BUILT"    || { rc=$?; [ "$rc" -eq 2 ] || { echo "Import app notarization failed (rc=$rc)"; exit "$rc"; }; }
notarize_staple "$UNINSTALL_APP_BUILT" || { rc=$?; [ "$rc" -eq 2 ] || { echo "Uninstall app notarization failed (rc=$rc)"; exit "$rc"; }; }
notarize_staple "$SHOWLOGS_APP_BUILT"  || { rc=$?; [ "$rc" -eq 2 ] || { echo "Show Logs app notarization failed (rc=$rc)"; exit "$rc"; }; }

# ---- 6. branded drag-to-Applications DMG ----------------------------------------------------
if [ "${NO_DMG:-0}" = 1 ]; then say "NO_DMG=1 — skipping DMG."; exit 0; fi
say "Composing DMG background"
BG="$DIST/.bg.png"
"$PY" "$HERE/compose-dmg-bg.py" "$ASSETS/logo-wide-black.png" "$BG" || { echo "compose-dmg-bg.py failed"; exit 1; }

say "Staging DMG contents"
# Ship a single "AiM" folder holding all three apps; the user drags the whole folder onto
# /Applications, landing everything in /Applications/AiM in one move.
STAGE="$DIST/.dmgstage"; rm -rf "$STAGE"; mkdir -p "$STAGE/.background" "$STAGE/AiM"
ditto "$APP"                 "$STAGE/AiM/RaceStudio 3.app"            || { echo "staging ditto failed (app)"; exit 1; }
ditto "$IMPORT_APP_BUILT"    "$STAGE/AiM/Import RaceStudio 3 Data.app" || { echo "staging ditto failed (import)"; exit 1; }
ditto "$UNINSTALL_APP_BUILT" "$STAGE/AiM/Uninstall RaceStudio 3.app"   || { echo "staging ditto failed (uninstall)"; exit 1; }
ditto "$SHOWLOGS_APP_BUILT" "$STAGE/AiM/Show RaceStudio 3 Logs.app"  || { echo "staging ditto failed (show-logs)"; exit 1; }
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
    set the bounds of container window to {220, 140, 860, 706}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 128
    set text size of vo to 12
    set background picture of vo to file ".background:bg.png"
    set position of item "AiM" of container window to {160, 235}
    set position of item "Applications" of container window to {480, 235}
    try
      set position of item ".background" of container window to {1100, 1100}
    end try
    update without registering applications
    delay 2
    close
    delay 1
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
notarize_staple "$DMG" || { rc=$?; [ "$rc" -eq 2 ] || { echo "DMG notarization failed (rc=$rc)"; exit "$rc"; }; }

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
