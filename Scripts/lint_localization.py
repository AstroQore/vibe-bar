#!/usr/bin/env python3
"""Fail when a migrated surface grows a new hardcoded user-facing string.

A localization pass that is only enforced by review lasts until the next
PR. This is the enforcement: every file listed in `MIGRATED` below has
been through the pass, and from now on a `Text("Refresh")` in one of them
is an error rather than a thing someone notices six months later when the
Chinese build has an English word in the middle of a card.

What is checked: string literals in the *label* position of the SwiftUI
initializers and modifiers a user actually reads — `Text`, `Button`,
`Toggle`, `Picker`, `Label`, `TextField`, `Section`, `.help`,
`.navigationTitle`, `.alert`, `.confirmationDialog`,
`.accessibilityLabel` — plus the label-shaped argument names this
codebase passes copy through (`title:`, `subtitle:`, `message:`,
`help:`, `caption:`, `placeholder:`).

What is allowed, and why each is not a loophole:

  * A term in `Resources/i18n/_glossary.json`. Company, SubProvider,
    product, model and harness names are identifiers, not copy —
    `AGENTS.md` § 7.1 — and translating one makes two surfaces disagree
    about what a thing is called. The list is data so the app, the
    cross-platform client, the lint and a translator all read one file.
  * A literal with no letters at all: "·", "—", "%", "$".
  * A per-file exception in `ALLOWED`, each of which carries its reason.

Run:
    Scripts/lint_localization.py            # report and exit non-zero
    Scripts/lint_localization.py --list     # print the migrated manifest
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GLOSSARY = ROOT / "Resources/i18n/_glossary.json"

# Files that have been through the localization pass. Adding a file here
# is a promise that every user-facing string in it goes through `L10n`;
# `LocalizationLintTests` runs this over exactly this list on every
# `swift test`.
MIGRATED = [
    "Sources/VibeBarCore/Models/QuotaError.swift",
    "Sources/VibeBarCore/Models/ResetHistoryComparison.swift",
    "Sources/VibeBarCore/Utilities/ResetCountdownFormatter.swift",
    "Sources/VibeBarCore/Utilities/QuotaFreshnessLabel.swift",
    "Sources/VibeBarApp/Views/EmptyStateView.swift",
    "Sources/VibeBarApp/Views/CostSummaryRow.swift",
    "Sources/VibeBarApp/Views/QuotaBucketView.swift",
    "Sources/VibeBarApp/Views/QuotaForecastRow.swift",
    "Sources/VibeBarApp/Views/UpcomingResets.swift",
    "Sources/VibeBarApp/Views/UsagePaceRow.swift",
    "Sources/VibeBarApp/Views/ServiceStatusCard.swift",
    "Sources/VibeBarApp/Views/SectionRefreshButton.swift",
    "Sources/VibeBarApp/Views/ModelRankingList.swift",
    "Sources/VibeBarApp/Views/TopModelTile.swift",
    "Sources/VibeBarApp/Views/Onboarding/OnboardingView.swift",
    "Sources/VibeBarApp/Views/Workbench/WorkbenchPlaceholderPage.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageStatsPage.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageHeroCards.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageCompositionCards.swift",
    "Sources/VibeBarApp/Views/PopoverRoot.swift",
    "Sources/VibeBarCore/Services/QuotaPaceForecast.swift",
    "Sources/VibeBarCore/Models/CostSnapshot.swift",
    "Sources/VibeBarApp/Views/Onboarding/OnboardingStepViews.swift",
    "Sources/VibeBarApp/Views/LanguageSettingsSection.swift",
]

# Per-file exceptions. Each is a literal that reads like copy but is not.
ALLOWED = {
    # Reason -> {file suffix: {literals}}
}

# Label-position initializers and modifiers.
CALLS = [
    "Text", "Button", "Toggle", "Picker", "Label", "TextField", "Section",
    "Stepper", "Link", "Menu", "TextEditor", "SecureField", "GroupBox",
    "DisclosureGroup", "Tab", "TabView", "Slider",
]
MODIFIERS = [
    "help", "navigationTitle", "alert", "confirmationDialog",
    "accessibilityLabel", "accessibilityValue", "accessibilityHint", "tag",
    "searchable",
]
# Argument labels this codebase passes copy through.
ARGUMENTS = [
    "title", "subtitle", "message", "help", "caption", "placeholder",
    "titleOverride", "emptyMessage", "emptyMessageOverride", "label",
    "heatmapTitleOverride", "prompt", "detail", "headline", "verdict",
]

STRING = r'"((?:[^"\\\n]|\\.)*)"'
PATTERNS = (
    [re.compile(rf'\b{name}\(\s*(?:verbatim:\s*)?{STRING}') for name in CALLS]
    + [re.compile(rf'\.{name}\(\s*(?:verbatim:\s*)?{STRING}') for name in MODIFIERS]
    + [re.compile(rf'\b{name}:\s*{STRING}') for name in ARGUMENTS]
)

LETTER = re.compile(r"[A-Za-z一-鿿]")


def strip_comments(line: str) -> str:
    """Blank out a trailing `//` comment without touching one inside a string."""
    in_string = False
    index = 0
    while index < len(line):
        character = line[index]
        if character == "\\" and in_string:
            index += 2
            continue
        if character == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def glossary_terms() -> set:
    document = json.loads(GLOSSARY.read_text())
    terms = set()
    for field, value in document.items():
        if field in {"schema", "note", "rules"} or not isinstance(value, list):
            continue
        terms.update(value)
    return terms


def is_allowed(text: str, terms: set, path: str) -> bool:
    stripped = text.strip()
    if not stripped or not LETTER.search(stripped):
        return True
    if stripped in terms:
        return True
    # A glossary term with punctuation or a separator around it — "Claude ·",
    # "AntiGravity:" — is still the term, not a sentence about it.
    bare = stripped.strip(" ·:—-…()[]")
    if bare in terms:
        return True
    for reason, files in ALLOWED.items():
        for suffix, literals in files.items():
            if path.endswith(suffix) and stripped in literals:
                return True
    return False


def main() -> int:
    if "--list" in sys.argv[1:]:
        print("\n".join(MIGRATED))
        return 0

    terms = glossary_terms()
    findings = []
    for relative in MIGRATED:
        path = ROOT / relative
        if not path.exists():
            findings.append((relative, 0, f"listed as migrated but does not exist"))
            continue
        in_block_comment = False
        for number, raw in enumerate(path.read_text().splitlines(), start=1):
            line = raw
            if in_block_comment:
                if "*/" in line:
                    line = line.split("*/", 1)[1]
                    in_block_comment = False
                else:
                    continue
            if "/*" in line:
                head, _, tail = line.partition("/*")
                if "*/" in tail:
                    line = head + tail.split("*/", 1)[1]
                else:
                    line, in_block_comment = head, True
            line = strip_comments(line)
            if not line.strip() or line.lstrip().startswith("///"):
                continue
            for pattern in PATTERNS:
                for match in pattern.finditer(line):
                    text = match.group(1)
                    if not is_allowed(text, terms, relative):
                        findings.append((relative, number, f'"{text}"'))

    if findings:
        print(
            "lint_localization: user-facing literals that do not go through "
            "L10n\n",
            file=sys.stderr,
        )
        for relative, number, detail in findings:
            print(f"  {relative}:{number}: {detail}", file=sys.stderr)
        print(
            f"\n{len(findings)} finding(s). Either route the string through "
            f"L10n (add the key to Resources/i18n/en.json and zh-Hans.json, "
            f"then run Scripts/build_localizations.py), or — if it is a "
            f"company, product, model or harness name — add it to "
            f"Resources/i18n/_glossary.json.",
            file=sys.stderr,
        )
        return 1
    print(f"lint_localization: {len(MIGRATED)} migrated file(s) clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
