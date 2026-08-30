# Settings document v1

This is the cross-client, product-disabled document contract for
`settings.json`. It defines parsing and three-way merge semantics only. The
shared-store manifest remains `json_unversioned` / `legacy_unsafe`, and neither
client may use this document engine as write authority until the native writer,
lease eligibility, durable replace path, and joint interop tests ship together.

## Envelope

The top level is one JSON object, capped at 8 MiB.

- A legacy v0 document contains neither `schemaVersion` nor `revision` and is
  read as revision 0.
- A v1 document contains both `schemaVersion: 1` and an unsigned 64-bit integer
  `revision`.
- A partial envelope, non-object root, floating/negative/overflowing revision,
  or unknown schema fails closed.

All non-envelope values remain raw JSON. Unknown top-level keys and unknown
values nested inside known settings must survive semantically; clients must not
re-encode a partial typed projection as the whole document.

## Three-way patch

For every key the caller changed between `base` and `desired`:

- when `current == base`, apply `desired` (including removal);
- when `current == desired`, the change is already applied and is idempotent;
- otherwise report a structured conflict and apply nothing.

Keys where `desired == base` are untouched, even when another client changed
them in `current`. A successful non-empty patch emits v1 and increments the
current revision exactly once. `schemaVersion` and `revision` are protocol-owned
and cannot be patched. Revision overflow fails closed.

Desktop's first prospective writer whitelist is limited to display/refresh,
menu-bar, core-provider visibility/order, and plan-label preferences. This is a
future product gate, not permission granted by these fixtures.

## Fixtures

- `settings-document-v0-legacy.json` — envelope-free legacy input.
- `settings-document-v1-unknown.json` — v1 plus unknown top-level and nested
  fields that must survive.
- `settings-document-vectors.json` — one non-conflicting merge and one same-key
  conflict shared by Swift and Rust.

The adjacent SHA-256 sidecars authenticate exact fixture bytes. The native
directory is the source of truth; other implementations copy these files
byte-for-byte and verify them before decoding.
