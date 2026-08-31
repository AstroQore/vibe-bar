#!/usr/bin/env python3
"""Regenerate docs/contracts/quota-naming-v1.json from the Swift sources.

The quota axis names — L1 company, L2 SubProvider, L3 group — decide how every
surface in both clients arranges providers, and AGENTS.md § 7.1 makes getting
them identical a behavioural rule rather than a nicety. They live in three
different Swift files here, so this reads all three rather than restating them.

Run after changing ToolType.hierarchy, MiniWindowGroupLabelCatalog, or the
window suffixes in QuotaFieldRegistry. A test fails if the file drifts.
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent


def read(relative: str) -> str:
    return (ROOT / relative).read_text()


def slice_between(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin : text.index(end, begin)]


def hierarchy() -> dict:
    """L1 company and L2 SubProvider for every tool.

    Two hops: ToolType.hierarchy maps a case to a named catalog entry, and the
    catalog holds the strings. `ToolType: String` takes its raw value from the
    case name, so the case name is also the wire key both clients use.
    """
    catalog_source = read("Sources/VibeBarCore/Models/ProviderHierarchy.swift")
    catalog = {
        name: {"company": vendor, "subProvider": product}
        for name, vendor, product, _tool in re.findall(
            r'static let (\w+)\s*=\s*ProviderHierarchy\(vendor: "([^"]*)",\s*'
            r'product: "([^"]*)",\s*tool: "([^"]*)"\)',
            catalog_source,
        )
    }
    if not catalog:
        raise SystemExit("ProviderHierarchyCatalog entries not found")

    table = slice_between(
        read("Sources/VibeBarCore/Models/ToolType.swift"),
        "public var hierarchy: ProviderHierarchy",
        "\n    }",
    )
    out = {}
    for case, entry in re.findall(
        r"case \.(\w+):\s*return ProviderHierarchyCatalog\.(\w+)", table
    ):
        if entry not in catalog:
            raise SystemExit(f"{case} points at unknown catalog entry {entry}")
        out[case] = catalog[entry]
    if not out:
        raise SystemExit("ToolType.hierarchy cases not found")
    return out


def group_labels() -> dict:
    """The short label each L3 group shows, e.g. codex.spark -> "Spark"."""
    source = read("Sources/VibeBarApp/Views/MiniWindowGroupLabelCatalog.swift")
    catalog = slice_between(source, "static let all:", "static func defaultLabel")
    return {
        key: label
        for key, _title, label in re.findall(
            r'\.init\(id: "([^"]+)", title: "([^"]*)", defaultLabel: "([^"]*)"\)', catalog
        )
    }


def group_key_rules() -> dict:
    """How a bucket id becomes an L3 group key, in the order native applies."""
    source = read("Sources/VibeBarApp/Views/MiniWindowGroupLabelCatalog.swift")
    body = slice_between(source, "static func groupKey(", "static func subProviderKey")

    exact = []
    # A case can list several buckets: `case "a", "b": return "key"`. Matching
    # only the single-bucket form silently dropped codex.spark, which is the
    # kind of omission a generator must fail on rather than quietly ship.
    for buckets, tool, key in re.findall(
        r'case ((?:"[^"]+"(?:, )?)+)(?: where tool == \.(\w+))?: return "([^"]+)"', body
    ):
        for bucket in re.findall(r'"([^"]+)"', buckets):
            entry = {"bucket": bucket, "key": key}
            if tool:
                entry["tool"] = tool
            exact.append(entry)

    contains = []
    current_tool = None
    for line in body.splitlines():
        tool_match = re.search(r"if tool == \.(\w+) \{", line)
        if tool_match:
            current_tool = tool_match.group(1)
            continue
        needle_match = re.search(r'if id\.contains\("([^"]+)"\) \{ return "([^"]+)" \}', line)
        if needle_match and current_tool:
            contains.append({
                "tool": current_tool,
                "contains": needle_match.group(1),
                "key": needle_match.group(2),
            })
            continue
        list_match = re.search(
            r'if \[([^\]]+)\]\.contains\(id\) \{', line)
        if list_match and current_tool:
            buckets = re.findall(r'"([^"]+)"', list_match.group(1))
            contains.append({"tool": current_tool, "anyOf": buckets, "key": None})
    # The multi-bucket `anyOf` branches return on the following line.
    keys = re.findall(r'\]\.contains\(id\)\s*\{\s*return\s*"([^"]+)"', body, re.S)
    pending = [rule for rule in contains if rule["key"] is None]
    for rule, key in zip(pending, keys):
        rule["key"] = key

    defaults = dict(
        re.findall(r'case \.(\w+): return "([^"]+)"',
                   slice_between(source, "static func namingGroupKey", "static func groupKey"))
    )

    suffixes = re.findall(
        r'"(_[a-z_]+)"',
        slice_between(read("Sources/VibeBarCore/Models/QuotaFieldRegistry.swift"),
                      "static func bucketGroupStem", "return stem.isEmpty"),
    )
    rules = {
        "exact": exact,
        "contains": contains,
        "defaultGroup": defaults,
        "stemSuffixes": [s for s in suffixes if s != "_window"],
    }
    # Every group key the Swift switch can return must have made it into one of
    # the rule lists. A regex that stops matching is otherwise indistinguishable
    # from a rule that was deleted.
    returned = set(re.findall(r'return "([\w.+-]+)"', body))
    captured = {rule["key"] for rule in exact} | {rule["key"] for rule in contains}
    missing = returned - captured
    if missing:
        raise SystemExit(f"groupKey rules not captured: {sorted(missing)}")
    if any(rule["key"] is None for rule in contains):
        raise SystemExit("a multi-bucket rule did not find its key")
    return rules


def main() -> None:
    tools = hierarchy()
    document = {
        "schema": "quota-naming-v1",
        "note": (
            "The quota axis: L1 company, L2 SubProvider, L3 group. Generated by "
            "Scripts/generate_quota_naming_contract.py from ToolType.swift, "
            "MiniWindowGroupLabelCatalog.swift and QuotaFieldRegistry.swift. "
            "Usage-axis names (harnesses) are a different axis and never mix "
            "with these in one list."
        ),
        "hierarchy": tools,
        "subProviderOverrides": [
            {"tool": "cursor", "bucket": "grok_bot_weekly", "subProvider": "Grok Bot"}
        ],
        "ungrouped": [
            {"tool": "cursor", "bucket": "grok_bot_weekly",
             "why": "sits directly under its SubProvider, with no L3 group"}
        ],
        "groupLabels": group_labels(),
        "groupKey": group_key_rules(),
        "fallback": (
            "A bucket no rule names takes the key '<tool>.<stem>', where the stem "
            "is the bucket id with one stemSuffix removed, and shows the bucket's "
            "own groupTitle as its label."
        ),
    }
    path = ROOT / "docs/contracts/quota-naming-v1.json"
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"{path.name}: {len(tools)} tools, {len(document['groupLabels'])} group labels, "
          f"{len(document['groupKey']['exact'])} exact + {len(document['groupKey']['contains'])} pattern rules")


if __name__ == "__main__":
    main()
