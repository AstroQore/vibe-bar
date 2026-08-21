#!/usr/bin/env python3
"""Build a demo home for Vibe Bar's demo mode.

Vibe Bar's README screenshots come from the real app pointed at a synthetic
home directory (``VIBEBAR_DEMO_HOME``, see ``DemoMode.swift``). This script
builds that directory from a maintainer's live ``~/.vibebar`` store:

* Quota caches, reset-cycle history, fill and forecast timelines, cost
  snapshots, cost history, the per-request usage ledger, cached provider
  status, the pricing catalogs and the page layout are **copied**, so the
  numbers on screen are real usage rather than invented curves.
* Everything that identifies the maintainer is **replaced**: the OpenAI
  account id that keys the Codex quota becomes ``demo-codex``; remote
  machine aliases, workspace and device ids are rewritten; no credential,
  cookie, Keychain item, session transcript or ``/Users/<name>`` path is
  copied. Paths inside the ledger are already privacy hashes.
* Agent sessions and a library of skills are **fabricated**: a dozen
  sessions across Claude Code, Claude Cowork, Codex, ChatGPT Work and Grok
  Build under ``/Users/example/Code``, and two dozen public skills linked
  into every managed harness directory.

The output is a throwaway: it is written to ``/tmp/vibebar-demo-home`` by
default (short, because the MCP socket path inside it has a 104-byte limit)
and is not meant to be committed. Run it again right before capturing — the quota
countdowns and "updated N minutes ago" labels are relative to now.

Usage::

    ./Scripts/demo_home.py                      # ~ → /tmp/vibebar-demo-home
    ./Scripts/demo_home.py --output ~/demo      # elsewhere
    VIBEBAR_DEMO_HOME=/tmp/vibebar-demo-home ".build/Vibe Bar.app/Contents/MacOS/VibeBar"

Requires only the Python 3 that ships with Xcode's command line tools.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import random
import shutil
import sqlite3
import sys
import urllib.parse
import uuid
from pathlib import Path

# Foundation's `Date` encodes as seconds since 2001-01-01 00:00:00 UTC.
REFERENCE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc).timestamp()

DEMO_CODEX_ACCOUNT_ID = "demo-codex"
EXAMPLE_HOME = "/Users/example"

# Primary-account ids `AccountStore` can produce. The Codex id is the one
# exception — it is the OpenAI account UUID — and is discovered from the
# timelines instead.
FIXED_PRIMARY_IDS = {
    "oauth-claude": ("claude", "Claude OAuth", "oauthCLI"),
    "cli-claude": ("claude", "Claude Code", "cliDetected"),
    "web-claude": ("claude", "Claude Web", "webCookie"),
    "web-gemini": ("gemini", "Gemini Web", "webCookie"),
    "local-antigravity": ("antigravity", "Antigravity", "localProbe"),
    "web-antigravity": ("antigravity", "Antigravity Web", "webCookie"),
    "oauth-grok": ("grok", "Grok OAuth", "oauthCLI"),
    "web-grok": ("grok", "Grok Web", "webCookie"),
    "misc-cursor": ("cursor", "Cursor", "cliDetected"),
}
CODEX_SOURCES = {"oauth-codex": "oauthCLI", "web-codex": "webCookie", "cli-codex": "cliDetected"}


def log(message: str) -> None:
    print(f"demo-home: {message}")


def fail(message: str) -> None:
    print(f"demo-home: {message}", file=sys.stderr)
    sys.exit(1)


def quota_cache_name(account_id: str) -> str:
    digest = hashlib.sha256(account_id.encode("utf-8")).hexdigest()
    return f"quota-v1-{digest}.json"


def ref_seconds(when: dt.datetime) -> float:
    return when.timestamp() - REFERENCE_EPOCH


def iso(when: dt.datetime) -> str:
    return when.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{when.microsecond // 1000:03d}Z"


def stable_uuid(seed: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "vibebar-demo:" + seed))


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def read_json(path: Path) -> object:
    return json.loads(path.read_text())


def skill_directory_hash(directory: Path) -> str:
    """Mirror of `SkillDirectoryHasher.hash` for the registry's contentHash."""
    entries: list[tuple[str, Path]] = []

    def collect(current: Path, relative: str) -> None:
        for name in sorted(os.listdir(current)):
            if name.startswith("."):
                continue
            child = current / name
            rel = name if not relative else f"{relative}/{name}"
            if child.is_symlink() or child.is_file():
                entries.append((rel, child))
            elif child.is_dir():
                collect(child, rel)

    collect(directory, "")
    entries.sort(key=lambda entry: entry[0].encode("utf-8"))
    hasher = hashlib.sha256()
    for rel, child in entries:
        hasher.update(rel.encode("utf-8"))
        hasher.update(b"\0")
        if child.is_symlink():
            hasher.update(os.readlink(child).encode("utf-8"))
        else:
            hasher.update(child.read_bytes())
        hasher.update(b"\0")
    return hasher.hexdigest()


# ---------------------------------------------------------------------------
# Live store → demo store
# ---------------------------------------------------------------------------


