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
# The shared string catalogue's bundle, built from the `vibe-bar-i18n`
# package. Its `L10n` looks for it under the app's Contents/Resources.
I18N_RESOURCE_BUNDLE="$BIN_DIR/vibe-bar-i18n_VibeBarLocalization.bundle"
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
if [[ ! -d "$I18N_RESOURCE_BUNDLE" ]]; then
    echo "Localization resource bundle not found at $I18N_RESOURCE_BUNDLE" >&2
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
# The string catalogue ships in the `vibe-bar-i18n` package's own resource
# bundle. It is packaged twice on purpose, and the two copies do different
# jobs. The bundle itself, under Resources, is what the package's `L10n`
# resolves through in an installed app (it looks there before ever reaching
# SwiftPM's `Bundle.module`, which traps once the build directory is gone).
# The `.lproj` directories copied beside it are what — together with
# CFBundleLocalizations — make macOS list Vibe Bar in Language & Region >
# Applications at all. SwiftPM lowercases a locale directory when it builds
# a resource bundle, so the name is restored to the conventional spelling on
# the way in; the lookup matches case-insensitively so both copies answer.
cp -R "$I18N_RESOURCE_BUNDLE" \
    "$APP_DIR/Contents/Resources/vibe-bar-i18n_VibeBarLocalization.bundle"
for lproj in "$I18N_RESOURCE_BUNDLE"/*.lproj; do
    [[ -d "$lproj" ]] || continue
    case "$(basename "$lproj")" in
        zh-hans.lproj) canonical="zh-Hans.lproj" ;;
        *)             canonical="$(basename "$lproj")" ;;
    esac
    cp -R "$lproj" "$APP_DIR/Contents/Resources/$canonical"
done
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" \
    "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp -R "$ROOT/Resources/ThirdPartyLicenses" \
    "$APP_DIR/Contents/Resources/ThirdPartyLicenses"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT/Resources/ProviderIcons" ]]; then
    cp -R "$ROOT/Resources/ProviderIcons" "$APP_DIR/Contents/Resources/ProviderIcons"
fi
# Ships with the app so the menu-bar self-check can hand the user a command
# that works on an installed copy, with no clone of this repo around.
cp "$ROOT/Scripts/fix_menu_bar_allowlist.py" \
    "$APP_DIR/Contents/Resources/fix_menu_bar_allowlist.py"

PkgInfo="APPL????"
printf '%s' "$PkgInfo" > "$APP_DIR/Contents/PkgInfo"

if [[ ! -f "$APP_DIR/Contents/Resources/VibeBar_VibeBarCore.bundle/pricing.json" ]]; then
    echo "Packaged core resource bundle is incomplete." >&2
    exit 1
fi
for lang in en zh-Hans; do
    if [[ ! -f "$APP_DIR/Contents/Resources/$lang.lproj/Localizable.strings" ]]; then
        echo "Packaged localization for $lang is missing." >&2
        exit 1
    fi
    if [[ ! -f "$APP_DIR/Contents/Resources/$lang.lproj/Localizable.stringsdict" ]]; then
        echo "Packaged plural rules for $lang are missing." >&2
        exit 1
    fi
done
for license_name in CodexBar SweetCookieKit Sparkle LobeIcons; do
    if [[ ! -f "$APP_DIR/Contents/Resources/ThirdPartyLicenses/$license_name.txt" ]]; then
        echo "Packaged third-party license resources are incomplete." >&2
        exit 1
    fi
done
if [[ ! -f "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]; then
    echo "Packaged third-party notices are incomplete." >&2
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

# Does the packaged app find its own resources?
#
# SwiftPM's generated `Bundle.module` accessor knows two places: a bundle
# beside `Bundle.main.bundleURL`, and the absolute build directory of the
# machine that compiled it. A packaged app has neither — the bundle goes under
# Contents/Resources, because a file outside Contents makes codesign reject the
# app — so any code that reaches `Bundle.module` traps. On the machine that
# built it the second path still exists, which is exactly why this shipped
# once: every local launch resolved through the build directory and only an
# installed copy failed.
#
# So hide that directory and require the app to start without it, with a
# surface rendered so the localized paths are actually exercised. A launch that
# proves nothing is worse than no launch at all.
smoke_home="$(mktemp -d)"
mkdir -p "$smoke_home/.vibebar"
: > "$smoke_home/VIBEBAR_DEMO_HOME.txt"
mv "$CORE_RESOURCE_BUNDLE" "$CORE_RESOURCE_BUNDLE.packaging-smoke"
mv "$I18N_RESOURCE_BUNDLE" "$I18N_RESOURCE_BUNDLE.packaging-smoke"
restore_core_bundle() {
    [[ -d "$CORE_RESOURCE_BUNDLE.packaging-smoke" ]] &&
        mv "$CORE_RESOURCE_BUNDLE.packaging-smoke" "$CORE_RESOURCE_BUNDLE"
    [[ -d "$I18N_RESOURCE_BUNDLE.packaging-smoke" ]] &&
        mv "$I18N_RESOURCE_BUNDLE.packaging-smoke" "$I18N_RESOURCE_BUNDLE"
    rm -rf "$smoke_home"
}
trap restore_core_bundle EXIT

VIBEBAR_DEMO_HOME="$smoke_home" \
VIBEBAR_DEMO_SURFACE=popover \
    "$APP_DIR/Contents/MacOS/VibeBar" > "$smoke_home/launch.log" 2>&1 &
smoke_pid=$!
sleep 10
if kill -0 "$smoke_pid" 2>/dev/null; then
    kill "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" 2>/dev/null || true
else
    echo "Packaged app did not survive a launch without the build directory:" >&2
    sed -n '1,10p' "$smoke_home/launch.log" >&2
    exit 1
fi
restore_core_bundle
trap - EXIT

echo "==> done: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
