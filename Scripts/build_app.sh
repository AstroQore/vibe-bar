#!/usr/bin/env bash
# Build Vibe Bar executable, wrap into a proper .app bundle, and ad-hoc sign.
# Usage: ./Scripts/build_app.sh [debug|release]
# Output: .build/Vibe Bar.app
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC_PATH="$BIN_DIR/VibeBar"

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Executable not found at $EXEC_PATH" >&2
    exit 1
fi

APP_DIR="$ROOT/.build/Vibe Bar.app"
ENTITLEMENTS="$ROOT/Resources/VibeBar.entitlements"
echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/VibeBar"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

PkgInfo="APPL????"
printf '%s' "$PkgInfo" > "$APP_DIR/Contents/PkgInfo"

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> ad-hoc codesign with entitlements"
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"

echo "==> done: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