class Builder:
    def __init__(self, source_home: Path, output_home: Path, days: int, now: dt.datetime, seed: int, fresh_days: int = 7):
        self.fresh_days = fresh_days
        self.source_home = source_home
        self.source = source_home / ".vibebar"
        self.output_home = output_home
        self.output = output_home / ".vibebar"
        self.days = days
        self.now = now
        self.random = random.Random(seed)
        self.codex_account_id: str | None = None
        self.codex_source = "oauthCLI"
        self.account_ids: dict[str, str] = {}  # live id → demo id
        self.remote_id_map: dict[str, str] = {}  # lower-cased live uuid → demo uuid
        self.machine_aliases: dict[str, str] = {}
        self.report: list[str] = []

    # -- discovery -----------------------------------------------------------

    def discover_accounts(self) -> None:
        quotas = self.source / "quotas"
        present = {p.name for p in quotas.glob("quota-v1-*.json")} if quotas.is_dir() else set()

        # Codex: the account UUID appears as `accountId` on every codex point.
        for name in ("fill_timeline.json", "forecast_timeline.json", "subscription_history.json"):
            path = self.source / name
            if not path.is_file():
                continue
            data = read_json(path)
            rows = data.get("points") or data.get("samples") or []
            for row in rows:
                if row.get("tool") == "codex" and row.get("accountId"):
                    candidate = str(row["accountId"])
                    if candidate in CODEX_SOURCES:
                        self.codex_source = CODEX_SOURCES[candidate]
                    if quota_cache_name(candidate) in present:
                        self.codex_account_id = candidate
                        break
            if self.codex_account_id:
                break

        if self.codex_account_id:
            self.account_ids[self.codex_account_id] = DEMO_CODEX_ACCOUNT_ID
        for fixed in CODEX_SOURCES:
            if quota_cache_name(fixed) in present and not self.codex_account_id:
                self.codex_account_id = fixed
                self.codex_source = CODEX_SOURCES[fixed]
                self.account_ids[fixed] = DEMO_CODEX_ACCOUNT_ID
        for account_id in FIXED_PRIMARY_IDS:
            if quota_cache_name(account_id) in present:
                self.account_ids[account_id] = account_id

        settings = read_json(self.source / "settings.json")
        for instance in settings.get("miscProviderInstances", []):
            account_id = f"misc-{instance['id']}"
            if quota_cache_name(account_id) in present:
                self.account_ids[account_id] = account_id

        if not self.account_ids:
            fail("no quota caches found under the source store; nothing to build a demo from")
        self.report.append(f"{len(self.account_ids)} accounts carried over")

    # -- helpers ---------------------------------------------------------------

    def rewrite_text(self, text: str) -> str:
        """Apply every identifier substitution to a JSON text blob."""
        for live, demo in self.account_ids.items():
            if live != demo:
                text = text.replace(live, demo)
        for live, demo in self.remote_id_map.items():
            text = text.replace(live, demo).replace(live.upper(), demo.upper())
        for live, demo in self.machine_aliases.items():
            text = text.replace(f'"{live}"', f'"{demo}"')
        return text

    def copy_json(self, name: str, required: bool = False) -> None:
        src = self.source / name
        if not src.is_file():
            if required:
                fail(f"missing {src}")
            return
        dst = self.output / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(self.rewrite_text(src.read_text()))

    def copy_tree_json(self, name: str) -> None:
        src = self.source / name
        if not src.is_dir():
            return
        for path in sorted(src.glob("*.json")):
            dst = self.output / name / path.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(self.rewrite_text(path.read_text()))

    # -- pieces ----------------------------------------------------------------

    def build_quota_caches(self) -> None:
        for live, demo in self.account_ids.items():
            src = self.source / "quotas" / quota_cache_name(live)
            dst = self.output / "quotas" / quota_cache_name(demo)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(self.rewrite_text(src.read_text()))

    def build_timelines(self) -> None:
        cutoff = ref_seconds(self.now - dt.timedelta(days=self.days))
        for name, key, stamp in (
            ("fill_timeline.json", "points", "sampledAt"),
            ("forecast_timeline.json", "points", "sampledAt"),
            ("subscription_history.json", "samples", "lastSeenAt"),
        ):
            src = self.source / name
            if not src.is_file():
                continue
            data = json.loads(self.rewrite_text(src.read_text()))
            rows = data.get(key, [])
            kept = [
                row
                for row in rows
                if row.get("accountId") in self.account_ids.values()
                and float(row.get(stamp, 0)) >= cutoff
            ]
            data[key] = kept
            write_json(self.output / name, data)
            self.report.append(f"{name}: {len(kept)}/{len(rows)} rows")

    def build_ledger(self) -> None:
        src = self.source / "usage_events.sqlite3"
        if not src.is_file():
            return
        dst = self.output / "usage_events.sqlite3"
        cutoff_day = (self.now - dt.timedelta(days=self.days)).strftime("%Y-%m-%d")
        # VACUUM INTO takes a consistent snapshot of a live database, WAL
        # included, without touching the source.
        with sqlite3.connect(f"file:{src}?mode=ro", uri=True) as live:
            live.execute("VACUUM INTO ?", (str(dst),))
        with sqlite3.connect(dst) as demo:
            before = demo.execute("SELECT COUNT(*) FROM usage_events").fetchone()[0]
            demo.execute("DELETE FROM usage_events WHERE day < ?", (cutoff_day,))
            tables = {row[0] for row in demo.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "usage_daily_rollups" in tables:
                demo.execute("DELETE FROM usage_daily_rollups WHERE day < ?", (cutoff_day,))
            if "ingested_files" in tables:
                # Keys of files the demo home does not have; a rescan never
                # runs in demo mode, so the table is dead weight.
                demo.execute("DELETE FROM ingested_files")
            demo.commit()
            after = demo.execute("SELECT COUNT(*) FROM usage_events").fetchone()[0]
            demo.execute("VACUUM")
        self.report.append(f"usage ledger: {after}/{before} requests")

    def build_remote(self) -> None:
        config_src = self.source / "remote_core.json"
        ledger_src = self.source / "remote_usage.sqlite3"
        if not config_src.is_file() or not ledger_src.is_file():
            return
        config = read_json(config_src)
        live_workspace = str(config["workspace_id"]).lower()
        live_core = str(config["core_device_id"]).lower()
        self.remote_id_map[live_workspace] = stable_uuid("workspace")
        self.remote_id_map[live_core] = stable_uuid("core")
        names = iter(["builder-01", "gpu-box", "staging-runner", "lab-mini"])
        for producer in sorted(config.get("probe_signing_public_keys", {})):
            self.remote_id_map[producer.lower()] = stable_uuid("probe:" + producer.lower())

        ledger_dst = self.output / "remote_usage.sqlite3"
        with sqlite3.connect(f"file:{ledger_src}?mode=ro", uri=True) as live:
            live.execute("VACUUM INTO ?", (str(ledger_dst),))
        with sqlite3.connect(ledger_dst) as demo:
            for (producer, alias) in demo.execute("SELECT producer_id, alias FROM remote_machines ORDER BY alias"):
                self.machine_aliases[alias] = next(names, f"probe-{alias[:2]}")
                self.remote_id_map.setdefault(str(producer).lower(), stable_uuid("probe:" + str(producer).lower()))
            for live_alias, demo_alias in self.machine_aliases.items():
                demo.execute("UPDATE remote_machines SET alias = ? WHERE alias = ?", (demo_alias, live_alias))
            columns = {
                "remote_machines": ("workspace_id", "producer_id"),
                "remote_source_generations": ("workspace_id", "producer_id"),
                "remote_usage_facts": ("workspace_id", "producer_id"),
                "remote_imported_batches": ("workspace_id", "producer_id"),
                "remote_sync_state": ("workspace_id", "core_device_id"),
            }
            existing = {row[0] for row in demo.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            for table, cols in columns.items():
                if table not in existing:
                    continue
                for col in cols:
                    for live_id, demo_id in self.remote_id_map.items():
                        demo.execute(
                            f"UPDATE {table} SET {col} = ? WHERE lower({col}) = ?", (demo_id, live_id)
                        )
            if "remote_sync_state" in existing:
                demo.execute("UPDATE remote_sync_state SET relay_cursor = NULL, last_error_code = NULL")
            demo.commit()
            demo.execute("VACUUM")

        # The relay URL is public documentation; the public keys are public
        # keys; every id is rewritten.
        rewritten = json.loads(self.rewrite_text(json.dumps(config)))
        write_json(self.output / "remote_core.json", rewritten)
        self.report.append(f"remote machines: {', '.join(self.machine_aliases.values())}")

    def build_settings(self) -> None:
        settings = json.loads(self.rewrite_text((self.source / "settings.json").read_text()))
        settings["launchAtLogin"] = False
        settings["mockEnabled"] = False
        settings["updateChannel"] = "main"
        settings["sessionBodyIndexingEnabled"] = True
        settings["menuBarBlockAlertSuppressed"] = True
        settings.setdefault("mcpServer", {})["enabled"] = True
        settings.setdefault("costData", {})["privacyModeEnabled"] = False

        # Show the misc providers that have a recent quota to show. A cache
        # from weeks ago renders as "Resets now" and "Updated 50 days ago",
        # which is a true statement about a plan that lapsed and a poor one
        # about the product.
        quotas = self.output / "quotas"
        fresh_after = ref_seconds(self.now - dt.timedelta(days=self.fresh_days))
        visible: list[str] = []
        for instance in settings.get("miscProviderInstances", []):
            cache = quotas / quota_cache_name(f"misc-{instance['id']}")
            show = False
            if cache.is_file():
                quota = read_json(cache)
                inner = quota.get("quota") or quota
                show = bool(inner.get("buckets")) and float(inner.get("queriedAt", 0)) >= fresh_after
            instance["isVisible"] = show
            if show:
                visible.append(instance["tool"])
        ordered = settings.get("miscProviderOrder") or []
        settings["visibleMiscProviders"] = [tool for tool in ordered if tool in visible] + [
            tool for tool in visible if tool not in ordered
        ]

        machine_ids = []
        for live_id in settings.get("remoteCostIncludedMachineIDs", []):
            machine_ids.append(self.rewrite_text(json.dumps(live_id)).strip('"'))
        settings["remoteCostIncludedMachineIDs"] = machine_ids

        mini = settings.setdefault("miniWindow", {})
        mini["wasOpen"] = False
        for key in ("savedOriginX", "savedOriginY", "savedPixelOriginX", "savedPixelOriginY", "savedScreenScale"):
            mini.pop(key, None)
        write_json(self.output / "settings.json", settings)
        self.report.append(f"misc providers visible: {len(visible)}")

    def build_demo_accounts(self) -> None:
        accounts = []
        if self.codex_account_id:
            plan = None
            cache = self.output / "quotas" / quota_cache_name(DEMO_CODEX_ACCOUNT_ID)
            if cache.is_file():
                plan = (read_json(cache).get("quota") or read_json(cache)).get("plan")
            accounts.append(
                {
                    "id": DEMO_CODEX_ACCOUNT_ID,
                    "tool": "codex",
                    "alias": "Codex OAuth" if self.codex_source == "oauthCLI" else "Codex",
                    "plan": plan,
                    "source": self.codex_source,
                }
            )
        for account_id, (tool, alias, source) in FIXED_PRIMARY_IDS.items():
            if account_id not in self.account_ids or account_id.startswith("misc-"):
                continue
            cache = read_json(self.output / "quotas" / quota_cache_name(account_id))
            accounts.append(
                {
                    "id": account_id,
                    "tool": tool,
                    "alias": alias,
                    "plan": (cache.get("quota") or cache).get("plan"),
                    "source": source,
                }
            )
        write_json(self.output / "demo_accounts.json", {"schemaVersion": 1, "accounts": accounts})

    def build_static_copies(self) -> None:
        self.copy_json("cost_history.json")
        self.copy_tree_json("cost_snapshots")
        self.copy_json("service_status.json")
        self.copy_json("pricing_cache.json")
        self.copy_json("pricing_refresh_status.json")
        self.copy_tree_json("pricing_sources")
        self.copy_json("layout.json")
        self.copy_json("antigravity_model_labels.json")
        # No mini_window_geometry.json: without one the mini window takes
        # its default place, top-right of the display demo mode presents on.

    # -- fabricated: sessions ----------------------------------------------------

    def build_sessions(self) -> None:
        sessions = demo_sessions(self.now, self.random)
        counts: dict[str, int] = {}
        for session in sessions:
            writer = SESSION_WRITERS[session["harness"]]
            writer(self.output_home, session)
            counts[session["harness"]] = counts.get(session["harness"], 0) + 1
        self.report.append("sessions: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))

    # -- fabricated: skills ------------------------------------------------------

    def build_skills(self) -> None:
        ssot = self.output_home / ".agents" / "skills"
        ssot.mkdir(parents=True, exist_ok=True)
        app_dirs = {
            "codex": self.output_home / ".codex" / "skills",
            "claude": self.output_home / ".claude" / "skills",
            "antigravity": self.output_home / ".gemini" / "config" / "skills",
            "grok": self.output_home / ".grok" / "skills",
            "cursor": self.output_home / ".cursor" / "skills",
        }
        for path in app_dirs.values():
            path.mkdir(parents=True, exist_ok=True)

        registry = []
        base = self.now - dt.timedelta(days=40)
        for index, skill in enumerate(DEMO_SKILLS):
            directory = ssot / skill["name"]
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "SKILL.md").write_text(skill_markdown(skill))
            for extra_name, extra_body in skill.get("files", {}).items():
                extra = directory / extra_name
                extra.parent.mkdir(parents=True, exist_ok=True)
                extra.write_text(extra_body)
            apps = {}
            for app in skill["apps"]:
                link = app_dirs[app] / skill["name"]
                if link.is_symlink() or link.exists():
                    link.unlink()
                os.symlink(str(directory.resolve()), str(link))
                apps[app] = {"method": "symlink", "adopted": False}
            installed = base + dt.timedelta(days=index * 1.7, hours=self.random.uniform(0, 9))
            registry.append(
                {
                    "id": f"local:{skill['name']}",
                    "name": skill["name"],
                    "description": skill["description"],
                    "directory": skill["name"],
                    "installedAt": ref_seconds(installed),
                    "updatedAt": ref_seconds(installed + dt.timedelta(seconds=2)),
                    "contentHash": skill_directory_hash(directory),
                    "apps": apps,
                }
            )
        write_json(
            self.output / "skills.json",
            {
                "schemaVersion": 1,
                "discoverRepos": ["anthropics/skills", "AstroQore/vibe-bar", "cloudflare/skills"],
                "skills": registry,
            },
        )
        self.report.append(f"skills: {len(registry)} across {len(app_dirs)} harness dirs")

    # -- driver ------------------------------------------------------------------

    def build(self) -> None:
        self.output.mkdir(parents=True, exist_ok=True)
        os.chmod(self.output, 0o700)
        self.discover_accounts()
        self.build_remote()  # first: fills the remote id map other files use
        self.build_quota_caches()
        self.build_timelines()
        self.build_ledger()
        self.build_settings()
        self.build_demo_accounts()
        self.build_static_copies()
        self.build_sessions()
        self.build_skills()
        (self.output_home / "README.txt").write_text(
            "Vibe Bar demo home. Generated by Scripts/demo_home.py; safe to delete.\n"
            "Point the app at it with VIBEBAR_DEMO_HOME=<this directory>.\n"
        )


# ---------------------------------------------------------------------------
# Fabricated sessions
# ---------------------------------------------------------------------------

PROJECTS = {
    "storefront-web": f"{EXAMPLE_HOME}/Code/storefront-web",
    "ingest-pipeline": f"{EXAMPLE_HOME}/Code/ingest-pipeline",
    "ops-runbook": f"{EXAMPLE_HOME}/Code/ops-runbook",
    "mobile-client": f"{EXAMPLE_HOME}/Code/mobile-client",
    "design-tokens": f"{EXAMPLE_HOME}/Code/design-tokens",
    "vibe-bar": f"{EXAMPLE_HOME}/Code/vibe-bar",
}


def demo_sessions(now: dt.datetime, rng: random.Random) -> list[dict]:
    """Sessions newest-first; the first one is the transcript the Sessions
    page opens on, so it carries a full conversation."""
    h = dt.timedelta(hours=1)
    m = dt.timedelta(minutes=1)
    return [
        {
            "harness": "claude-code",
            "project": "vibe-bar",
            "model": "claude-opus-5",
            "branch": "feat/usage-filters",
            "started": now - 2 * h - 14 * m,
            "turns": [
                ("user", "The harness filter chips on the Usage Stats page scroll off the right edge at the default window width. Can you make the row wrap instead, and keep the selected chip visible?"),
                ("assistant", "I'll look at how the chip row is laid out first — it is an HStack inside a horizontal ScrollView in `UsageFiltersBar.swift` — and then decide between wrapping and a trailing overflow menu."),
                ("tool", "Read Sources/VibeBarApp/Views/Workbench/UsageFiltersBar.swift"),
                ("tool", "Grep harnessChips( Sources/VibeBarApp"),
                ("assistant", "Wrapping is the better fit: the chips are a filter, not a tab bar, so two rows read fine and nothing needs to scroll. The existing `FlowLayout` in `ColumnMasonryLayout.swift` already handles wrapping with a fixed spacing, so I'll reuse it rather than add another layout type.\n\nChanges:\n- Replace the `ScrollView(.horizontal)` with `FlowLayout(spacing: 6)`.\n- Drop the `scrollTo(selected)` call, which no longer applies.\n- Keep the `All harnesses` chip pinned first by sorting it ahead of the rest."),
                ("tool", "Edit Sources/VibeBarApp/Views/Workbench/UsageFiltersBar.swift"),
                ("tool", "Bash swift build 2>&1 | tail -3"),
                ("tool", "Build complete! (41.2s)"),
                ("assistant", "Builds clean. I also checked the Settings › Layout page, which embeds the same bar in a narrower column — it wraps to three rows there and the selected chip stays in view.\n\nOne thing worth a look: with twelve harnesses the second row starts with `Gemini CLI`, which is deprecated. Do you want it hidden when it has no usage in the selected range?"),
                ("user", "Yes, hide it when it has nothing in range. Then run the tests."),
                ("tool", "Edit Sources/VibeBarApp/Controllers/UsageStatsViewModel.swift"),
                ("tool", "Bash swift test 2>&1 | tail -5"),
                ("tool", "Executed 212 tests, with 0 failures (0 unexpected) in 18.409 seconds"),
                ("assistant", "Done. Harnesses with zero requests in the selected range are filtered out of the chip row (they stay in the breakdown tables so the totals do not change), and all 212 tests pass.\n\nSummary of the diff:\n- `UsageFiltersBar.swift`: chips wrap with `FlowLayout`, `All harnesses` pinned first.\n- `UsageStatsViewModel.swift`: `visibleHarnesses` excludes zero-request harnesses.\n- No new files, no settings changes."),
            ],
        },
        {
            "harness": "codex",
            "project": "ingest-pipeline",
            "model": "gpt-5.6-sol",
            "started": now - 3 * h - 41 * m,
            "turns": [
                ("user", "Backfill the events table from the archived parquet files for July, in 1-day batches, and stop on the first batch whose row count disagrees with the manifest."),
                ("assistant", "I'll read the manifest format and the existing loader before writing the backfill, so the batch boundaries line up with what the nightly job produces."),
                ("tool", "shell: ls data/archive/2026/07 | head"),
                ("tool", "shell: sed -n 1,80p loaders/manifest.py"),
                ("assistant", "The manifest keys batches by `YYYY-MM-DD` and records `row_count` per file, so a per-day reconciliation is straightforward. I've added `scripts/backfill_events.py`: it iterates the days, loads each parquet into a staging table, compares `COUNT(*)` with the manifest, and only then swaps the partition in. A mismatch aborts with the day and both counts.\n\nDry run over July: 31 batches, all counts match. Run it for real?"),
                ("user", "Go ahead and run it against the local database"),
                ("tool", "shell: python scripts/backfill_events.py --from 2026-07-01 --to 2026-07-31 --apply"),
                ("tool", "2026-07-01 … 2026-07-31: 31 batches applied, 4,812,330 rows, 0 mismatches"),
                ("assistant", "Backfill complete: 31 batches, 4,812,330 rows, no mismatches. The staging table is dropped and the script is idempotent, so re-running a day is safe."),
            ],
        },
        {
            "harness": "grok-build",
            "project": "storefront-web",
            "model": "grok-4.6",
            "started": now - 5 * h - 3 * m,
            "title": "Checkout step indicator loses state on refresh",
            "summary": "Persisted the checkout step in the URL hash and restored it on load; added a Playwright test for the refresh case.",
            "turns": [
                ("user", "Reloading on step 3 of checkout drops the user back to step 1. Persist the step and write a test for it."),
                ("assistant", "The step lives only in component state. I'll mirror it into the URL hash (`#step=3`), read it back on mount, and guard against a hash pointing past the last completed step."),
                ("tool", "edit src/checkout/StepIndicator.tsx"),
                ("tool", "run npx playwright test tests/checkout-refresh.spec.ts"),
                ("assistant", "Refreshing on step 3 now lands on step 3; jumping to step 4 by hand is clamped back to 3 because payment has not been entered. One new Playwright test covers both."),
            ],
        },
        {
            "harness": "claude-code",
            "project": "ops-runbook",
            "model": "claude-sonnet-5",
            "branch": "main",
            "started": now - 7 * h - 22 * m,
            "turns": [
                ("user", "Reconcile the on-call rotation in rotation.yaml with the calendar export in exports/august.ics and list every week where they disagree."),
                ("tool", "Read rotation.yaml"),
                ("tool", "Bash python3 -c \"import icalendar\" || pip install icalendar"),
                ("assistant", "Two weeks disagree:\n\n- Aug 10–16: `rotation.yaml` names the platform team, the calendar has the data team.\n- Aug 24–30: the calendar has a swap that never made it into the file.\n\nEverything else matches. I have not changed either source — which one is authoritative?"),
            ],
        },
        {
            "harness": "chatgpt-work",
            "project": "design-tokens",
            "model": "gpt-5.6-sol",
            "started": now - 9 * h,
            "turns": [
                ("user", "Rename the `brand-*` color tokens to `accent-*` across the token JSON, the Tailwind config, and the Storybook docs. Keep a deprecated alias for one release."),
                ("assistant", "Renaming 14 tokens. I'll keep `brand-*` as aliases that resolve to the new names and emit a build-time deprecation warning, so consumers have a release to migrate."),
                ("tool", "shell: rg -l 'brand-' tokens tailwind.config.ts stories"),
                ("tool", "shell: node scripts/build-tokens.js"),
                ("assistant", "14 tokens renamed, 14 aliases added, Storybook rebuilt. The aliases are tagged `deprecated: true` in the token JSON so the docs page lists them under a separate heading."),
            ],
        },
        {
            "harness": "codex",
            "project": "mobile-client",
            "model": "gpt-5.6-sol",
            "started": now - 11 * h - 30 * m,
            "turns": [
                ("user", "Audit the dependency manifest for packages that have not been updated upstream in over a year and say which ones are load-bearing."),
                ("tool", "shell: cat Package.swift"),
                ("tool", "shell: for p in $(grep -o 'url: \"[^\"]*\"' Package.swift | cut -d'\"' -f2); do echo $p; done"),
                ("assistant", "Three packages are older than a year: a keychain wrapper (used in 2 files, trivially replaceable), a JSON schema validator (used only in tests), and the charting library (used across 19 views — load-bearing, and the hardest to swap). I'd keep the chart library and open an issue upstream; the other two can go in a day."),
            ],
        },
        {
            "harness": "claude-cowork",
            "project": "ops-runbook",
            "model": "claude-opus-5",
            "branch": "main",
            "started": now - 26 * h,
            "turns": [
                ("user", "Turn the incident notes from last Tuesday into a postmortem using the template in docs/postmortem-template.md."),
                ("tool", "Read docs/postmortem-template.md"),
                ("tool", "Read incidents/2026-08-11.md"),
                ("assistant", "Drafted `incidents/2026-08-11-postmortem.md`. Timeline, impact and detection are filled from the notes; the root cause section quotes the config diff; the action items are the three the notes already agreed on plus one I added — alerting on the queue depth that was visible 40 minutes before the page."),
            ],
        },
        {
            "harness": "claude-code",
            "project": "storefront-web",
            "model": "claude-opus-5",
            "branch": "fix/cart-rounding",
            "started": now - 31 * h,
            "turns": [
                ("user", "Cart totals are off by a cent when a percentage discount applies to three or more items. Find out why and fix it."),
                ("tool", "Grep applyDiscount src/cart"),
                ("tool", "Read src/cart/pricing.ts"),
                ("assistant", "The discount is applied per line and rounded per line, then summed. Three items at $9.99 with 15% off round to $8.49 each ($25.47), while the intended total is 85% of $29.97 = $25.47 — but at four items the per-line rounding drifts by a cent. Fix: compute the discount on the subtotal and distribute the remainder to the last line, which is what the invoice PDF already does."),
                ("tool", "Edit src/cart/pricing.ts"),
                ("tool", "Bash npm test -- pricing"),
                ("assistant", "Fixed and covered with a property test over 1–12 items and every discount from 1–50%. Totals now match the invoice generator exactly."),
            ],
        },
        {
            "harness": "grok-build",
            "project": "ingest-pipeline",
            "model": "grok-4.6",
            "started": now - 2 * dt.timedelta(days=1) - 3 * h,
            "title": "Add retry with jitter to the S3 fetcher",
            "summary": "Wrapped the fetch in an exponential backoff with full jitter, capped at 5 attempts; surfaced the attempt count in logs.",
            "turns": [
                ("user", "The S3 fetcher fails the whole batch on a single 503. Add retries with jitter."),
                ("assistant", "Adding exponential backoff with full jitter (base 200 ms, cap 5 s, 5 attempts) around the fetch, and logging the attempt number so a noisy hour is visible in the logs."),
                ("tool", "edit fetchers/s3.py"),
                ("assistant", "Done. A 503 on attempt 1 now retries; a batch only fails after five consecutive failures on the same object."),
            ],
        },
        {
            "harness": "codex",
            "project": "vibe-bar",
            "model": "gpt-5.6-sol",
            "started": now - 2 * dt.timedelta(days=1) - 9 * h,
            "turns": [
                ("user", "Review the open PR for the session index memory bound and tell me whether the page window can still grow without limit on a very large transcript."),
                ("tool", "shell: gh pr diff 211 --name-only"),
                ("tool", "shell: sed -n 1,120p Sources/VibeBarCore/Models/TranscriptPageWindow.swift"),
                ("assistant", "It cannot. The window is capped at 400 messages and the index stores byte offsets rather than message bodies, so a 200 MB transcript costs the same as a 2 MB one until a page is opened. One nit: the cap is a literal in two places; a named constant would keep them from drifting."),
            ],
        },
        {
            "harness": "claude-code",
            "project": "design-tokens",
            "model": "claude-sonnet-5",
            "branch": "main",
            "started": now - 3 * dt.timedelta(days=1) - 2 * h,
            "turns": [
                ("user", "Generate the dark-mode values for every surface token by lowering lightness 6 steps in OKLCH, and show me the before/after table."),
                ("tool", "Bash node scripts/oklch-shift.js --steps -6 --filter surface"),
                ("assistant", "12 surface tokens shifted. The table is in `docs/dark-surfaces.md`; three tokens clipped at the gamut boundary and were clamped, which I've marked with an asterisk."),
            ],
        },
        {
            "harness": "claude-code",
            "project": "mobile-client",
            "model": "claude-opus-5",
            "branch": "feat/offline-queue",
            "started": now - 3 * dt.timedelta(days=1) - 6 * h,
            "turns": [
                ("user", "Design an offline write queue for the notes feature: writes must survive a force quit and replay in order once the network returns."),
                ("assistant", "Proposal: an append-only SQLite table of pending mutations keyed by a monotonic sequence, written in the same transaction as the local change; a replayer that drains in order, stops on the first non-retryable error, and marks the row with the server's response id for idempotency. I'll write the design note first, then the schema."),
                ("tool", "Write docs/offline-queue.md"),
                ("assistant", "Design note written with the table schema, the replay state machine, and the three failure cases (duplicate replay, conflicting server state, app killed mid-replay). Ready to implement when you've had a look."),
            ],
        },
    ]


def _claude_lines(session: dict, cwd: str, session_id: str) -> list[dict]:
    lines = []
    when = session["started"]
    parent = None
    counter = 0
    version = "2.1.8"
    for role, text in session["turns"]:
        when = when + dt.timedelta(seconds=random.Random(counter).randint(12, 140))
        entry_id = stable_uuid(f"{session_id}:{counter}")
        base = {
            "parentUuid": parent,
            "isSidechain": False,
            "userType": "external",
            "cwd": cwd,
            "sessionId": session_id,
            "version": version,
            "gitBranch": session.get("branch", "main"),
            "uuid": entry_id,
            "timestamp": iso(when),
        }
        if role == "user":
            base.update({"type": "user", "message": {"role": "user", "content": text}})
        elif role == "assistant":
            base.update(
                {
                    "type": "assistant",
                    "requestId": "req_" + entry_id.replace("-", "")[:24],
                    "message": {
                        "id": "msg_" + entry_id.replace("-", "")[:24],
                        "type": "message",
                        "role": "assistant",
                        "model": session["model"],
                        "content": [{"type": "text", "text": text}],
                        "stop_reason": "end_turn",
                        "usage": {
                            "input_tokens": 4 + counter * 3,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 18_000 + counter * 900,
                            "output_tokens": max(40, len(text) // 3),
                        },
                    },
                }
            )
        else:  # tool call + result, as Claude Code records them
            name, _, argument = text.partition(" ")
            tool_id = "toolu_" + entry_id.replace("-", "")[:22]
            if name in ("Read", "Grep", "Edit", "Write", "Bash"):
                key = {"Read": "file_path", "Grep": "pattern", "Edit": "file_path", "Write": "file_path", "Bash": "command"}[name]
                lines.append(
                    {
                        **base,
                        "type": "assistant",
                        "message": {
                            "id": "msg_" + entry_id.replace("-", "")[:24],
                            "type": "message",
                            "role": "assistant",
                            "model": session["model"],
                            "content": [{"type": "tool_use", "id": tool_id, "name": name, "input": {key: argument}}],
                            "stop_reason": "tool_use",
                            "usage": {"input_tokens": 3, "cache_read_input_tokens": 19_000, "output_tokens": 60},
                        },
                    }
                )
                parent = entry_id
                counter += 1
                when = when + dt.timedelta(seconds=2)
                result_id = stable_uuid(f"{session_id}:{counter}")
                base = {**base, "uuid": result_id, "parentUuid": parent, "timestamp": iso(when)}
                base.update(
                    {
                        "type": "user",
                        "message": {
                            "role": "user",
                            "content": [{"type": "tool_result", "tool_use_id": tool_id, "content": f"({name} completed)"}],
                        },
                        "toolUseResult": {"stdout": ""},
                    }
                )
                entry_id = result_id
            else:
                # Bare output lines ("Build complete!") ride as tool results.
                base.update(
                    {
                        "type": "user",
                        "message": {
                            "role": "user",
                            "content": [{"type": "tool_result", "tool_use_id": tool_id, "content": text}],
                        },
                        "toolUseResult": {"stdout": text},
                    }
                )
        lines.append(base)
        parent = entry_id
        counter += 1
    session["last_active"] = when
    return lines


def _claude_project_dir(cwd: str) -> str:
    return cwd.replace("/", "-")


def write_claude_code(home: Path, session: dict) -> None:
    cwd = PROJECTS[session["project"]]
    session_id = stable_uuid("claude:" + session["project"] + iso(session["started"]))
    path = home / ".claude" / "projects" / _claude_project_dir(cwd) / f"{session_id}.jsonl"
    _write_jsonl(path, _claude_lines(session, cwd, session_id), session)


def write_claude_cowork(home: Path, session: dict) -> None:
    cwd = PROJECTS[session["project"]]
    session_id = stable_uuid("cowork:" + session["project"] + iso(session["started"]))
    workspace = stable_uuid("cowork-workspace:" + session["project"])
    path = (
        home
        / "Library/Application Support/Claude/local-agent-mode-sessions"
        / workspace
        / ".claude"
        / "projects"
        / _claude_project_dir(cwd)
        / f"{session_id}.jsonl"
    )
    _write_jsonl(path, _claude_lines(session, cwd, session_id), session)


def write_codex(home: Path, session: dict, originator: str = "codex_cli_rs") -> None:
    cwd = PROJECTS[session["project"]]
    session_id = stable_uuid("codex:" + session["project"] + iso(session["started"]))
    when = session["started"]
    lines = [
        {
            "timestamp": iso(when),
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "timestamp": iso(when),
                "cwd": cwd,
                "originator": originator,
                "cli_version": "0.62.0",
                "source": "cli" if originator == "codex_cli_rs" else "vscode",
                "model_provider": "openai",
            },
        },
        {
            "timestamp": iso(when),
            "type": "turn_context",
            "payload": {
                "cwd": cwd,
                "approval_policy": "on-request",
                "sandbox_policy": {"type": "workspace-write"},
                "model": session["model"],
                "effort": "high",
                "summary": "auto",
            },
        },
    ]
    call = 0
    for index, (role, text) in enumerate(session["turns"]):
        when = when + dt.timedelta(seconds=random.Random(index).randint(10, 120))
        if role == "user":
            payload = {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}
        elif role == "assistant":
            payload = {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}
        elif text.startswith("shell: "):
            call += 1
            payload = {
                "type": "function_call",
                "name": "shell",
                "arguments": json.dumps({"command": ["bash", "-lc", text[len("shell: "):]]}),
                "call_id": f"call_{call}",
            }
        else:
            payload = {"type": "function_call_output", "call_id": f"call_{call}", "output": text}
        lines.append({"timestamp": iso(when), "type": "response_item", "payload": payload})
    lines.append(
        {
            "timestamp": iso(when),
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 48_210,
                        "cached_input_tokens": 41_000,
                        "output_tokens": 3_120,
                        "reasoning_output_tokens": 1_900,
                        "total_tokens": 51_330,
                    },
                    "model_context_window": 272_000,
                },
            },
        }
    )
    session["last_active"] = when
    stamp = session["started"].astimezone(dt.timezone.utc)
    path = (
        home
        / ".codex/sessions"
        / stamp.strftime("%Y/%m/%d")
        / f"rollout-{stamp.strftime('%Y-%m-%dT%H-%M-%S')}-{session_id}.jsonl"
    )
    _write_jsonl(path, lines, session)


