#!/bin/bash
# Usta — one-shot install helper.
# Removes the macOS Gatekeeper quarantine flag so Usta.app opens without
# the "Apple could not verify" warning.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/danialza/Usta/main/scripts/install.sh | bash
# or after dragging Usta.app to /Applications:
#   bash scripts/install.sh

set -euo pipefail

APP="/Applications/Usta.app"

# Allow custom path: bash install.sh /path/to/Usta.app
if [ $# -ge 1 ]; then
  APP="$1"
fi

if [ ! -d "$APP" ]; then
  echo "❌ Usta.app not found at: $APP"
  echo ""
  echo "Drag Usta.app to /Applications first, or pass the path:"
  echo "  bash install.sh /custom/path/Usta.app"
  exit 1
fi

echo "→ Removing Gatekeeper quarantine from $APP"
if xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
  echo "✓ Done. You can now open Usta normally — no warning."
else
  echo "⚠️  No quarantine flag found (already clean, or app was built locally)."
fi

echo ""
echo "Launch:"
echo "  open \"$APP\""
