#!/bin/bash
# collect-logs.sh — gather the current RaceStudio 3 logs into a dated folder on the Desktop and
# reveal it in Finder, so a user can hand them to a developer in one drag. Best-effort: every
# source is optional; a missing log is noted in README.txt, never an error. Run by
# "Show RaceStudio 3 Logs.app" (the script is embedded in that app's Resources).
#
# Env overrides (used by the unit test to sandbox everything):
#   RS3_APP_SUPPORT  engine root (default ~/Library/Application Support/RaceStudio3)
#   RS3_DESKTOP_DIR  where the output folder goes (default ~/Desktop)
#   RS3_OPEN_CMD     command used to reveal the folder (default: open)
set -uo pipefail

INSTALL_ROOT="${RS3_APP_SUPPORT:-$HOME/Library/Application Support/RaceStudio3}"
DESKTOP="${RS3_DESKTOP_DIR:-$HOME/Desktop}"
OPEN_CMD="${RS3_OPEN_CMD:-open}"
BRIDGE_LOG="/Library/Logs/aim-bridge.log"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="$HERE/pins.env"
# aim-bridge-ctl lives in the sibling RaceStudio 3.app (…/AiM/RaceStudio 3.app/Contents/MacOS).
CTL="$HERE/../../../RaceStudio 3.app/Contents/MacOS/aim-bridge-ctl"
BUNDLE="$HERE/../../../RaceStudio 3.app"
DASH_ADDR="10.0.0.1"   # AiM dash IP when the Mac is joined to the dash's own Wi-Fi access point

# Verify a shipped binary is the AiM-patched build (marker string present), not stock Wine. Uses
# plain grep + redirect (NOT grep -q): under `set -o pipefail` grep -q SIGPIPEs strings.
chk_marker() {  # $1=file  $2=marker  $3=label
  if [ -f "$1" ]; then
    if strings "$1" 2>/dev/null | grep -F "$2" >/dev/null 2>&1; then echo "  $3: patched"
    else echo "  $3: STOCK — marker absent (this fix is NOT active)"; fi
  else echo "  $3: not found"; fi
}

ts="$(date '+%Y%m%d-%H%M%S')"
OUT="$DESKTOP/AiM-Logs-$ts"
mkdir -p "$OUT" || { echo "failed to create output folder: $OUT" >&2; exit 1; }

missing=()
copy_if_present() {  # $1=source file  $2=basename in OUT
  if [ -f "$1" ]; then cp "$1" "$OUT/$2" 2>/dev/null || missing+=("$2 (copy failed)")
  else missing+=("$2 (not found at $1)"); fi
}
copy_if_present "$INSTALL_ROOT/logs/run.log"     "run.log"
copy_if_present "$INSTALL_ROOT/logs/install.log" "install.log"
copy_if_present "$BRIDGE_LOG"                     "aim-bridge.log"

{
  echo "AiM RaceStudio 3 — diagnostics"
  echo "collected: $(date)"
  echo
  echo "macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  echo "arch:  $(uname -m)"
  echo "install root: $INSTALL_ROOT"
  if [ -f "$PINS" ]; then
    echo "RS3 version: $(sed -nE 's/^RS3_PINNED_VER="(.*)"/\1/p' "$PINS")"
    echo "pkg rev:     $(sed -nE 's/^RS3_PKG_REV="(.*)"/\1/p' "$PINS")"
  fi
  os_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
  if [ -x "$CTL" ]; then
    bstat="$("$CTL" status 2>&1)"
    echo "bridge daemon: $bstat"
    # On macOS 15+ the Local Network gate means WiFi device discovery REQUIRES this 'enabled'.
    # Anything else (notFound / notRegistered / requiresApproval) => RS3 will list no WiFi devices.
    if [ "${os_major:-0}" -ge 15 ] 2>/dev/null && [ "$bstat" != "enabled" ]; then
      echo "  ^ NOT enabled — on macOS 15+ this is why WiFi shows no connected devices."
      echo "    Fix: relaunch RaceStudio 3, choose \"Set Up Wi-Fi\", click Allow, then turn on"
      echo "    \"RaceStudio 3\" in System Settings > General > Login Items & Extensions"
      echo "    (Allow in the Background). SD-card / USB import works without it."
    fi
  else echo "bridge daemon: (aim-bridge-ctl not found)"; fi

  echo
  echo "=== patched components (every line should read 'patched') ==="
  WB="$BUNDLE/Contents/Resources/wine/lib/wine"
  chk_marker "$WB/x86_64-windows/ws2_32.dll"  "AiM: redirecting"   "bundle ws2_32  (WiFi redirect)"
  chk_marker "$WB/x86_64-windows/wlanapi.dll" "AiM synthetic"      "bundle wlanapi (WiFi interface)"
  chk_marker "$WB/x86_64-unix/winemac.so"     "wine_rs3OpenAuxApp" "bundle winemac (menu + Cmd-Q)"
  PFX="$INSTALL_ROOT/prefix/drive_c/windows/system32"
  chk_marker "$PFX/ws2_32.dll"  "AiM: redirecting" "prefix ws2_32  (what RS3 actually loads)"
  chk_marker "$PFX/wlanapi.dll" "AiM synthetic"    "prefix wlanapi (what RS3 actually loads)"

  if [ "$(uname)" = "Darwin" ]; then
    echo
    echo "=== network (dash $DASH_ADDR; the Mac must be joined to the dash's Wi-Fi) ==="
    wifi_dev="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')"
    wifi_dev="${wifi_dev:-en0}"
    ssid="$(networksetup -getairportnetwork "$wifi_dev" 2>/dev/null | sed -E 's/^.*Network: //')"
    echo "  Wi-Fi device: $wifi_dev    SSID: ${ssid:-(unknown / redacted by macOS)}"
    echo "  Wi-Fi IPv4:   $(ipconfig getifaddr "$wifi_dev" 2>/dev/null || echo none)"
    ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{ifc=substr($1,1,length($1)-1)} /inet /{if($2!="127.0.0.1")print "  addr: "ifc" "$2}'
    route -n get "$DASH_ADDR" 2>/dev/null | awk '/route to:|gateway:|interface:/{print "  route"$0}'
    if ping -c1 -t2 "$DASH_ADDR" >/dev/null 2>&1; then echo "  ping $DASH_ADDR: reachable"
    else echo "  ping $DASH_ADDR: NO RESPONSE (dash off, or Mac not on the dash Wi-Fi)"; fi
    arp -n "$DASH_ADDR" 2>/dev/null | sed 's/^/  arp: /'
  fi
  : # ensure this block's exit status is 0 (prior probes may exit non-zero under pipefail)
} > "$OUT/system-info.txt" 2>/dev/null || { echo "failed to write system-info.txt" >&2; exit 1; }

{
  echo "These are the current RaceStudio 3 logs, collected $(date)."
  echo "Email or drag this whole folder to whoever is helping you."
  echo
  echo "Included:"
  for f in run.log install.log aim-bridge.log system-info.txt; do
    [ -f "$OUT/$f" ] && echo "  - $f"
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo
    echo "Not found (normal if you haven't used that feature yet):"
    printf '  - %s\n' "${missing[@]}"
  fi
} > "$OUT/README.txt" 2>/dev/null || { echo "failed to write README.txt" >&2; exit 1; }

"$OPEN_CMD" "$OUT" 2>/dev/null || true
exit 0
