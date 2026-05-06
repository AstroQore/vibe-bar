## Summary

-

## Validation

- [ ] `swift build`
- [ ] `swift test`
- [ ] `./Scripts/build_app.sh release`
- [ ] `codesign -d --entitlements - ".build/Vibe Bar.app"`

## Privacy Checklist

- [ ] No raw tokens, cookies, JWTs, organization IDs, account IDs, or real email addresses.
- [ ] No personal `/Users/<name>` paths or machine-specific identifiers.
- [ ] New persistent data, if any, uses `VibeBarLocalStore` / `~/.vibebar/`.
- [ ] Logs and diagnostics use `SafeLog.sanitize` / `EmailMasker` where needed.

## Target Workflow

- [ ] Codex/OpenAI
- [ ] Claude Code/Anthropic
- [ ] Shared menu-bar, mini-window, or cost-history surface
- [ ] Build, packaging, or release metadata
