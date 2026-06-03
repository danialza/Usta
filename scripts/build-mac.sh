#!/usr/bin/env bash
# Builds Atelier.app at <repo>/dist/Atelier.app.
# Steps:
#   1. cargo build --release (atelierd, ateliercli)
#   2. swift build -c release (AtelierMac)
#   3. assemble a minimal .app bundle with Info.plist + bundled daemon
#
# Notarisation / signing are out of scope for this script (TODO: codesign +
# notarytool once we have a Developer ID). The unsigned bundle still runs
# locally; users can `xattr -dr com.apple.quarantine Atelier.app` if needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Atelier.app"

echo "==> Cargo release build (atelierd + ateliercli)"
cd "$ROOT"
cargo build --release -p atelier-daemon -p atelier-cli -p atelier-mcp

echo "==> Swift release build (AtelierMac)"
cd "$ROOT/apps/mac"
swift build -c release

SWIFT_BIN="$ROOT/apps/mac/.build/release/AtelierMac"
DAEMON_BIN="$ROOT/target/release/atelierd"
CLI_BIN="$ROOT/target/release/ateliercli"

[ -x "$SWIFT_BIN"  ] || { echo "missing $SWIFT_BIN"; exit 1; }
[ -x "$DAEMON_BIN" ] || { echo "missing $DAEMON_BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SWIFT_BIN"  "$APP/Contents/MacOS/Atelier"
cp "$DAEMON_BIN" "$APP/Contents/MacOS/atelierd"
[ -x "$CLI_BIN" ] && cp "$CLI_BIN" "$APP/Contents/MacOS/ateliercli" || true
MCP_BIN="$ROOT/target/release/atelier-mcp"
[ -x "$MCP_BIN" ] && cp "$MCP_BIN" "$APP/Contents/MacOS/atelier-mcp" || true

# Bundle the role library so first-launch has the 5 builtins.
mkdir -p "$APP/Contents/Resources/roles"
cp "$ROOT/roles/"*.yaml "$APP/Contents/Resources/roles/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                    <string>Atelier</string>
    <key>CFBundleDisplayName</key>             <string>Atelier</string>
    <key>CFBundleIdentifier</key>              <string>dev.atelier.Atelier</string>
    <key>CFBundleVersion</key>                 <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>      <string>0.1.0</string>
    <key>CFBundleExecutable</key>              <string>Atelier</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>LSMinimumSystemVersion</key>          <string>15.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSPrincipalClass</key>                <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>   <string>Atelier coordinates terminals and agents on your behalf.</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so the binary's code identity is stable across builds.
# macOS uses the code identity to decide whether to re-prompt for keychain
# access. Without a stable signature each rebuild is "a new app" → password
# prompt every launch (sometimes multiple times). `--sign -` is the special
# identity meaning "self-sign with a hash-only identity" (no developer cert
# needed), but it gives the binary a stable identity hash so macOS treats
# subsequent launches as the SAME app once user clicks Always Allow once.
echo "==> Ad-hoc codesign (stable identity for keychain)"
codesign --force --deep --sign - "$APP" 2>&1 | tail -3 || true

echo
echo "==> Done."
echo "Run:  open $APP"
echo "Atelier will find the bundled atelierd next to its own binary."
