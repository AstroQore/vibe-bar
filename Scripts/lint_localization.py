#!/usr/bin/env python3
"""Fail when a migrated surface grows a new hardcoded user-facing string.

A localization pass that is only enforced by review lasts until the next
PR. This is the enforcement: every file listed in `MIGRATED` has been
through the pass, and from now on a `Text("Refresh")` in one of them is
an error rather than a thing someone notices six months later when the
Chinese build has an English word in the middle of a card.

**This does not match on regexes over a line.** The first version did,
and it reported clean while the screen showed English: a pattern anchored
to "literal immediately after a known initializer" sees `Text("Refresh")`
but not `Label(busy ? "Importing…" : "Import now", …)`, not
`sectionLabel("REAL TOKENS")`, and not an argument that wrapped onto the
next line. A lint that is trusted and wrong is worse than no lint.

So this scans the file properly: a small Swift lexer walks every string
literal, tracking the enclosing call and the argument label it sits
under. A literal is user-facing when the call it belongs to renders text
— a SwiftUI initializer, a text modifier, or one of this codebase's own
label-producing helpers, which are *derived from the source* rather than
listed here so the list cannot go stale — and when its argument label is
not one of the identifier-shaped ones (`systemImage:` is an SF Symbol,
never copy).

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
    Scripts/lint_localization.py --helpers  # print the derived helper set
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
    "Sources/VibeBarApp/Views/Workbench/WorkbenchRootView.swift",
    "Sources/VibeBarApp/Views/Workbench/ResetsPage.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageStatsPage.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageHeroCards.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageCompositionCards.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageFiltersBar.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageTrendChartView.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageDistributionDashboard.swift",
    "Sources/VibeBarApp/Views/Workbench/UsageBreakdownTables.swift",
    "Sources/VibeBarApp/Controllers/UsageStatsViewModel.swift",
    "Sources/VibeBarApp/Views/PopoverRoot.swift",
    "Sources/VibeBarCore/Services/QuotaPaceForecast.swift",
    "Sources/VibeBarCore/Models/CostSnapshot.swift",
    "Sources/VibeBarApp/Views/Onboarding/OnboardingStepViews.swift",
    "Sources/VibeBarApp/Views/LanguageSettingsSection.swift",
    "Sources/VibeBarApp/Views/Workbench/SessionListView.swift",
    "Sources/VibeBarApp/Views/Workbench/SessionManagerPage.swift",
    "Sources/VibeBarApp/Views/Workbench/TranscriptView.swift",
    "Sources/VibeBarApp/Controllers/SessionManagerModel.swift",
    "Sources/VibeBarApp/Controllers/SkillsManagerModel.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillsManagerPage.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillListRow.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillWiringView.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillDiscoverSheet.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillImportSheet.swift",
    "Sources/VibeBarApp/Views/Workbench/SkillBackupsSheet.swift",
    # Settings, its panes, and the model types whose `label` / `title` /
    # `detail` properties they render. An enum carrying a presentation string
    # looks like a model detail and *is* UI: the picker label was localized
    # while its choices stayed English until a reviewer caught it.
    "Sources/VibeBarApp/Views/SettingsSidebarView.swift",
    "Sources/VibeBarApp/Views/MCPSettingsSection.swift",
    "Sources/VibeBarApp/Views/MiniWindowsSettingsSection.swift",
    "Sources/VibeBarApp/Views/PricingSettingsSection.swift",
    "Sources/VibeBarApp/Views/RemoteSettingsSection.swift",
    "Sources/VibeBarApp/Views/MiscProviderSettingsSection.swift",
    "Sources/VibeBarApp/Views/SettingsView.swift",
    "Sources/VibeBarCore/Models/AppSettings.swift",
    "Sources/VibeBarCore/Models/DisplayMode.swift",
    "Sources/VibeBarCore/Models/MenuBarSettings.swift",
    "Sources/VibeBarCore/Models/MiscProviderSettings.swift",
    "Sources/VibeBarCore/Models/PreferredTerminal.swift",
    "Sources/VibeBarCore/Models/PrimaryProviderRouteHealth.swift",
    "Sources/VibeBarCore/Models/PrimaryProviderSourcePlanner.swift",
    "Sources/VibeBarCore/Models/UpdateChannel.swift",
    "Sources/VibeBarApp/Views/HeaderView.swift",
    "Sources/VibeBarApp/Views/QuotaGroupCard.swift",
    "Sources/VibeBarApp/Views/QuotaHistoryChartView.swift",
    "Sources/VibeBarApp/Views/OverviewQuotaHistoryCard.swift",
    "Sources/VibeBarApp/Views/OverviewUsageMixCard.swift",
    "Sources/VibeBarApp/Views/ResetHistoryCompareView.swift",
    "Sources/VibeBarApp/Views/FillTimelineChart.swift",
    "Sources/VibeBarApp/Views/CostHistoryView.swift",
    "Sources/VibeBarApp/Views/ChartBrushNavigator.swift",
    "Sources/VibeBarApp/Views/UsageActivityView.swift",
    "Sources/VibeBarApp/Views/YearlyContributionHeatmapView.swift",
    "Sources/VibeBarApp/Views/MiniQuotaWindowView.swift",
    "Sources/VibeBarCore/Services/UsagePace.swift",
    "Sources/VibeBarCore/Services/SubscriptionWindowProgress.swift",
    "Sources/VibeBarCore/Models/CostChartGranularity.swift",
    "Sources/VibeBarCore/Models/UsageHeatmap+Activity.swift",
    "Sources/VibeBarApp/Views/MiniWindowAltLayouts.swift",
    "Sources/VibeBarApp/Views/MiscProvidersPage.swift",
    "Sources/VibeBarApp/Views/CodexBarProviderBridgeCard.swift",
    "Sources/VibeBarApp/Views/RemoteMachinesPage.swift",
]



class Failure(SystemExit):
    pass


# ---------------------------------------------------------------- lexing

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Literal:
    __slots__ = ("text", "line", "callee", "is_modifier", "receiver", "label")

    def __init__(self, text, line, callee, is_modifier, receiver, label):
        self.text = text
        self.line = line
        self.callee = callee
        self.is_modifier = is_modifier
        self.receiver = receiver
        self.label = label


def scan(source: str):
    """Every string literal in `source`, with the call context around it.

    Handles line and (nested) block comments, triple-quoted multi-line strings,
    `#"…"#` raw strings, escapes, and `\\(…)` interpolation — an
    interpolated literal is consumed whole rather than recursed into, so
    `"\\(n) left"` is reported as one literal and still flagged.
    """
    literals = []
    # One frame per open `(`; a frame records what is being called and the
    # argument label the cursor currently sits under.
    frames = [{"callee": None, "modifier": False, "receiver": None,
               "label": None, "expect": False}]
    index = 0
    line = 1
    length = len(source)
    block_depth = 0

    while index < length:
        char = source[index]

        if char == "\n":
            line += 1
            index += 1
            continue

        if block_depth:
            if source.startswith("*/", index):
                block_depth -= 1
                index += 2
            elif source.startswith("/*", index):
                block_depth += 1
                index += 2
            else:
                index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            index = length if end == -1 else end
            continue

        if source.startswith("/*", index):
            block_depth = 1
            index += 2
            continue

        # Raw strings: #"…"#, ##"…"##
        if char == "#":
            hashes = 0
            probe = index
            while probe < length and source[probe] == "#":
                hashes += 1
                probe += 1
            if probe < length and source[probe] == '"':
                start_line = line
                terminator = '"' + "#" * hashes
                if source.startswith('"""', probe):
                    terminator = '"""' + "#" * hashes
                    probe += 3
                else:
                    probe += 1
                end = source.find(terminator, probe)
                end = length if end == -1 else end
                body = source[probe:end]
                line += body.count("\n")
                literals.append(_literal(body, start_line, frames))
                index = end + len(terminator)
                continue

        if source.startswith('"""', index):
            start_line = line
            end = source.find('"""', index + 3)
            end = length if end == -1 else end
            body = source[index + 3:end]
            line += body.count("\n")
            literals.append(_literal(body, start_line, frames))
            index = end + 3
            continue

        if char == '"':
            start_line = line
            index += 1
            body = []
            depth = 0  # interpolation nesting
            while index < length:
                current = source[index]
                if current == "\\" and index + 1 < length:
                    if source[index + 1] == "(":
                        depth += 1
                        body.append("\\(")
                        index += 2
                        continue
                    body.append(source[index:index + 2])
                    index += 2
                    continue
                if depth:
                    if current == "(":
                        depth += 1
                    elif current == ")":
                        depth -= 1
                    elif current == "\n":
                        line += 1
                    body.append(current)
                    index += 1
                    continue
                if current == '"':
                    index += 1
                    break
                if current == "\n":
                    line += 1
                body.append(current)
                index += 1
            literals.append(_literal("".join(body), start_line, frames))
            continue

        if char == "(":
            callee, modifier, receiver = _callee_before(source, index)
            frames.append(
                {"callee": callee, "modifier": modifier, "receiver": receiver,
                 "label": None, "expect": True}
            )
            index += 1
            continue

        if char == ")":
            if len(frames) > 1:
                frames.pop()
            index += 1
            continue

        if char in "[{":
            frames.append(
                {"callee": None, "modifier": False, "receiver": None,
                 "label": None, "expect": False}
            )
            index += 1
            continue

        if char in "]}":
            if len(frames) > 1:
                frames.pop()
            index += 1
            continue

        if char == ",":
            frames[-1]["label"] = None
            frames[-1]["expect"] = True
            index += 1
            continue

        match = IDENTIFIER.match(source, index)
        if match:
            if frames[-1]["expect"]:
                after = match.end()
                while after < length and source[after] in " \t":
                    after += 1
                if after < length and source[after] == ":" and not source.startswith("::", after):
                    frames[-1]["label"] = match.group(0)
                frames[-1]["expect"] = False
            index = match.end()
            continue

        if char not in " \t":
            frames[-1]["expect"] = False
        index += 1

    return literals


