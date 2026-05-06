# Vibe Bar

Vibe Bar is a native macOS menu-bar app for watching AI usage, quota pace, cost
history, service status, and compact floating-window summaries.

## Build

```bash
swift test
./Scripts/build_app.sh
open ".build/Vibe Bar.app"
```

The SwiftPM executable product is `VibeBar`; the packaged app is
`.build/Vibe Bar.app`.

## Local Data

Runtime state is stored in the current user's home directory:

```text
~/.vibebar/
├── settings.json
├── quotas/
├── cost_snapshots/
├── scan_cache/
├── service_status.json
└── cost_history.json
```

Vibe Bar reads local CLI credentials and Claude/Codex session JSONL logs. It
does not write to the CLI credential or session files. Claude web cookies and
the resolved Claude organization ID are stored in Keychain; older plaintext
cookie files under `~/.vibebar/cookies/` are migrated into Keychain and removed
on first read.

## Development Notes

- `Package.swift` defines the `VibeBar` executable and `VibeBarCore` library.
- `Scripts/build_app.sh` creates and ad-hoc signs the app bundle.
- `Resources/AppIcon.icns` is copied into the bundle during packaging.
- `swift test` covers the parser, settings, pricing, and usage utilities.
