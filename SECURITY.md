# Security Policy

Vibe Bar reads local Codex/OpenAI and Claude Code/Anthropic credentials, session
logs, and usage data to show quota and cost information on your Mac. Please treat
security reports and diagnostics as sensitive by default.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if it is available on this repository.
If it is not available, open a minimal public issue that describes the affected
area without including secrets, then ask for a private channel.

Do not paste:

- API tokens, session cookies, JWTs, or Keychain values.
- Full CLI auth files or browser cookie exports.
- Real email addresses, organization IDs, account IDs, or internal workspace
  identifiers.
- Full unsanitized session logs.

## Supported Versions

Vibe Bar is early public-release software. Security fixes target the default
branch first, and release artifacts should be rebuilt from the fixed source.

## Security Expectations

- Secrets should stay in Keychain or existing provider credential stores.
- Derived usage and cost history should stay under `~/.vibebar/`.
- Logs and diagnostics should be sanitized before they are shared.
- The macOS app sandbox should remain enabled.