def _literal(text, line, frames):
    frame = frames[-1]
    return Literal(
        text, line, frame["callee"], frame["modifier"], frame["receiver"],
        frame["label"],
    )


def _callee_before(source, paren_index):
    """`(name, followed_a_dot, receiver)` for the call opening at `(`."""
    probe = paren_index - 1
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    end = probe + 1
    while probe >= 0 and (source[probe].isalnum() or source[probe] == "_"):
        probe -= 1
    name = source[probe + 1:end]
    if not name or not (name[0].isalpha() or name[0] == "_"):
        return None, False, None
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    if probe < 0 or source[probe] != ".":
        return name, False, None
    probe -= 1
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    end = probe + 1
    while probe >= 0 and (source[probe].isalnum() or source[probe] == "_"):
        probe -= 1
    return name, True, source[probe + 1:end] or None


# ------------------------------------------------------------- the rules

# SwiftUI initializers whose leading arguments are text the user reads.
UI_CALLS = {
    "Text", "Button", "Toggle", "Picker", "Label", "TextField", "SecureField",
    "TextEditor", "Section", "Stepper", "Link", "Menu", "GroupBox",
    "DisclosureGroup", "NavigationLink", "Slider", "ProgressView", "Tab",
    "Alert", "Toast",
}

# Text-bearing modifiers. `.tag` is deliberately absent: it carries a
# selection identity, not copy.
UI_MODIFIERS = {
    "help", "navigationTitle", "navigationSubtitle", "alert",
    "confirmationDialog", "accessibilityLabel", "accessibilityValue",
    "accessibilityHint", "searchable", "badge",
}

