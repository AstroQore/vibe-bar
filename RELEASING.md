# Releasing Vibe Bar

Vibe Bar releases are built from a versioned tag and uploaded to a draft
GitHub Release. The release remains a draft until a maintainer checks the
assets and publishes it in the GitHub UI. The same signed Sparkle appcast
serves two update channels:

- **Main** is Sparkle's untagged default channel and contains stable releases.
- **Dev** uses the `dev` Sparkle channel. Dev users also receive Main releases
  because Sparkle always includes the default channel.

The same workflow supports both today's ad-hoc signature and a future
Developer ID + notarization setup. Neither path enables the App Sandbox;
`Resources/VibeBar.entitlements` must remain an empty plist because the misc
provider integrations require the current unsandboxed runtime.

## Prepare a version

1. Update both values in `Resources/Info.plist`:
   - `CFBundleShortVersionString` — user-facing version, for example `0.2.0`.
   - `CFBundleVersion` — monotonically increasing build number.
2. Merge that version bump to `main` through a PR.
3. Choose the channel, then create and push the matching tag from the commit
   being released.

For Main:

```sh
git tag -a v1.0.0 -m "Vibe Bar 1.0.0"
git push origin v1.0.0
```

The Main tag must be exactly `v` plus `CFBundleShortVersionString`.

For Dev, keep the same user-facing version and append the monotonically
increasing `CFBundleVersion` to the tag:

```sh
git tag -a v1.0.0-dev.100 -m "Vibe Bar 1.0.0 Dev build 100"
git push origin v1.0.0-dev.100
```

Here `CFBundleShortVersionString` is `1.0.0` and `CFBundleVersion` is `100`.
Every later release, including the eventual Main promotion, must have a
higher build number so Sparkle never treats it as a downgrade. Tag/channel
mismatches fail before an asset is uploaded.

## What the workflow does

`.github/workflows/release.yml` runs on GitHub's macOS 26 runner. It:

1. checks out the tagged source and reports the active toolchain;
2. optionally imports a Developer ID certificate;
3. runs the complete Swift test suite;
4. builds and signs the release app;
5. verifies the strict code signature and rejects sandboxed entitlements;
6. optionally notarizes and staples a Developer ID build;
7. creates an architecture-labelled ZIP and SHA-256 checksum;
8. preserves the current shared appcast, signs the ZIP with Sparkle's EdDSA
   key, and adds either a Main or `dev` appcast item; and
9. creates or updates a draft GitHub Release, marking Dev drafts as
   prereleases.

Review the generated draft and then select **Publish release** on GitHub.
Re-running the workflow for the same tag replaces its assets. Draft releases
do not become the live update feed. Once a versioned release is published,
`.github/workflows/publish-update-feed.yml` queries the published releases,
selects the newest Main and newest Dev archive, and reconstructs the shared
feed from those channel heads before committing it to the machine-managed
`updates` branch. Workflow concurrency only serializes branch writes; feed
correctness does not depend on every release event remaining queued. A later
run always sees all published releases and repairs the complete two-channel
feed.

## Release assets

The reusable local entry point is:

```sh
./Scripts/release_app.sh --channel main v1.0.0
./Scripts/release_app.sh --channel dev v1.0.0-dev.100
```

It writes architecture-labelled files under `.build/release/`, for example:

```text
Vibe-Bar-1.0.0-macOS-arm64.zip
Vibe-Bar-1.0.0-dev.100-macOS-arm64.zip
appcast.xml
```

Pass `--base-appcast <path>` (or set `VIBEBAR_BASE_APPCAST`) to merge an
existing shared feed. CI downloads the current `updates` branch appcast
automatically. Do not use the single-release appcast as a replacement for the
shared feed unless it was generated from that base.

`Scripts/generate_update_feed.sh` is the narrower publication-time companion:
it takes one already reviewed release ZIP, validates the tag against the
version embedded in that archive, adds the item without pruning the supplied
base appcast, and signs it without rebuilding or replacing the release asset.
The publication workflow invokes it once per available channel head.

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
Actions secret `SPARKLE_ED_PRIVATE_KEY`, and immediately delete the temporary
file. Never commit or print the private key.

Local releases use the `astroqore-vibe-bar` Keychain account by default.
CI exposes `SPARKLE_ED_PRIVATE_KEY` only to the release-asset build step,
passes it to Sparkle over standard input, and fails before packaging when the
secret is absent. The value is not written to the checkout, command line,
release assets, or workflow output. `Scripts/release_app.sh` also rejects an
appcast that lacks an EdDSA archive signature or the expected build number.

The shared feed URL embedded in new builds is:

```text
https://raw.githubusercontent.com/AstroQore/vibe-bar/updates/appcast.xml
```

Each published release must contain the ZIP, its checksum, and the combined
`appcast.xml`. The `updates` branch is workflow-owned; do not edit its
appcast by hand. Existing builds that still use GitHub's `releases/latest`
feed bootstrap into the new system from the Main release's own appcast asset.

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
./Scripts/release_app.sh --channel main v1.0.0
```

Never commit certificates, passwords, Apple IDs, team IDs, or notarization
profiles to the repository.