def write_chatgpt_work(home: Path, session: dict) -> None:
    write_codex(home, session, originator="codex_work_desktop")


def write_grok_build(home: Path, session: dict) -> None:
    cwd = PROJECTS[session["project"]]
    session_id = stable_uuid("grok:" + session["project"] + iso(session["started"]))
    encoded = urllib.parse.quote(cwd, safe="")
    directory = home / ".grok" / "sessions" / encoded / session_id
    directory.mkdir(parents=True, exist_ok=True)
    when = session["started"]
    history = []
    for index, (role, text) in enumerate(session["turns"]):
        when = when + dt.timedelta(seconds=random.Random(index).randint(10, 120))
        kind = {"user": "user", "assistant": "assistant", "tool": "tool_result"}[role]
        history.append({"type": kind, "content": text, "timestamp": iso(when)})
    session["last_active"] = when
    summary = {
        "info": {"id": session_id, "cwd": cwd, "created_at": iso(session["started"]), "updated_at": iso(when)},
        "generated_title": session["title"],
        "session_summary": session["summary"],
        "current_model_id": session["model"],
        "created_at": iso(session["started"]),
        "last_active_at": iso(when),
        "num_chat_messages": len(history),
    }
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    _write_jsonl(directory / "chat_history.jsonl", history, session)