# Argument labels this codebase passes copy through, whatever the callee.
COPY_ARGUMENTS = {
    "title", "subtitle", "message", "help", "caption", "placeholder",
    "titleOverride", "emptyMessage", "emptyMessageOverride", "label",
    "heatmapTitleOverride", "prompt", "detail", "headline", "verdict",
    "detected", "web", "missing", "text", "value", "summary", "footer",
    "toolName",
}

# Argument labels that are never copy, even inside a text-rendering call.
# `systemImage:` is an SF Symbol name; `tag:`/`id:` are identities.
IDENTIFIER_ARGUMENTS = {
    "systemImage", "image", "icon", "id", "tag", "key", "forKey", "table",
    "bundle", "forResource", "withExtension", "named", "identifier",
    "separator", "format", "comment", "scheme", "host", "path", "rawValue",
    "toolNameOverride", "forGroupName", "bucketId", "accountId",
}

# Return types that mark a helper as producing something the user reads.
VIEW_RETURNS = re.compile(r"->\s*(some\s+View|Text|AnyView|String|LocalizedStringKey)\b")


def _resolve(relative) -> pathlib.Path:
    path = pathlib.Path(relative)
    return path if path.is_absolute() else ROOT / path


def derived_helpers(files) -> set:
    """This codebase's own label-producing helpers, read out of the source.

    `sectionLabel("REAL TOKENS · SELECTED RANGE")` is as much a visible
    string as `Text(...)`, and there are enough of these — `detailText`,
    `hintLabel`, `metric`, `summaryRow`, `messageRow` — that a hand-kept
    list would be stale within a release. Any function that takes a
    `String` and returns a view or a string is treated as one.
    """
    helpers = set()
    for relative in files:
        path = _resolve(relative)
        if not path.exists():
            continue
        source = path.read_text()
        for match in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", source):
            depth, index = 1, match.end()
            while index < len(source) and depth:
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                index += 1
            parameters = source[match.end():index - 1]
            tail = source[index:index + 80]
            if "String" in parameters and VIEW_RETURNS.search(tail):
                helpers.add(match.group(1))
    # A function *named* for an identifier builds identity, not copy, however
    # much its signature looks like a label helper's. `OverviewQuotaCurve.id`
    # takes three strings and returns one, so inferring from the shape alone
    # made every `id("blank-\(n)")` in the manifest a finding. These are the
    # same names `IDENTIFIER_ARGUMENTS` already trusts as an argument label.
    return helpers - IDENTIFIER_ARGUMENTS


