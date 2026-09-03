#!/usr/bin/env python3
"""Compile Resources/i18n/*.json into everything the app actually reads.

    Resources/i18n/en.json          ← the source of truth, hand-edited
    Resources/i18n/zh-Hans.json
    Resources/i18n/_glossary.json   ← the never-translate list
    Resources/i18n/_schema.json     ← what an entry may contain
              │
              ▼  this script
    Sources/VibeBarCore/Resources/<lang>.lproj/Localizable.strings
    Sources/VibeBarCore/Resources/<lang>.lproj/Localizable.stringsdict
    Sources/VibeBarCore/Localization/L10n+Generated.swift

Three deliberate properties, each of which has a reason:

**The catalog directory is portable.** It holds named placeholders
(`{provider}`, `{days}`) and ICU plurals, no `%@` and no `%1$lld`. It is
going to be lifted into a repository shared with the cross-platform
client, where a TypeScript consumer has to render the same sentences —
and `%@` is not a thing it can render. Positional order is also exactly
what a second language reorders, so nothing outside this script ever
sees a position.

**Nothing but this script reads the JSON.** Not the app, not the build.
The app reads `.strings` / `.stringsdict` through `L10n`, and the
generated outputs are checked in, so a fresh machine builds Vibe Bar with
no Python involved. That is what lets the catalog become an external
dependency later without touching one call site.

**A key that takes arguments is not reachable as a string.**
`L10n.string(_:)` is internal to VibeBarCore; the App target only ever
sees the generated `L10n.Quota.resetsIn(duration:)`-shaped API, which
takes named arguments in the language's own order and cannot be handed
to `String(format:)` by mistake.

Usage:
    Scripts/build_localizations.py [--check]

--check writes nothing and exits non-zero when the tree is stale.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / "Resources/i18n"
RESOURCE_DIR = ROOT / "Sources/VibeBarCore/Resources"
SWIFT_PATH = ROOT / "Sources/VibeBarCore/Localization/L10n+Generated.swift"

# The authoring language. Its key set, its argument names, and its plural
# categories are the contract every other catalog is checked against.
BASE = "en"

# Kept in step with `L10n.supported`; LocalizationCatalogTests asserts the
# two agree rather than leaving it to this comment.
LANGUAGES = ["en", "zh-Hans"]

# Surface scopes. A key names where the string is read, so a reviewer can
# tell from the key alone which surface a change can reach. `platform.*`
# is the escape hatch for a string only one client can ever show — a
# React client renders no menu-bar extra and asks for no Automation
# permission — and everything outside it must be renderable by both.
SCOPES = {
    "common": "Common",        # reused everywhere: Refresh, Cancel, units
    "popover": "Popover",      # the menu-bar popover shell, tabs, cards
    "quota": "Quota",          # quota bars, buckets, forecast, reset history
    "cost": "Cost",            # cost cards, history, model ranking
    "status": "Status",        # provider service status
    "usage": "Usage",          # usage / activity / heatmap surfaces
    "workbench": "Workbench",  # the Workbench window and its pages
    "onboarding": "Onboarding",  # the first-run setup assistant
    "settings": "Settings",    # Settings surfaces
    "error": "Errors",         # user-facing failure copy, incl. QuotaError
    "platform": "Platform",    # macOS-only copy: platform.macos.*
}

KEY_PATTERN = re.compile(r"^[a-z][a-z0-9]*(?:\.[A-Za-z0-9_]+)+$")
NAME_PATTERN = re.compile(r"^[a-z][A-Za-z0-9]*$")

# `{name}` — a simple substitution. Braces are only ever placeholders, so
# a literal brace in copy is not supported (nothing needs one, and the
# alternative is an escaping rule two clients would have to agree on).
PLACEHOLDER = re.compile(r"\{\s*([A-Za-z][A-Za-z0-9]*)\s*\}")

# A `%` that looks like a printf specifier. A bare `%` is ordinary copy —
# "80% used", "{percent}% share" — and is allowed; what is rejected is a
# specifier that leaked in from a `.strings` file, because the catalog's
# whole point is that it carries no positional order. The space flag is
# deliberately not in the flag class: "% share" is copy, not a specifier.
PRINTF = re.compile(r"%(?:\d+\$)?[-+0#]*\d*(?:\.\d+)?[@dsfiul]")

# `{count, plural, one {…} other {…}}` — ICU, with `#` for the number.
PLURAL = re.compile(
    r"\{\s*([A-Za-z][A-Za-z0-9]*)\s*,\s*plural\s*,\s*(.+?)\}\s*(?=[^}]*$)", re.S
)
PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"]

# Argument types. `double` is deliberately absent: how a number reads is a
# locale decision that belongs in one formatter, not in a catalog repeated
# per language, so a decimal is formatted at the call site and arrives
# here as a string. The value type is what Foundation's `.stringsdict`
# calls it and what `String(format:)` consumes.
#
# `int` is rendered with the locale's grouping separator — 1,234 rather
# than 1234 — which is right for a count and wrong for a number that is an
# identifier. A year, a version, an id is a `string`, formatted at the call
# site. (A year rendered as "2,027" is how this rule was learned.)
ARG_TYPES = {
    "string": {"swift": "String", "spec": "@", "value_type": "@"},
    "int": {"swift": "Int", "spec": "lld", "value_type": "lld"},
}

# Register rules, per language. Vibe Bar's Chinese is written and terse —
# the register of a spec, not of a chat message — and a catalog is exactly
# the place that slips: one contributor writes `用不完` for "Surplus"
# because it is what you would say out loud, and the app now has two
# voices. These are the spoken- and internet-register words that have
# actually turned up, plus the sentence-final mood particles and
# exclamation marks that mark speech rather than writing.
#
# Substrings are only listed when they cannot appear inside a legitimate
# written compound: `超` is absent because `超出` and `超过` are correct,
# and `了` is absent because it is a perfectly good aspect marker — only
# its sentence-final mood use is caught, by anchoring to the punctuation.
REGISTER = {
    "zh-Hans": {
        "spoken or internet register": [
            "用不完", "差不多", "搞定", "一会儿", "一下子", "大概率",
            "不够用", "没用掉", "刷新不了", "试试", "咋", "干脆", "省得",
            "别忘", "挺好", "超级", "东西", "一堆",
        ],
        "sentence-final mood particle": ["啦", "呀", "嘛", "吧。", "吧！", "呢。", "呢？"],
        "exclamation": ["！"],
        "formal-polite address": ["请您", "您"],
    }
}


def check_register(language: str, entries: dict) -> None:
    rules = REGISTER.get(language)
    if not rules:
        return
    for key, entry in sorted(entries.items()):
        for reason, words in rules.items():
            for word in words:
                if word in entry["value"]:
                    raise Failure(
                        f"{language}.json: {key} contains {word!r} — {reason}. "
                        f"Vibe Bar's Chinese is written and terse: prefer the "
                        f"precise term over the familiar one (盈余 not 用不完, "
                        f"已用尽 not 没了, 约 not 差不多, 未配置 not 还没设置). "
                        f"Value: {entry['value']}"
                    )


SWIFT_KEYWORDS = {
    "as", "associatedtype", "break", "case", "catch", "class", "continue",
    "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
    "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
    "inout", "internal", "is", "let", "nil", "operator", "private", "protocol",
    "public", "repeat", "rethrows", "return", "self", "static", "struct",
    "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
    "var", "where", "while",
}


class Failure(SystemExit):
    def __init__(self, message: str):
        super().__init__(f"build_localizations: {message}")


# ---------------------------------------------------------------- parsing


def parse_plural(key: str, value: str):
    """Split a value into (prefix, plural spec, suffix), or None."""
    start = value.find("{")
    while start != -1:
        head = value[start:]
        match = re.match(
            r"\{\s*([A-Za-z][A-Za-z0-9]*)\s*,\s*plural\s*,", head
        )
        if match:
            break
        start = value.find("{", start + 1)
    if start == -1:
        return None

    name = match.group(1)
    # Hand-balance the braces: the branches contain braces of their own, so
    # a regex cannot find the end of the block.
    depth, index = 0, start
    while index < len(value):
        if value[index] == "{":
            depth += 1
        elif value[index] == "}":
            depth -= 1
            if depth == 0:
                break
        index += 1
    if depth != 0:
        raise Failure(f"{key}: unbalanced braces in a plural block")

    body = value[start + match.end() - match.start(): index]
    branches = {}
    cursor = 0
    while cursor < len(body):
        branch = re.compile(r"\s*([a-z]+|=\d+)\s*\{").match(body, cursor)
        if branch is None:
            if body[cursor:].strip():
                raise Failure(f"{key}: cannot parse plural branch near {body[cursor:][:24]!r}")
            break
        category = branch.group(1)
        depth, end = 1, branch.end()
        while end < len(body) and depth:
            if body[end] == "{":
                depth += 1
            elif body[end] == "}":
                depth -= 1
            end += 1
        if depth:
            raise Failure(f"{key}: unbalanced braces in plural branch '{category}'")
        branches[category] = body[branch.end(): end - 1]
        cursor = end
    if "other" not in branches:
        raise Failure(f"{key}: a plural needs an 'other' branch")
    for category in branches:
        if category not in PLURAL_CATEGORIES:
            raise Failure(
                f"{key}: '{category}' is not a CLDR plural category "
                f"({', '.join(PLURAL_CATEGORIES)})"
            )
    if len(value[index + 1:].split("{")) > 1 and PLURAL.search(value[index + 1:] or ""):
        raise Failure(f"{key}: only one plural block per value")
    return value[:start], (name, branches), value[index + 1:]


def placeholders(text: str) -> list:
    """Placeholder names in order of first appearance."""
    seen = []
    for name in PLACEHOLDER.findall(text):
        if name not in seen:
            seen.append(name)
    return seen


def entry_arguments(key: str, value: str, declared: dict) -> list:
    """(name, type) in the order the English value introduces them."""
    plural = parse_plural(key, value)
    names = []
    if plural:
        prefix, (counter, branches), suffix = plural
        names += [n for n in placeholders(prefix) if n not in names]
        if counter not in names:
            names.append(counter)
        for category in PLURAL_CATEGORIES:
            if category in branches:
                names += [n for n in placeholders(branches[category]) if n not in names]
        names += [n for n in placeholders(suffix) if n not in names]
    else:
        names = placeholders(value)

    arguments = []
    for name in names:
        if not NAME_PATTERN.match(name):
            raise Failure(f"{key}: '{name}' is not a lowerCamelCase placeholder name")
        kind = "int" if (plural and name == plural[1][0]) else declared.get(name, "string")
        if kind not in ARG_TYPES:
            raise Failure(
                f"{key}: argument '{name}' declared as '{kind}'; only "
                f"{', '.join(sorted(ARG_TYPES))} exist — format a decimal at the "
                f"call site so number formatting stays in one place"
            )
        arguments.append((name, kind))
    unknown = sorted(set(declared) - {name for name, _ in arguments})
    if unknown:
        raise Failure(f"{key}: args declares {unknown} which the value never uses")
    return arguments


def load(language: str) -> dict:
    path = SOURCE_DIR / f"{language}.json"
    if not path.exists():
        raise Failure(f"missing catalog {path.relative_to(ROOT)}")
    try:
        document = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise Failure(f"{path.name} is not valid JSON: {error}") from error
    if not isinstance(document, dict):
        raise Failure(f"{path.name} must be a flat object of key -> entry")
    entries = {}
    for key, entry in document.items():
        if not isinstance(entry, dict) or "value" not in entry:
            raise Failure(f"{path.name}: {key} must be an object with a 'value'")
        value = entry["value"]
        if not isinstance(value, str) or not value.strip():
            raise Failure(f"{path.name}: {key} has an empty or non-string value")
        comment = entry.get("comment")
        if comment is not None and not isinstance(comment, str):
            raise Failure(f"{path.name}: {key} has a non-string comment")
        args = entry.get("args", {})
        if not isinstance(args, dict):
            raise Failure(f"{path.name}: {key} has a non-object 'args'")
        unexpected = sorted(set(entry) - {"value", "comment", "args"})
        if unexpected:
            raise Failure(f"{path.name}: {key} has unknown field(s) {unexpected}")
        entries[key] = {"value": value, "comment": comment, "args": args}
    return entries


# --------------------------------------------------------------- checking


def check_base(entries: dict) -> dict:
    """Validate en.json and return key -> [(name, type)]."""
    arguments = {}
    members = {}
    for key, entry in sorted(entries.items()):
        scope = key.split(".", 1)[0]
        if scope not in SCOPES:
            raise Failure(
                f"{key}: '{scope}' is not a surface scope ({', '.join(sorted(SCOPES))})"
            )
        if not KEY_PATTERN.match(key):
            raise Failure(f"{key}: keys are dotted stable identifiers, never sentences")
        leaked = PRINTF.search(entry["value"])
        if leaked:
            raise Failure(
                f"{key}: {leaked.group(0)!r} is a printf specifier leaking into "
                f"the catalog — write a named placeholder like {{provider}} instead"
            )
        arguments[key] = entry_arguments(key, entry["value"], entry["args"])
        member = (SCOPES[scope], swift_member(key))
        if member in members:
            raise Failure(
                f"{key} and {members[member]} both generate "
                f"L10n.{member[0]}.{member[1]}"
            )
        members[member] = key
    return arguments


def check_translation(language: str, base: dict, base_args: dict, entries: dict) -> None:
    missing = sorted(set(base) - set(entries))
    if missing:
        raise Failure(
            f"{language}.json is missing {len(missing)} key(s): "
            f"{', '.join(missing[:8])}{' …' if len(missing) > 8 else ''}"
        )
    extra = sorted(set(entries) - set(base))
    if extra:
        raise Failure(
            f"{language}.json has {len(extra)} key(s) en.json does not: "
            f"{', '.join(extra[:8])}{' …' if len(extra) > 8 else ''}"
        )
    for key in sorted(base):
        entry = entries[key]
        if PRINTF.search(entry["value"]):
            raise Failure(f"{language}.json: {key} contains a printf specifier")
        if entry["args"]:
            raise Failure(
                f"{language}.json: {key} declares 'args' — argument types are "
                f"declared once, in en.json"
            )
        expected = {name for name, _ in base_args[key]}
        actual = {name for name, _ in entry_arguments(
            key, entry["value"], {n: t for n, t in base_args[key]}
        )}
        if expected != actual:
            raise Failure(
                f"{language}.json: {key} uses {sorted(actual)} but en.json "
                f"defines {sorted(expected)} — a placeholder a translation "
                f"invents renders as literal braces, and one it drops loses "
                f"the number it was carrying"
            )
        base_plural = parse_plural(key, base[key]["value"])
        plural = parse_plural(key, entry["value"])
        if bool(base_plural) != bool(plural):
            raise Failure(
                f"{language}.json: {key} is a plural in one language and not "
                f"the other"
            )
        if plural and "other" not in plural[1][1]:
            raise Failure(f"{language}.json: {key} has no 'other' plural branch")


# --------------------------------------------------------------- emitting


def escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def positional(text: str, order: dict, types: dict, escape_percent: bool) -> str:
    """Named placeholders → positional printf specifiers.

    A value with arguments is handed to `String(format:)`, so an ordinary
    `%` in the copy — "80% used" — has to be doubled or it eats the
    character after it. A value with no arguments is returned verbatim and
    must keep its single `%`. The generator knows which is which, so
    neither the author nor the translator has to.
    """
    if escape_percent:
        text = text.replace("%", "%%")
    def swap(match):
        name = match.group(1)
        return f"%{order[name]}${ARG_TYPES[types[name]]['spec']}"
    return PLACEHOLDER.sub(swap, text)


def render_strings(language: str, base: dict, entries: dict, base_args: dict) -> str:
    lines = [
        "/* Vibe Bar — generated by Scripts/build_localizations.py from",
        f"   Resources/i18n/{language}.json. Do not edit: LocalizationCatalogTests",
        "   regenerates this file and fails on a diff. */",
        "",
    ]
    for key in sorted(entries):
        if parse_plural(key, base[key]["value"]):
            continue  # lives in the .stringsdict instead
        arguments = base_args[key]
        order = {name: index + 1 for index, (name, _) in enumerate(arguments)}
        types = dict(arguments)
        note = entries[key]["comment"] or base[key]["comment"]
        if note:
            lines.append(f"/* {note} */")
        value = positional(entries[key]["value"], order, types, bool(arguments))
        lines.append(f'"{escape(key)}" = "{escape(value)}";')
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def render_stringsdict(language: str, base: dict, entries: dict, base_args: dict) -> str:
    plural_keys = [k for k in sorted(entries) if parse_plural(k, base[k]["value"])]
    body = []
    for key in plural_keys:
        arguments = base_args[key]
        order = {name: index + 1 for index, (name, _) in enumerate(arguments)}
        types = dict(arguments)
        prefix, (counter, branches), suffix = parse_plural(key, entries[key]["value"])
        # `NSStringLocalizedFormatKey` is the sentence with the plural block
        # standing in as a variable; the variable's own dict holds the
        # per-category spellings, with `#` becoming the number itself.
        # `%N$#@name@`, not `%#@name@`: the rest of the sentence uses explicit
        # positions, and an implicit variable mixed in with them makes
        # Foundation feed the plural whichever argument came first — which,
        # for a sentence that names a quota before counting its cycles, is a
        # string. It then falls through to `other` for every count.
        frame = (
            positional(prefix, order, types, True)
            + f"%{order[counter]}$#@{counter}@"
            + positional(suffix, order, types, True)
        )
        body.append(f"\t<key>{escape_xml(key)}</key>")
        body.append("\t<dict>")
        body.append("\t\t<key>NSStringLocalizedFormatKey</key>")
        body.append(f"\t\t<string>{escape_xml(frame)}</string>")
        body.append(f"\t\t<key>{escape_xml(counter)}</key>")
        body.append("\t\t<dict>")
        body.append("\t\t\t<key>NSStringFormatSpecTypeKey</key>")
        body.append("\t\t\t<string>NSStringPluralRuleType</string>")
        body.append("\t\t\t<key>NSStringFormatValueTypeKey</key>")
        body.append(f"\t\t\t<string>{ARG_TYPES['int']['value_type']}</string>")
        for category in PLURAL_CATEGORIES:
            if category not in branches:
                continue
            spelling = positional(
                branches[category], order, types, True
            ).replace("#", f"%{order[counter]}$lld")
            body.append(f"\t\t\t<key>{escape_xml(category)}</key>")
            body.append(f"\t\t\t<string>{escape_xml(spelling)}</string>")
        body.append("\t\t</dict>")
        body.append("\t</dict>")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        "<!-- Generated by Scripts/build_localizations.py from "
        f"Resources/i18n/{language}.json. Do not edit. -->\n"
        "<dict>\n" + ("\n".join(body) + "\n" if body else "") + "</dict>\n"
        "</plist>\n"
    )


def escape_xml(text: str) -> str:
    return (
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )


def swift_member(key: str) -> str:
    segments = key.split(".")[1:]
    head, *rest = segments
    name = head[0].lower() + head[1:] + "".join(s[0].upper() + s[1:] for s in rest)
    return name


def swift_identifier(name: str) -> str:
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def render_swift(base: dict, base_args: dict) -> str:
    lines = [
        "// Generated by Scripts/build_localizations.py from Resources/i18n/en.json.",
        "// Do not edit: LocalizationCatalogTests regenerates this file and fails",
        "// on a diff.",
        "//",
        "// This is the *only* way the App target reaches a localized string.",
        "// `L10n.string(_:)` is internal to VibeBarCore on purpose, so a key that",
        "// takes arguments cannot be fetched as a bare format string and filled in",
        "// by hand — the accessor takes named arguments and the generator owns the",
        "// positional order each language happens to need.",
        "",
        "import Foundation",
        "",
        "extension L10n {",
    ]
    by_scope = {}
    for key in sorted(base):
        by_scope.setdefault(SCOPES[key.split(".", 1)[0]], []).append(key)

    for index, scope in enumerate(sorted(by_scope)):
        if index:
            lines.append("")
        lines.append(f"    public enum {scope} {{")
        for key in by_scope[scope]:
            member = swift_identifier(swift_member(key))
            arguments = base_args[key]
            # A value may legitimately contain a newline — a multi-line
            # tooltip is one key, so that a translation can reorder its
            # lines — and a raw one here would end the `///` and leave the
            # rest of the sentence as invalid Swift.
            preview = (
                base[key]["value"].replace("*/", "* /").replace("\n", "\\n")
            )
            lines.append(f"        /// `{key}` — {preview}")
            if not arguments:
                lines.append(f"        public static var {member}: String {{")
                lines.append(f'            L10n.string("{key}")')
                lines.append("        }")
            else:
                signature = ", ".join(
                    f"{swift_identifier(name)}: {ARG_TYPES[kind]['swift']}"
                    for name, kind in arguments
                )
                passed = ", ".join(swift_identifier(name) for name, _ in arguments)
                lines.append(
                    f"        public static func {member}({signature}) -> String {{"
                )
                lines.append(f'            L10n.string("{key}", {passed})')
                lines.append("        }")
        lines.append("    }")
    lines.append("}")
    lines.append("")
    lines.append("extension L10n {")
    lines.append("    /// Every key the catalog defines, for the tests that assert the")
    lines.append("    /// shipped `.strings` resolve and that no key is unreachable.")
    lines.append("    static let allKeys: [String] = [")
    for key in sorted(base):
        lines.append(f'        "{key}",')
    lines.append("    ]")
    lines.append("")
    lines.append("    /// Keys whose value is a plural and therefore lives in the")
    lines.append("    /// `.stringsdict` rather than the `.strings` file.")
    lines.append("    static let pluralKeys: [String] = [")
    for key in sorted(base):
        if parse_plural(key, base[key]["value"]):
            lines.append(f'        "{key}",')
    lines.append("    ]")
    lines.append("}")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------- main


def main() -> None:
    check_only = "--check" in sys.argv[1:]
    base = load(BASE)
    if not base:
        raise Failure("en.json is empty")
    base_args = check_base(base)

    outputs = {}
    for language in LANGUAGES:
        entries = base if language == BASE else load(language)
        if language != BASE:
            check_translation(language, base, base_args, entries)
        check_register(language, entries)
        outputs[RESOURCE_DIR / f"{language}.lproj/Localizable.strings"] = (
            render_strings(language, base, entries, base_args)
        )
        outputs[RESOURCE_DIR / f"{language}.lproj/Localizable.stringsdict"] = (
            render_stringsdict(language, base, entries, base_args)
        )
    outputs[SWIFT_PATH] = render_swift(base, base_args)

    if check_only:
        stale = [
            str(path.relative_to(ROOT))
            for path, text in outputs.items()
            if not path.exists() or path.read_text() != text
        ]
        if stale:
            raise Failure(
                "stale generated files: " + ", ".join(sorted(stale))
                + " — run Scripts/build_localizations.py"
            )
        print(f"localizations up to date: {len(base)} keys × {len(LANGUAGES)} languages")
        return

    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    plurals = sum(1 for k in base if parse_plural(k, base[k]["value"]))
    print(
        f"{len(base)} keys ({plurals} plural) × {len(LANGUAGES)} languages → "
        f"{len(outputs)} generated files"
    )


if __name__ == "__main__":
    main()
