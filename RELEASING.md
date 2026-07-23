# Releasing Vibe Bar

Vibe Bar releases are built from a versioned tag and uploaded to a draft
GitHub Release. The release remains a draft until a maintainer checks the
assets and publishes it in the GitHub UI.

The same workflow supports both today's ad-hoc signature and a future
Developer ID + notarization setup. Neither path enables the App Sandbox;
`Resources/VibeBar.entitlements` must remain an empty plist because the misc
provider integrations require the current unsandboxed runtime.

## Prepare a version

1. Update both values in `Resources/Info.plist`:
   - `CFBundleShortVersionString` — user-facing version, for example `0.2.0`.
   - `CFBundleVersion` — monotonically increasing build number.
2. Merge that version bump to `main` through a PR.
3. From the updated `main`, create and push the matching tag:

   ```sh
   git tag -a v0.2.0 -m "Vibe Bar 0.2.0"
   git push origin v0.2.0
   ```

The tag must be exactly `v` plus `CFBundleShortVersionString`. A mismatch
fails before an asset is uploaded.

## What the workflow does

`.github/workflows/release.yml` runs on GitHub's macOS 26 runner. It:

1. checks out the tagged source and reports the active toolchain;
2. optionally imports a Developer ID certificate;
3. runs the complete Swift test suite;
4. builds and signs the release app;
5. verifies the strict code signature and rejects sandboxed entitlements;
6. optionally notarizes and staples a Developer ID build;
7. creates an architecture-labelled ZIP and SHA-256 checksum;
8. signs the ZIP with Sparkle's EdDSA key and generates `appcast.xml`; and
9. creates or updates a draft GitHub Release.

Review the generated draft and then select **Publish release** on GitHub.
Re-running the workflow for the same tag replaces its assets. Draft releases
do not become the live update feed: GitHub's `releases/latest` URL continues
to resolve to the previous published release until the draft is published.

## Release assets

The reusable local entry point is:

```sh
./Scripts/release_app.sh v0.2.0
```

It writes architecture-labelled files under `.build/release/`, for example:

```text
Vibe-Bar-0.2.0-macOS-arm64.zip
Vibe-Bar-0.2.0-macOS-arm64.zip.sha256
appcast.xml
```

Without signing credentials this produces an ad-hoc-signed build. GitHub can
host that build, but Gatekeeper will require users to approve it manually.
The archive still requires a Sparkle EdDSA signature; this protects in-app
updates independently of the optional Apple Developer ID signature.

## Sparkle update signing

Generate one organization-scoped Sparkle key on a trusted maintainer Mac:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account astroqore-vibe-bar
```

Keep the printed public key in `Resources/Info.plist` as `SUPublicEDKey`.
The private key remains in the login Keychain. For GitHub Actions, export it
to a temporary permission-restricted file, save its contents as the repository
secret `SPARKLE_ED_PRIVATE_KEY`, and immediately delete the temporary file.
Never commit or print the private key.

Local releases use the `astroqore-vibe-bar` Keychain account by default.
CI reads `SPARKLE_ED_PRIVATE_KEY` from standard input and fails before
packaging when the secret is absent. `Scripts/release_app.sh` also rejects an
appcast that lacks an EdDSA archive signature or the expected build number.

The stable feed URL is:

```text
https://github.com/AstroQore/vibe-bar/releases/latest/download/appcast.xml
```

Each published release must therefore contain the ZIP, its checksum, and
`appcast.xml`. Do not hand-edit the appcast after it has been generated.

## Enable Developer ID signing and notarization

After joining the Apple Developer Program, export a **Developer ID
Application** certificate as a password-protected `.p12`. Add these Actions
repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded `.p12` file |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific password used by `notarytool` |

For example, encode the certificate locally without printing it:

```sh
base64 -i DeveloperID.p12 | pbcopy
```

Once `MACOS_CERTIFICATE_P12` is present, the workflow refuses to create a
half-configured public build: it requires the certificate password and all
three notarization credentials, signs with hardened runtime, waits for Apple
notarization, staples the ticket, and assesses the finished app with
Gatekeeper.

For a local Developer ID release, import the certificate into the login
Keychain and store notarization credentials once:

```sh
xcrun notarytool store-credentials "vibebar-release"
VIBEBAR_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
VIBEBAR_NOTARY_KEYCHAIN_PROFILE="vibebar-release" \
./Scripts/release_app.sh v0.2.0
```

Never commit certificates, passwords, Apple IDs, team IDs, or notarization
profiles to the repository.