LETTER = re.compile(r"[A-Za-z一-鿿]")

# Per-file exceptions: a literal that reads like copy but is not, keyed by
# the reason it is exempt. Kept short on purpose — most cases are better
# answered by the glossary (a name) or by `IDENTIFIER_ARGUMENTS` (an
# argument that never carries copy), and an exception that names one file is
# the thing that quietly grows into a second, unreviewed allowlist.
ALLOWED: dict = {
    "a format mask shown as a field placeholder: it is the shape of the "
    "value the user types, and every language types the same shape": {
        "Views/RemoteSettingsSection.swift": {"VB-XXXXX-XXXXX"},
    },
}


def glossary_terms() -> set:
    document = json.loads(GLOSSARY.read_text())
    terms = set()
    for field, value in document.items():
        if field in {"schema", "note", "rules"} or not isinstance(value, list):
            continue
        terms.update(value)
    return terms


URL = re.compile(r"^[a-z][a-z0-9+.-]*://\S*$|^~?/[\w./~-]*$")


def is_allowed(text: str, terms: set, path: str) -> bool:
    stripped = text.strip()
    if not stripped or not LETTER.search(stripped):
        return True
    # A URL or a bare filesystem path is an address, not a sentence. No
    # language spells `https://` differently.
    if URL.match(stripped):
        return True
    if stripped in terms:
        return True
    # A glossary term with punctuation or a separator around it — "Claude ·",
    # "AntiGravity:" — is still the term, not a sentence about it.
    if stripped.strip(" ·:—-…()[]") in terms:
        return True
    for _reason, files in ALLOWED.items():
        for suffix, literals in files.items():
            if str(path).endswith(suffix) and stripped in literals:
                return True
    return False


# Receivers whose string arguments are identifiers, not copy. `L10n` is the
# obvious one: its argument *is* a catalog key.
IDENTIFIER_RECEIVERS = {"L10n", "Bundle", "UserDefaults", "NSLocalizedString"}


# Display formatting that asks the *process* locale instead of the app's.
# `Locale.current` is the system's language, and `AppSettings.language` is
# not; a date formatted against it drops "May 9, 2026" into the middle of a
# Chinese sentence. Everything the user reads goes through `AppLocale`.
FORMATTING = [
    (re.compile(r"\bDateFormatter\(\)"), "DateFormatter() — use AppLocale.dateFormatter"),
    (re.compile(r"\bRelativeDateTimeFormatter\(\)"),
     "RelativeDateTimeFormatter() — use AppLocale.relativeDateTimeFormatter"),
    (re.compile(r"\.formatted\(date:"), ".formatted(date:time:) — use AppLocale.string"),
    (re.compile(r"\bLocale\.current\b"), "Locale.current — the system's language, not the app's"),
]


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


