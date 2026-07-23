#!/usr/bin/env bash
# Produce a verified GitHub Release asset for the version in Info.plist.
#
# Usage:
#   ./Scripts/release_app.sh [v<version>]
#
# Default output:
#   .build/release/Vibe-Bar-<version>-macOS-<arch>.zip
#   .build/release/Vibe-Bar-<version>-macOS-<arch>.zip.sha256
#   .build/release/appcast.xml
#
# Without extra environment variables the app is ad-hoc signed. To create a
# public Developer ID build, set VIBEBAR_CODESIGN_IDENTITY and one notarization
# credential method:
#
#   VIBEBAR_NOTARY_KEYCHAIN_PROFILE=<notarytool-profile>
#
# or all of:
#
#   APPLE_ID=<developer-account-email>
#   APPLE_TEAM_ID=<team-id>
#   APPLE_APP_PASSWORD=<app-specific-password>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
APP_DIR="$ROOT/.build/Vibe Bar.app"
DIST_DIR="$ROOT/.build/release"
SIGN_IDENTITY="${VIBEBAR_CODESIGN_IDENTITY:--}"
SPARKLE_KEY_ACCOUNT="${VIBEBAR_SPARKLE_KEY_ACCOUNT:-astroqore-vibe-bar}"

usage() {
    printf '%s\n' \
        "Produce a verified GitHub Release asset for the version in Info.plist." \
        "" \
        "Usage: ./Scripts/release_app.sh [v<version>]" \
        "" \
        "Signing defaults to ad-hoc. See RELEASING.md for Developer ID" \
        "signing, notarization, GitHub secrets, and publishing instructions."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ ! -f "$PLIST" ]]; then
    echo "Info.plist not found at $PLIST" >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_TAG="${1:-${VIBEBAR_RELEASE_TAG:-v$VERSION}}"

if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
    echo "Release tag $RELEASE_TAG does not match Info.plist version v$VERSION" >&2
    echo "Bump CFBundleShortVersionString before releasing this tag." >&2
    exit 1
fi

if [[ "${VIBEBAR_SKIP_TESTS:-0}" != "1" ]]; then
    echo "==> running full test suite"
    (cd "$ROOT" && swift test)
fi

echo "==> building Vibe Bar $VERSION ($BUILD_NUMBER)"
(cd "$ROOT" && ./Scripts/build_app.sh release)

echo "==> verifying bundled pricing resources"
if [[ ! -f "$APP_DIR/Contents/Resources/VibeBar_VibeBarCore.bundle/pricing.json" ]]; then
    echo "Refusing to release an app without the VibeBarCore resource bundle." >&2
    exit 1
fi

echo "==> verifying bundle signature"
codesign --verify --deep --strict "$APP_DIR"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP_DIR" 2>&1)"
if grep -q 'com.apple.security.app-sandbox' <<<"$ENTITLEMENTS"; then
    echo "Refusing to release a sandboxed Vibe Bar bundle." >&2
    exit 1
fi

ARCH_LIST="$(lipo -archs "$APP_DIR/Contents/MacOS/VibeBar")"
if [[ " $ARCH_LIST " == *" arm64 "* && " $ARCH_LIST " == *" x86_64 "* ]]; then
    ARCH_LABEL="universal"
elif [[ " $ARCH_LIST " == *" arm64 "* ]]; then
    ARCH_LABEL="arm64"
elif [[ " $ARCH_LIST " == *" x86_64 "* ]]; then
    ARCH_LABEL="x86_64"
else
    ARCH_LABEL="$(tr ' ' '-' <<<"$ARCH_LIST")"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
ARCHIVE="$DIST_DIR/Vibe-Bar-$VERSION-macOS-$ARCH_LABEL.zip"

package_app() {
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"
}

package_app

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "==> notarizing Developer ID build"
    if [[ -n "${VIBEBAR_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ARCHIVE" \
            --keychain-profile "$VIBEBAR_NOTARY_KEYCHAIN_PROFILE" \
            --wait
    elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
        xcrun notarytool submit "$ARCHIVE" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait
    else
        echo "Developer ID signing requires notarization credentials." >&2
        echo "Set VIBEBAR_NOTARY_KEYCHAIN_PROFILE, or APPLE_ID, APPLE_TEAM_ID," >&2
        echo "and APPLE_APP_PASSWORD." >&2
        exit 1
    fi

    echo "==> stapling notarization ticket"
    xcrun stapler staple "$APP_DIR"
    xcrun stapler validate "$APP_DIR"
    spctl --assess --type execute --verbose=2 "$APP_DIR"
    package_app
else
    echo "==> ad-hoc release asset (Gatekeeper will require manual approval)"
fi

GENERATE_APPCAST="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type f \
        -path '*/Sparkle/bin/generate_appcast' \
        -print \
        -quit
)"
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle generate_appcast tool not found after SwiftPM build." >&2
    exit 1
fi

RELEASE_NOTES="$DIST_DIR/$(basename "${ARCHIVE%.zip}").md"
printf '# Vibe Bar %s\n\nSee the [full release notes](https://github.com/AstroQore/vibe-bar/releases/tag/%s).\n' \
    "$VERSION" "$RELEASE_TAG" > "$RELEASE_NOTES"

echo "==> generating signed Sparkle appcast"
APPCAST_ARGS=(
    --download-url-prefix "https://github.com/AstroQore/vibe-bar/releases/download/$RELEASE_TAG/"
    --link "https://github.com/AstroQore/vibe-bar/releases/tag/$RELEASE_TAG"
    --embed-release-notes
    --maximum-versions 1
    -o "$DIST_DIR/appcast.xml"
)
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
        | "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$DIST_DIR"
elif [[ "${CI:-}" == "true" ]]; then
    echo "SPARKLE_ED_PRIVATE_KEY is required in CI." >&2
    exit 1
else
    "$GENERATE_APPCAST" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        "${APPCAST_ARGS[@]}" \
        "$DIST_DIR"
fi
rm -f "$RELEASE_NOTES"

APPCAST="$DIST_DIR/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "Generated appcast does not contain an EdDSA archive signature." >&2
    exit 1
fi
if ! grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
    echo "Generated appcast does not contain build $BUILD_NUMBER." >&2
    exit 1
fi

CHECKSUM="$ARCHIVE.sha256"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")")

echo "==> release assets ready"
echo "$ARCHIVE"
echo "$CHECKSUM"
echo "$APPCAST"