def _write_jsonl(path: Path, lines: list[dict], session: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for line in lines:
            handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    stamp = session.get("last_active", session["started"]).timestamp()
    os.utime(path, (stamp, stamp))


SESSION_WRITERS = {
    "claude-code": write_claude_code,
    "claude-cowork": write_claude_cowork,
    "codex": write_codex,
    "chatgpt-work": write_chatgpt_work,
    "grok-build": write_grok_build,
}


# ---------------------------------------------------------------------------
# Fabricated skills
# ---------------------------------------------------------------------------

ALL_APPS = ["codex", "claude", "antigravity", "grok", "cursor"]

DEMO_SKILLS = [
    {"name": "agents-sdk", "description": "Build AI agents on Cloudflare Workers using the Agents SDK. Load when creating stateful agents, durable workflows, real-time WebSocket apps, scheduled tasks, MCP servers, chat applications, voice agents, or browser automation.", "apps": ALL_APPS},
    {"name": "cloudflare", "description": "Comprehensive Cloudflare platform skill covering Workers, Pages, storage (KV, D1, R2), AI (Workers AI, Vectorize, Agents SDK), networking (Tunnel, Spectrum), security (WAF, DDoS), and infrastructure-as-code. Biases towards retrieval from Cloudflare docs over pre-trained knowledge.", "apps": ALL_APPS},
    {"name": "cloudflare-email-service", "description": "Send and receive transactional emails with Cloudflare Email Service (Email Sending + Email Routing). Use when building email sending, email routing, Agents SDK email handling, or integrating email into any app.", "apps": ["codex", "claude"]},
    {"name": "code-review", "description": "Run an extremely strict maintainability review for abstraction quality, giant functions, duplicated logic, and naming. Produces a ranked list of findings with the line they anchor to.", "apps": ALL_APPS},
    {"name": "dataviz", "description": "Use before creating any chart, graph, plot or dashboard in any medium. A form heuristic, a colour formula with a runnable validator, mark specs and interaction rules that read as one system in light and dark.", "apps": ["claude", "cursor"]},
    {"name": "docx", "description": "Create, read, edit and manipulate Word documents (.docx) and templates (.dotx): tables of contents, headings, page numbers, tracked changes, comments, and converting content into a polished document.", "apps": ["claude", "codex", "antigravity"]},
    {"name": "durable-objects", "description": "Create and review Cloudflare Durable Objects. Use when building stateful coordination (chat rooms, multiplayer games, booking systems), implementing RPC methods, SQLite storage, alarms, WebSockets, or reviewing DO code for best practices.", "apps": ALL_APPS},
    {"name": "frontend-design", "description": "Guidance for distinctive, intentional visual design when building new UI or reshaping an existing one. Helps with aesthetic direction, typography, and making choices that don't read as templated defaults.", "apps": ["claude", "cursor", "antigravity"]},
    {"name": "gh-address-comments", "description": "Help address review and issue comments on the open GitHub PR for the current branch: fetch the threads, group them by file, apply the change or reply with a reason, and resolve what was handled.", "apps": ["codex", "claude", "grok"]},
    {"name": "harness-dispatch", "description": "Choose a harness and model tier for a sub-task, write a self-contained brief, and hand it to a subagent or an external agent CLI. Covers quota-aware scheduling through Vibe Bar's MCP server with a static priority fallback.", "apps": ALL_APPS},
    {"name": "jupyter-notebook", "description": "Use when the user asks to create, scaffold, or edit Jupyter notebooks (.ipynb): cell structure, kernel selection, outputs, and converting between notebook and script form.", "apps": ["codex", "claude"]},
    {"name": "pdf", "description": "Use when tasks involve reading, creating, or reviewing PDF files where rendering matters: extract text and tables, fill forms, merge and split, annotate, and produce print-ready output.", "apps": ALL_APPS},
    {"name": "playwright", "description": "Use when the task requires automating a real browser from the terminal: navigate, click, fill forms, take screenshots, assert on the DOM, and record traces for flaky tests.", "apps": ["codex", "claude", "cursor"]},
    {"name": "pptx", "description": "Create, read and edit PowerPoint presentations: slide layouts, speaker notes, charts and images, and converting an outline into a deck that follows a template.", "apps": ["claude", "antigravity"]},
    {"name": "release-notes", "description": "Draft release notes from the merged pull requests between two tags. Groups by area, keeps the imperative subject lines, and links every PR; never invents a change that is not in the log.", "apps": ["codex", "claude", "grok"]},
    {"name": "sandbox-sdk", "description": "Build sandboxed applications for secure code execution. Load when building AI code execution, code interpreters, CI/CD systems, interactive dev environments, or executing untrusted code.", "apps": ["codex", "claude"]},
    {"name": "skill-creator", "description": "Create new skills, modify and improve existing skills, and measure skill performance. Use when users want to create a skill from scratch, run evals to test a skill, or optimise a skill's description for better triggering accuracy.", "apps": ALL_APPS},
    {"name": "swift-concurrency-review", "description": "Review Swift code for strict-concurrency correctness: actor isolation, Sendable boundaries, main-actor UI access, and Task lifetimes. Flags each finding with the rule it breaks and the smallest fix.", "apps": ["codex", "claude", "cursor"]},
    {"name": "turnstile-spin", "description": "Set up Cloudflare Turnstile end-to-end in a project: scan the codebase, create the widget via the Cloudflare API, embed it where user requests need bot verification, and wire canonical server-side siteverify.", "apps": ["codex", "claude"]},
    {"name": "vibe-bar", "description": "Ask Vibe Bar about this Mac's AI subscription quota, token usage, spend and local agent sessions over MCP. Quota answers use company names, usage answers use harness names, and the two are never mixed in one list.", "apps": ALL_APPS},
    {"name": "web-perf", "description": "Analyse web performance using the Chrome DevTools MCP: measure Core Web Vitals, record a trace, find the long tasks and layout shifts, and propose the smallest change that moves the metric.", "apps": ["claude", "cursor", "antigravity"]},
    {"name": "workers-best-practices", "description": "Review and author Cloudflare Workers code against production best practices. Load when writing new Workers, reviewing Worker code, configuring wrangler.jsonc, or checking for common anti-patterns.", "apps": ALL_APPS},
    {"name": "wrangler", "description": "Cloudflare Workers CLI for deploying, developing, and managing Workers, KV, R2, D1, Vectorize, Hyperdrive, Workers AI, Containers, Queues, Workflows, Pipelines, and Secrets Store. Load before running wrangler commands.", "apps": ["codex", "claude", "grok"]},
    {"name": "xlsx", "description": "Create, read and edit spreadsheets: formulas, named ranges, pivot-style summaries, conditional formatting, and importing CSV into a workbook that recalculates cleanly.", "apps": ["claude", "codex"]},
]


def skill_markdown(skill: dict) -> str:
    description = skill["description"].replace('"', '\\"')
    return (
        "---\n"
        f"name: {skill['name']}\n"
        f'description: "{description}"\n'
        "---\n\n"
        f"# {skill['name']}\n\n"
        f"{skill['description']}\n\n"
        "## When to use\n\n"
        "Load this skill when the task matches the description above. It is a\n"
        "placeholder body written for Vibe Bar's demo home; the real skill of\n"
        "the same name lives in its own repository.\n"
    )


# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=str(Path.home()), help="home directory to snapshot (default: ~)")
    # Short on purpose: the demo home hosts ~/.vibebar/mcp.sock, and a Unix
    # socket path is limited to 104 bytes — a checkout deep in a worktree
    # tree would push it over.
    parser.add_argument(
        "--output",
        default="/tmp/vibebar-demo-home",
        help="demo home to write (default: /tmp/vibebar-demo-home)",
    )
    parser.add_argument("--days", type=int, default=45, help="how much history to keep (default: 45)")
    parser.add_argument("--seed", type=int, default=7, help="random seed for the fabricated parts")
    parser.add_argument("--keep", action="store_true", help="do not wipe an existing output directory first")
    args = parser.parse_args(argv)

    source_home = Path(args.source).expanduser().resolve()
    output_home = Path(args.output).expanduser().resolve()
    if output_home == source_home or source_home in output_home.parents and output_home.name == ".vibebar":
        fail("output must not be the source home")
    if not (source_home / ".vibebar").is_dir():
        fail(f"no .vibebar store under {source_home}")
    if output_home.exists() and not args.keep:
        if not (output_home / ".vibebar").is_dir() and any(output_home.iterdir()):
            fail(f"{output_home} exists and does not look like a demo home; refusing to wipe it")
        shutil.rmtree(output_home)
    output_home.mkdir(parents=True, exist_ok=True)
    os.chmod(output_home, 0o700)

    now = dt.datetime.now(dt.timezone.utc).astimezone()
    builder = Builder(source_home, output_home, args.days, now, args.seed)
    builder.build()
    for line in builder.report:
        log(line)
    log(f"demo home ready: {output_home}")
    log(f"  VIBEBAR_DEMO_HOME={output_home}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
