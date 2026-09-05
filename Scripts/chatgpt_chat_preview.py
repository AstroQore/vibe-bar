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
            "chatGPTChat": {"enabled": True, "includeHistory": True, "astraWeeklyLimit": 200,
                            "solDailyLimit": 170, "sharedDailyLimit": 200},
        })
    if not (store / "demo_accounts.json").exists():
        write(store / "demo_accounts.json", {"schemaVersion": 1, "accounts": [
            {"id": "demo-codex", "tool": "codex", "source": "webCookie", "plan": "Example"},
            {"id": "demo-chatgpt-chat", "tool": "chatgptChat", "source": "webCookie", "plan": "Example"},
        ]})

    def bucket(key, title, remaining, used=None, limit=None, reset=None, window=None):
        quantity = {"remaining": remaining, "isEstimated": used is not None, "coverageComplete": True}
        if used is not None:
            quantity.update(used=used, limit=limit)
        value = {"id": key, "title": title, "shortLabel": title, "groupTitle": title,
                 "usedPercent": 100 * used / limit if used is not None else 0, "quantity": quantity}
        if reset is not None:
            value["resetAt"] = now + reset
        if window is not None:
            value["rawWindowSeconds"] = window
        return value

    samples = {
        "demo-codex": {"tool": "codex", "plan": "Example", "queriedAt": now, "buckets": [
            {"id": "five_hour", "title": "5 Hours", "shortLabel": "5 Hours", "usedPercent": 44,
             "resetAt": now + 10800, "rawWindowSeconds": 18000},
            {"id": "weekly", "title": "Weekly", "shortLabel": "Weekly", "usedPercent": 65,
             "resetAt": now + 345600, "rawWindowSeconds": 604800},
        ]},
        "demo-chatgpt-chat": {"tool": "chatgptChat", "plan": "Example", "queriedAt": now, "buckets": [
            bucket("image_gen", "Image Generation", 998, reset=36000),
            bucket("deep_research", "Deep Research", 247, reset=1209600),
            bucket("astra_weekly", "GPT-6 Pro", 176, used=24, limit=200, window=604800),
            bucket("sol_pro_daily", "GPT-5.6 Sol Pro", 153, used=17, limit=170, window=86400),
        ], "chatGPTChat": {"historyQueriedAt": now, "historyComplete": True,
                           "excludedWorkConversations": 3, "unclassifiedTurns": 0,
                           "failedConversations": 0, "observedFrom": now - 604800, "transport": "preview"}},
    }
    for identity, value in samples.items():
        digest = hashlib.sha256(identity.encode()).hexdigest()
        write(store / "quotas" / f"quota-v1-{digest}.json", value)
    print(root)


if __name__ == "__main__":
    main()
