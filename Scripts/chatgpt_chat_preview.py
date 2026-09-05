#!/usr/bin/env python3
"""Create a synthetic, isolated home for reviewing ChatGPT Chat UI. No credentials are read."""
import argparse
import hashlib
import json
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("/tmp/vibebar-chat-preview"))
    args = parser.parse_args()
    root = args.output.resolve()
    if root == Path.home().resolve():
        raise SystemExit("A preview must not use the real home directory")
    marker = root / "VIBEBAR_DEMO_HOME.txt"
    if root.exists() and any(root.iterdir()) and not marker.exists():
        raise SystemExit("Refusing to overwrite a directory that is not a Vibe Bar demo home")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    marker.write_text("Synthetic ChatGPT Chat review data; not a live account.\n")
    store = root / ".vibebar"
    (store / "quotas").mkdir(parents=True, exist_ok=True, mode=0o700)
    now = time.time() - 978307200  # Foundation Date's 2001 epoch.

    def write(path, value):
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        path.chmod(0o600)

    if not (store / "settings.json").exists():
        write(store / "settings.json", {
            "hasCompletedOnboarding": True, "mockEnabled": True,
            "displayMode": "remaining", "language": "zh-Hans",
            "visibleCoreProviders": ["codex"],
            "chatGPTChat": {"enabled": True},
        })
    if not (store / "demo_accounts.json").exists():
        write(store / "demo_accounts.json", {"schemaVersion": 1, "accounts": [
            {"id": "demo-codex", "tool": "codex", "source": "webCookie", "plan": "pro"},
            {"id": "demo-chatgpt-chat", "tool": "chatgptChat", "source": "webCookie", "plan": "pro"},
        ]})

    def bucket(key, title, remaining, used=None, limit=None, reset=None, window=None):
        quantity = {"remaining": remaining, "isEstimated": True, "coverageComplete": True}
        if used is not None:
            quantity.update(used=used, limit=limit)
        value = {"id": key, "title": title, "shortLabel": title, "usedPercent": 100 * used / limit if used is not None else 0, "quantity": quantity}
        if reset is not None:
            value["resetAt"] = now + reset
        if window is not None:
            value["rawWindowSeconds"] = window
        return value

    samples = {
        "demo-codex": {"tool": "codex", "plan": "pro", "queriedAt": now, "buckets": [
            {"id": "five_hour", "title": "5 Hours", "shortLabel": "5 Hours", "usedPercent": 44,
             "resetAt": now + 10800, "rawWindowSeconds": 18000},
            {"id": "weekly", "title": "Weekly", "shortLabel": "Weekly", "usedPercent": 65,
             "resetAt": now + 345600, "rawWindowSeconds": 604800},
        ], "resetCredits": {"availableCount": 3, "availableExpirations": [now + 15 * 86400, now + 28 * 86400 + 8100, now + 29 * 86400 + 14700]}},
        "demo-chatgpt-chat": {"tool": "chatgptChat", "plan": "pro", "queriedAt": now, "buckets": [
            bucket("image_gen", "Image Generation", 998, reset=36000),
            bucket("deep_research", "Deep Research", 247, used=3, limit=250, reset=1209600, window=2592000),
        ], "chatGPTChat": {"transport": "preview", "planVerified": True}},

    }
    for identity, value in samples.items():
        digest = hashlib.sha256(identity.encode()).hexdigest()
        write(store / "quotas" / f"quota-v1-{digest}.json", value)
    # Four reset types, retained as realistic synthetic before/after records.
    cycles = []
    kinds = ["onSchedule", "earlyClockRestarted", "earlyClockUnchanged", "earlyClockRestarted"]
    for n, kind in enumerate(kinds):
        completed = now - (4 - n) * 86400
        old_reset = completed if kind == "onSchedule" else completed + 2 * 86400
        new_reset = old_reset if kind == "earlyClockUnchanged" else completed + 7 * 86400
        details = {"previousResetAt": old_reset, "nextResetAt": new_reset,
                   "previousUsedPercent": [86, 50, 77, 91][n], "nextUsedPercent": 0,
                   "observedAfter": completed - 120, "observedBefore": completed, "plan": "pro"}
        if n == 3:
            details["creditRedeemedAt"] = completed - 30
        cycles.append({"accountId": "demo-codex", "tool": "codex", "bucketId": "weekly",
                       "windowEnd": completed, "windowStart": old_reset - 604800,
                       "rawWindowSeconds": 604800, "peakUsedPercent": details["previousUsedPercent"],
                       "lastUsedPercent": details["previousUsedPercent"], "observationCount": 30,
                       "firstSeenAt": completed - 86400, "lastSeenAt": completed - 120,
                       "completedAt": completed, "completionReason": "refillDetected",
                       "resetKind": kind, "resetDetails": details})
    write(store / "subscription_history.json", {"schemaVersion": 2, "legacyTimelineImported": True,
          "resetSignalRepairVersion": 1, "promotedProviderBackfillVersion": 1, "samples": cycles,
          "redemptions": [{"accountId": "demo-codex", "credit": {"id": "synthetic-credit", "redeemedAt": cycles[-1]["resetDetails"]["creditRedeemedAt"]}}]})
    print(root)


if __name__ == "__main__":
    main()