def formatting_findings(relative, source: str):
    """Display formatting that bypasses `AppLocale`, outside comments."""
    found = []
    stripped = []
    block = False
    for line in source.splitlines():
        if block:
            if "*/" in line:
                line, block = line.split("*/", 1)[1], False
            else:
                stripped.append("")
                continue
        if "/*" in line:
            head, _, tail = line.partition("/*")
            if "*/" in tail:
                line = head + tail.split("*/", 1)[1]
            else:
                line, block = head, True
        line = strip_comments(line)
        stripped.append("" if line.lstrip().startswith("///") else line)
    for number, line in enumerate(stripped, start=1):
        for pattern, reason in FORMATTING:
            if pattern.search(line):
                found.append((number, reason))

    # A number / percent / currency style needs `.locale(AppLocale.current)`
    # somewhere in its own argument list. That span has to be found by
    # walking the parentheses — a regex cannot balance them, and the first
    # attempt reported a call that was already correct, which is exactly the
    # kind of false positive that gets a lint switched off.
    joined = "\n".join(stripped)
    for match in re.finditer(r"\.formatted\(\s*\.(?:number|percent|currency)", joined):
        start = joined.index("(", match.start() + len(".formatted") - 1)
        depth, index = 0, start
        while index < len(joined):
            if joined[index] == "(":
                depth += 1
            elif joined[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        if ".locale(" not in joined[start:index]:
            found.append((
                joined.count("\n", 0, match.start()) + 1,
                "a number/percent/currency style without .locale(AppLocale.current)",
            ))
    return found


def findings_for(relative, helpers: set, terms: set):
    path = _resolve(relative)
    source = path.read_text()
    # A generated file is never hand-migrated, and its key literals would
    # otherwise read as copy passed to a one-argument String helper.
    if "Generated by Scripts/" in source[:400]:
        return []
    found = []
    for literal in scan(source):
        if literal.receiver in IDENTIFIER_RECEIVERS:
            continue
        callee = literal.callee
        renders = (
            (callee in UI_CALLS and not literal.is_modifier)
            or (callee in UI_MODIFIERS and literal.is_modifier)
            or (callee in helpers)
        )
        if literal.label in COPY_ARGUMENTS:
            renders = True
        if literal.label in IDENTIFIER_ARGUMENTS:
            renders = False
        if not renders:
            continue
        if is_allowed(literal.text, terms, relative):
            continue
        where = f"{callee or '?'}(" + (f"{literal.label}:" if literal.label else "") + "…)"
        found.append((literal.line, literal.text, where))
    for line, reason in formatting_findings(relative, source):
        found.append((line, reason, "display formatting"))
    return found


def main() -> int:
    if "--list" in sys.argv[1:] and "--scan" not in sys.argv[1:]:
        print("\n".join(MIGRATED))
        return 0

    arguments = sys.argv[1:]
    if "--scan" in arguments:
        # Point the scanner at one arbitrary file and print what it finds,
        # one `line<TAB>literal` per row. `LocalizationLintTests` uses this
        # to check the scanner against a fixture of the shapes that used to
        # slip past it — a lint nothing tests is a lint that is trusted for
        # the wrong reasons.
        target = pathlib.Path(arguments[arguments.index("--scan") + 1])
        helpers = derived_helpers(MIGRATED) | derived_helpers([target])
        for line, text, _where in findings_for(target, helpers, glossary_terms()):
            print(f"{line}\t{text}")
        return 0

    helpers = derived_helpers(MIGRATED)
    if "--helpers" in arguments:
        print("\n".join(sorted(helpers)))
        return 0

    terms = glossary_terms()
    findings = []
    for relative in MIGRATED:
        if not (ROOT / relative).exists():
            findings.append((relative, 0, "listed as migrated but does not exist", ""))
            continue
        for line, text, where in findings_for(relative, helpers, terms):
            findings.append((relative, line, f'"{text}"', where))

    if findings:
        print(
            "lint_localization: user-facing literals that do not go through "
            "L10n\n",
            file=sys.stderr,
        )
        for relative, line, detail, where in findings:
            print(f"  {relative}:{line}: {detail}  in {where}", file=sys.stderr)
        print(
            f"\n{len(findings)} finding(s). Either route the string through "
            f"L10n (add the key to Resources/i18n/en.json and zh-Hans.json, "
            f"then run Scripts/build_localizations.py), or — if it is a "
            f"company, product, model or harness name — add it to "
            f"Resources/i18n/_glossary.json.",
            file=sys.stderr,
        )
        return 1
    print(
        f"lint_localization: {len(MIGRATED)} migrated file(s) clean "
        f"({len(helpers)} label-producing helpers derived from the source)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
