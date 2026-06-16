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
