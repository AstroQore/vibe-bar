#!/usr/bin/env python3
"""Repair a macOS 26 Control Center menu-bar allow-list that hides an app.

Background
----------
Control Center keeps a per-bundle-id allow-list in

    ~/Library/Group Containers/group.com.apple.controlcenter
        /Library/Preferences/group.com.apple.controlcenter.plist

under the key ``trackedApplications`` (itself an embedded binary plist). Each
entry carries a ``bundle``, an ``isAllowed`` flag, and a ``menuItemLocations``
list. When an app the user hid keeps a stale reference to *another* app's
bundle id in its ``menuItemLocations``, Control Center resolves the victim
through that mapping and applies the hidden app's ``isAllowed = False`` to it.

The victim's icon then never reaches the menu bar even though its own entry
says ``isAllowed = True``. System Settings shows its Menu Bar toggle as on,
flipping that toggle changes nothing, and neither does reinstalling or
rebooting — the state lives in this file.

This script removes only those orphaned references. It never changes any
``isAllowed`` flag, so every app keeps the show/hide state the user chose.

Usage
-----
    python3 fix_menu_bar_allowlist.py                 # dry run
    python3 fix_menu_bar_allowlist.py --apply         # fix + restart services
    python3 fix_menu_bar_allowlist.py --bundle-id X   # target another app

Requires Full Disk Access for the terminal running it, because the group
container is TCC-protected.
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import time

DEFAULT_BUNDLE_ID = "com.astroqore.VibeBar"
PLIST = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.controlcenter"
    "/Library/Preferences/group.com.apple.controlcenter.plist"
)


def decode(value):
    """trackedApplications and its members may be embedded binary plists."""
    if isinstance(value, bytes):
        try:
            return plistlib.loads(value)
        except Exception:
            return value
    return value


def bundle_id(obj):
    """Pull a bundle id out of {'bundle': {'_0': 'com.example.app'}} shapes."""
    obj = decode(obj)
    if not isinstance(obj, dict):
        return None
    bundle = obj.get("bundle")
    if isinstance(bundle, dict):
        for value in bundle.values():
            if isinstance(value, str):
                return value
    return bundle if isinstance(bundle, str) else None


def restart_services():
    """Control Center caches the allow-list; it must be reloaded to take."""
    for command in (["killall", "cfprefsd"], ["killall", "ControlCenter"]):
        subprocess.run(command, capture_output=True, check=False)
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--apply", action="store_true", help="write the change")
    parser.add_argument(
        "--no-restart",
        action="store_true",
        help="skip restarting cfprefsd/ControlCenter after applying",
    )
    args = parser.parse_args()
    target = args.bundle_id

    if not os.path.exists(PLIST):
        print(f"not found: {PLIST}")
        print("Nothing to repair — this macOS version may not use an allow-list.")
        return 1

    try:
        with open(PLIST, "rb") as handle:
            root = plistlib.load(handle)
    except PermissionError:
        print("Permission denied reading Control Center's preferences.")
        print("Grant Full Disk Access to this terminal, then run this again:")
        print("  System Settings > Privacy & Security > Full Disk Access")
        return 2

    raw = root.get("trackedApplications")
    if raw is None:
        print("no trackedApplications key — nothing to repair")
        return 1
    embedded = isinstance(raw, bytes)
    tracked = plistlib.loads(raw) if embedded else raw

    changes = []
    for index, entry in enumerate(tracked):
        if not isinstance(entry, dict) or "menuItemLocations" not in entry:
            continue
        owner = bundle_id(entry) or bundle_id(entry.get("location") or {})
        if owner == target:
            continue  # the target's own record is not the problem
        locations = entry.get("menuItemLocations") or []
        kept = [loc for loc in locations if bundle_id(loc) != target]
        if len(kept) != len(locations):
            changes.append((index, owner, entry.get("isAllowed")))
            if args.apply:
                entry["menuItemLocations"] = kept

    if not changes:
        print(f"No orphaned references to {target} — allow-list is clean.")
        print("If the icon is still missing, the cause is something else.")
        return 0

    print(f"Orphaned references to {target} found in:")
    for index, owner, allowed in changes:
        print(f"  [{index}] {owner} (isAllowed={allowed}, left unchanged)")

    if not args.apply:
        print("\nDry run — nothing written. Re-run with --apply to fix.")
        return 0

    backup = f"{PLIST}.vibebar-backup-{int(time.time())}"
    shutil.copy2(PLIST, backup)
    print(f"\nBackup: {backup}")

    if embedded:
        root["trackedApplications"] = plistlib.dumps(tracked, fmt=plistlib.FMT_BINARY)
    with open(PLIST, "wb") as handle:
        plistlib.dump(root, handle, fmt=plistlib.FMT_BINARY)
    print(f"Updated: {PLIST}")

    if not args.no_restart:
        print("Restarting cfprefsd and ControlCenter…")
        restart_services()
    print("Done. Quit and reopen the app to re-register its menu bar item.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
