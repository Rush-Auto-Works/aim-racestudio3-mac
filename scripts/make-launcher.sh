#!/usr/bin/env bash
# Create a double-clickable RaceStudio 3 launcher in ~/Applications.
# Usage: ./make-launcher.sh [bottle-name]
set -euo pipefail
BOTTLE="${1:-RaceStudio3}"
OUT="$HOME/Applications/RaceStudio 3.command"
mkdir -p "$HOME/Applications"
cat > "$OUT" <<EOF
#!/bin/bash
# Launch AiM RaceStudio 3 in the CrossOver "$BOTTLE" bottle.
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
exec "\$CX/bin/cxstart" --bottle "$BOTTLE" -- \\
  'C:\\AIM_SPORT\\RaceStudio3\\64\\AiMRS3-64-ReleaseU.exe' "\$@"
EOF
chmod +x "$OUT"
echo "Created: $OUT"
echo "Double-click it in Finder. First time: right-click -> Open -> Open (Gatekeeper)."
