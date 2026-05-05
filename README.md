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
├── cookies/
│   ├── claude-web.txt
│   └── claude-organization-id.txt
├── quotas/
├── cost_snapshots/
└── cost_history.json
```

Vibe Bar reads local CLI credentials and saved Claude web cookies. It does not
write to the CLI credential files. Claude organization IDs are resolved from the
Claude web organizations endpoint and cached locally after a Claude Web Login or
the first successful Claude web quota refresh.

## Development Notes

- `Package.swift` defines the `VibeBar` executable and `VibeBarCore` library.
- `Scripts/build_app.sh` creates and ad-hoc signs the app bundle.
- `Resources/AppIcon.icns` is copied into the bundle during packaging.
- `swift test` covers the parser, settings, pricing, and usage utilities.
