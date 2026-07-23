#!/usr/bin/env bash
# Build Vibe Bar executable, wrap it into a proper .app bundle, and sign it.
# Usage: ./Scripts/build_app.sh [debug|release]
# Output: .build/Vibe Bar.app
#
# Signing defaults to ad-hoc for local builds. Public release automation can
# set VIBEBAR_CODESIGN_IDENTITY to a Developer ID Application identity; the
# same unsandboxed entitlements remain in force in both modes.
set -euo pipefail

CONFIG="${1:-release}"
SIGN_IDENTITY="${VIBEBAR_CODESIGN_IDENTITY:--}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC_PATH="$BIN_DIR/VibeBar"
CORE_RESOURCE_BUNDLE="$BIN_DIR/VibeBar_VibeBarCore.bundle"
SPARKLE_FRAMEWORK_SOURCE="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type d \
        -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
        -print \
        -quit
)"

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Executable not found at $EXEC_PATH" >&2
    exit 1
fi
if [[ ! -f "$CORE_RESOURCE_BUNDLE/pricing.json" ]]; then
    echo "Core resource bundle not found at $CORE_RESOURCE_BUNDLE" >&2
    exit 1
fi
if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" || ! -x "$SPARKLE_FRAMEWORK_SOURCE/Versions/B/Sparkle" ]]; then
    echo "Sparkle framework artifact not found after SwiftPM build." >&2
    exit 1
fi

APP_DIR="$ROOT/.build/Vibe Bar.app"
ENTITLEMENTS="$ROOT/Resources/VibeBar.entitlements"
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/VibeBar"
# A signed macOS app may only contain its conventional Contents tree. Core's
# pricing resolver explicitly discovers this SwiftPM bundle under Resources
# before falling back to Bundle.module for source builds and tests.
cp -R "$CORE_RESOURCE_BUNDLE" \
    "$APP_DIR/Contents/Resources/VibeBar_VibeBarCore.bundle"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT/Resources/ProviderIcons" ]]; then
    cp -R "$ROOT/Resources/ProviderIcons" "$APP_DIR/Contents/Resources/ProviderIcons"
fi

PkgInfo="APPL????"
printf '%s' "$PkgInfo" > "$APP_DIR/Contents/PkgInfo"

if [[ ! -f "$APP_DIR/Contents/Resources/VibeBar_VibeBarCore.bundle/pricing.json" ]]; then
    echo "Packaged core resource bundle is incomplete." >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SPARKLE_SIGN_ARGS=(--force --sign - --options runtime)
else
    SPARKLE_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi

echo "==> signing Sparkle helper components"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
codesign \
    "${SPARKLE_SIGN_ARGS[@]}" \
    --preserve-metadata=entitlements \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Autoupdate"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Updater.app"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc codesign with entitlements"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
    echo "==> Developer ID codesign with hardened runtime"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

echo "==> done: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
