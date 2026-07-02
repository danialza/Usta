#!/usr/bin/env bash
# Builds Usta.app at <repo>/dist/Usta.app.
# Steps:
#   1. cargo build --release (ustad, ustacli)
#   2. swift build -c release (UstaMac)
#   3. assemble a minimal .app bundle with Info.plist + bundled daemon
#
# Notarisation / signing are out of scope for this script (TODO: codesign +
# notarytool once we have a Developer ID). The unsigned bundle still runs
# locally; users can `xattr -dr com.apple.quarantine Usta.app` if needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Usta.app"

echo "==> Cargo release build (ustad + ustacli + usta-mcp)"
cd "$ROOT"
# Build per-package separately. A combined "-p A -p B -p C" build sometimes
# leaves target/release/ustad as a stale variant due to cross-package
# artifact reuse — building each in its own invocation forces fresh outputs.
cargo build --release -p usta-cli
cargo build --release -p usta-mcp
cargo build --release -p usta-daemon

echo "==> Swift release build (UstaMac)"
cd "$ROOT/apps/mac"
swift build -c release

SWIFT_BIN="$ROOT/apps/mac/.build/release/UstaMac"
DAEMON_BIN="$ROOT/target/release/ustad"
CLI_BIN="$ROOT/target/release/ustacli"

[ -x "$SWIFT_BIN"  ] || { echo "missing $SWIFT_BIN"; exit 1; }
[ -x "$DAEMON_BIN" ] || { echo "missing $DAEMON_BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$SWIFT_BIN"  "$APP/Contents/MacOS/Usta"
cp "$DAEMON_BIN" "$APP/Contents/MacOS/ustad"
[ -x "$CLI_BIN" ] && cp "$CLI_BIN" "$APP/Contents/MacOS/ustacli" || true
MCP_BIN="$ROOT/target/release/usta-mcp"
[ -x "$MCP_BIN" ] && cp "$MCP_BIN" "$APP/Contents/MacOS/usta-mcp" || true

# Bundle the role library so first-launch has the 5 builtins.
mkdir -p "$APP/Contents/Resources/roles"
cp "$ROOT/roles/"*.yaml "$APP/Contents/Resources/roles/" 2>/dev/null || true

# Bundle the Usta app icon.
[ -f "$ROOT/brand/Usta.icns" ] && cp "$ROOT/brand/Usta.icns" "$APP/Contents/Resources/Usta.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                    <string>Usta</string>
    <key>CFBundleDisplayName</key>             <string>Usta</string>
    <key>CFBundleIdentifier</key>              <string>dev.usta.Usta</string>
    <key>CFBundleVersion</key>                 <string>0.1.1</string>
    <key>CFBundleShortVersionString</key>      <string>0.1.1</string>
    <key>CFBundleExecutable</key>              <string>Usta</string>
    <key>CFBundleIconFile</key>                <string>Usta</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>LSMinimumSystemVersion</key>          <string>15.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>NSPrincipalClass</key>                <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>   <string>Usta coordinates terminals and agents on your behalf.</string>
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
echo "Usta will find the bundled daemon next to its own binary."
