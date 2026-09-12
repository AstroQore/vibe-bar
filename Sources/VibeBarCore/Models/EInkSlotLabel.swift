import Foundation

/// How the panel names one quota slot.
///
/// Round 1 shipped a short per-provider table ("Claude", "Codex") and the
/// owner's review killed it: on a panel showing two Claude rows and two Codex
/// rows, "Claude · Weekly" does not say *which* weekly bucket it is, and the
/// one surface that already answers that question — the mini window — spells
/// it out in three tiers. This resolves the same three tiers, in English and
/// unabbreviated, because a panel read across a desk has no tooltip.
///
/// The tiers, joined by `" · "`:
///
/// 1. **SubProvider** — `ToolType.quotaSubProviderName(bucketID:)`: "Claude",
///    "ChatGPT Agentic", "AntiGravity", "Grok Bot".
/// 2. **Quota group** — only for a *branch* bucket, i.e. one whose
///    `MenuBarFieldCatalog.namingGroupKey` is not the SubProvider's own
///    `<tool>.all-models` catch-all. "Fable", "GPT-5.3 Codex Spark",
///    "Claude and GPT Models". Taken from the contract title rather than
///    from `MiniWindowGroupLabelCatalog.defaultLabel`, whose short forms
///    ("Claude + GPT") are exactly the abbreviations the panel may not print.
/// 3. **Window** — "Weekly", "5 Hours", "Daily", "Monthly".
///
/// A part equal to one already emitted is dropped, so Grok Bot's single
/// weekly reads "Grok Bot · Weekly" rather than naming itself twice.
public enum EInkSlotLabel {
    public static let separator = " · "

    /// The default label for one quota field.
    ///
    /// `bucket` is the live bucket when the assembler has one: a provider that
    /// renamed a window, or a bucket the static catalog has never heard of,
    /// is named by what it actually returned.
    public static func `default`(
        for fieldID: String,
        registry: QuotaFieldRegistry = .empty,
        bucket: QuotaBucket? = nil
    ) -> String {
        parts(for: fieldID, registry: registry, bucket: bucket).joined(separator: separator)
    }

    /// The label a slide prints for a slot: its own override, else the
    /// default.
    public static func resolved(
        for fieldID: String,
        options: EInkSlideOptions,
        registry: QuotaFieldRegistry = .empty,
        bucket: QuotaBucket? = nil
    ) -> String {
        options.customLabel(for: fieldID)
            ?? `default`(for: fieldID, registry: registry, bucket: bucket)
    }

    /// The tiers, already de-duplicated and with empties dropped.
    public static func parts(
        for fieldID: String,
        registry: QuotaFieldRegistry = .empty,
        bucket: QuotaBucket? = nil
    ) -> [String] {
        guard let selector = EInkDataAssembler.selector(fieldID: fieldID) else {
            return [fieldID]
        }
        let field = MenuBarFieldCatalog.field(id: fieldID, registry: registry)
        var raw: [String] = [selector.tool.quotaSubProviderName(bucketID: selector.bucketID)]
        if let group = groupTitle(selector: selector, field: field, bucket: bucket) {
            raw.append(group)
        }
        if let window = windowTitle(field: field, bucket: bucket) {
            raw.append(window)
        }
        var seen = Set<String>()
        var kept: [String] = []
        for part in raw.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !part.isEmpty, seen.insert(part.lowercased()).inserted else { continue }
            // "Cursor · Cursor Models · Monthly" names its SubProvider twice.
            // A tier that merely restates an earlier one, with or without a
            // trailing noun, is dropped rather than printed on a 296 px panel.
            if kept.contains(where: { part.lowercased().hasPrefix($0.lowercased() + " ") }) { continue }
            kept.append(part)
        }
        return kept
    }

    /// Two lines for a slot too narrow for one: the SubProvider on top, the
    /// rest underneath.
    ///
    /// Rings and the rail always draw this form (centred); the ledger and the
    /// table only fall back to it when the label outruns a grown column.
    public static func twoLines(_ label: String) -> (first: String, second: String) {
        let parts = label.components(separatedBy: separator)
        guard parts.count > 1 else { return (label, "") }
        return (parts[0], parts.dropFirst().joined(separator: separator))
    }

    /// Whether `label` needs the two-line form in a column this wide, at the
    /// device's pixel font.
    public static func needsTwoLines(_ label: String, columnWidth: Int, font: EInkFont = .pixel12(bold: false)) -> Bool {
        EInkTextMetrics.width(label, font: font) > columnWidth
    }

    /// The widest label in `labels`, in device pixels.
    public static func widestWidth(_ labels: [String], font: EInkFont = .pixel12(bold: false)) -> Int {
        labels.map { EInkTextMetrics.width($0, font: font) }.max() ?? 0
    }

    // MARK: - Tiers

    /// The L3 quota group, or `nil` when the bucket sits directly under its
    /// SubProvider.
    static func groupTitle(
        selector: EInkDataAssembler.QuotaSelector,
        field: MenuBarFieldOption?,
        bucket: QuotaBucket?
    ) -> String? {
        // A bucket whose own group title is just its SubProvider (Grok Bot)
        // adds nothing: the first tier already said it.
        let subProvider = selector.tool.quotaSubProviderName(bucketID: selector.bucketID)
        if let live = bucket?.groupTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !live.isEmpty,
           live.caseInsensitiveCompare(subProvider) != .orderedSame,
           !isCatchAll(live)
        {
            return live
        }
        guard let field else { return nil }
        // The catch-all lane ("All Models") is not a name, it is the absence
        // of one: "Claude · All Models · Weekly" reads as three tiers where
        // there are two.
        guard let key = MenuBarFieldCatalog.namingGroupKey(for: field),
              key != MenuBarFieldCatalog.allModelsGroupKey(for: field.tool)
        else { return nil }
        let parts = field.title.components(separatedBy: separator)
        guard parts.count > 1 else { return nil }
        let group = parts.dropLast().joined(separator: separator)
        return isCatchAll(group) ? nil : group
    }

    /// The window word, written out.
    static func windowTitle(field: MenuBarFieldOption?, bucket: QuotaBucket?) -> String? {
        if let bucket {
            let title = bucket.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        guard let field else { return nil }
        return field.title.components(separatedBy: separator).last
    }

    static func isCatchAll(_ value: String) -> Bool {
        value.caseInsensitiveCompare("All Models") == .orderedSame
    }
}

// MARK: - Fitting a name into a box

public extension EInkSlotLabel {
    /// How much wider than its measurement a string is assumed to draw.
    ///
    /// `EInkTextMetrics` buckets the device's glyphs into a handful of
    /// advances, so a measurement can be a glyph short of what the panel
    /// actually inks — and the first hardware push of round 2 came back with
    /// "67%" printed as "7%" because a box was sized to the estimate exactly.
    /// Every fit test therefore asks for one glyph more, which is the slack
    /// convention the briefing layout already used (its `+10` stats column).
    static let measurementSlack = 8

    /// Whether `text` fits a box this wide, slack included.
    static func fits(_ text: String, width: Int, font: EInkFont = .pixel12(bold: false)) -> Bool {
        text.isEmpty || EInkTextMetrics.width(text, font: font) + measurementSlack <= width
    }

    /// `text` cut down to `width` with a trailing "…".
    ///
    /// The only truncation the panel is allowed to perform, and only once a
    /// name has already been given a whole row of its own. A cut word is
    /// still a readable name; a cut *figure* is a wrong number, which is why
    /// nothing else here is ever shortened.
    static func truncated(_ text: String, width: Int, font: EInkFont = .pixel12(bold: false)) -> String {
        if fits(text, width: width, font: font) { return text }
        var characters = Array(text)
        while !characters.isEmpty {
            characters.removeLast()
            let candidate = String(characters)
                .trimmingCharacters(in: .whitespaces) + ellipsis
            if fits(candidate, width: width, font: font) { return candidate }
        }
        return ellipsis
    }

    /// Whether a string was shortened by `truncated`.
    static func isTruncated(_ text: String) -> Bool { text.hasSuffix(ellipsis) }

    static var ellipsis: String { "…" }

    /// The label's tiers packed onto lines no wider than `width`.
    ///
    /// Tiers join with `separator` while they fit, so "Claude · Weekly" stays
    /// one line and "ChatGPT Agentic · GPT-5.3 Codex Spark · Weekly" becomes
    /// the two lines the reader would break it at anyway. A tier too wide for
    /// a line of its own is truncated; everything else is intact.
    /// `truncateAt` is the width a line may never exceed, which is not always
    /// the width it is packed to: a ring cell is 56 px of a 284 px row, and
    /// the ported layouts deliberately let a name spill onto a neighbour's
    /// slack (`longestInMiddle` exists for exactly that) rather than cut it.
    /// Packing at the cell width and truncating at the row's still breaks the
    /// name where it reads, without shortening anything that the panel has
    /// room for.
    static func wrapped(
        _ label: String,
        width: Int,
        font: EInkFont = .pixel12(bold: false),
        maxLines: Int = 3,
        truncateAt: Int? = nil
    ) -> [String] {
        let tiers = label
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tiers.isEmpty else { return [] }
        var lines: [String] = []
        for tier in tiers {
            if let last = lines.last, fits(last + separator + tier, width: width, font: font) {
                lines[lines.count - 1] = last + separator + tier
            } else {
                lines.append(tier)
            }
        }
        // A tier wider than the line it landed on breaks at its spaces —
        // "Claude and GPT Models" is one tier and two readable halves, and a
        // 94 px ring cell has room for neither the whole of it nor an
        // apology for cutting it. Each piece remembers which tier it came
        // from, so a line that has to be put back together again is joined
        // with the separator where the name had one and a space where it did
        // not: "Codex Spark Weekly" is not this bucket's name.
        var pieces: [(text: String, tier: Int)] = []
        for (index, line) in lines.enumerated() {
            pieces += wordWrapped(line, width: width, font: font).map { ($0, index) }
        }
        let keep = max(1, maxLines)
        if pieces.count > keep {
            var tail = pieces[keep - 1]
            for piece in pieces[keep...] {
                tail.text += (piece.tier == tail.tier ? " " : separator) + piece.text
                tail.tier = piece.tier
            }
            pieces = Array(pieces.prefix(keep - 1)) + [tail]
        }
        let limit = truncateAt ?? width
        return pieces.map { truncated($0.text, width: limit, font: font) }
    }

    /// One line broken at its spaces. A single word wider than the line is
    /// left alone: breaking inside a word invents a name nobody typed.
    static func wordWrapped(_ line: String, width: Int, font: EInkFont) -> [String] {
        guard !fits(line, width: width, font: font) else { return [line] }
        var packed: [String] = []
        for word in line.split(separator: " ").map(String.init) {
            if let last = packed.last, fits(last + " " + word, width: width, font: font) {
                packed[packed.count - 1] = last + " " + word
            } else {
                packed.append(word)
            }
        }
        return packed.isEmpty ? [line] : packed
    }
}

/// How one ledger or table slot spells its name once the label column has
/// grown as far as the bar will allow.
///
/// The figure row always carries the bar, the percentage and the countdown;
/// what changes is how much of the name sits in its label column and how many
/// full-width lines the rest needs. `EInkSlotLabel.slotLines` decides, and
/// both orientations of the ledger draw what it returns.
public struct EInkSlotLines: Equatable, Sendable {
    /// Full-width lines drawn above the figure row.
    public var leading: [EInkSlotLineFragment]
    /// What sits in the label column, beside the bar. Empty is legal: the
    /// column then holds the row's left edge and nothing else.
    public var column: EInkSlotLineFragment
    /// Full-width lines drawn under the figure row.
    public var trailing: [EInkSlotLineFragment]

    /// How many text rows tall the slot is. A two-line slot costs two.
    public var lineCount: Int { 1 + leading.count + trailing.count }
    /// Whether any part of the name had to be cut.
    public var isTruncated: Bool {
        ([column] + leading + trailing).contains { EInkSlotLabel.isTruncated($0.text) }
    }
}

/// One drawn line of a slot name, and which part of the name it prints.
///
/// The part matters after "Edit in Studio": an exploded fragment that could
/// not say what it was would come back as frozen text, which is the bug the
/// landscape briefing shipped with.
public struct EInkSlotLineFragment: Equatable, Sendable {
    public var text: String
    public var part: EInkSlotLabelPart?

    public init(_ text: String, part: EInkSlotLabelPart? = nil) {
        self.text = text
        self.part = part
    }
}

public extension EInkSlotLabel {
    /// How a slot spells itself in a label column `column` wide, on a row
    /// `full` wide.
    ///
    /// The column has already grown as far as the bar allows, so this is the
    /// second step of the rule: the whole name if it fits, else the
    /// SubProvider in the column with the group and window on a line of their
    /// own, else the name on full-width lines with the figures under it.
    static func slotLines(
        name: String,
        window: String,
        column: Int,
        full: Int,
        font: EInkFont = .pixel12(bold: false)
    ) -> EInkSlotLines {
        let whole = window.isEmpty ? name : name + separator + window
        if fits(whole, width: column, font: font) {
            return EInkSlotLines(leading: [], column: EInkSlotLineFragment(whole, part: .whole), trailing: [])
        }
        if !window.isEmpty, fits(name, width: column, font: font) {
            let lines = wrapped(window, width: full, font: font, maxLines: 2)
            return EInkSlotLines(
                leading: [],
                column: EInkSlotLineFragment(name, part: .name),
                // A window that still needs two lines is two fragments, and a
                // fragment is not the window: only the whole of it may claim
                // the binding.
                trailing: lines.map { EInkSlotLineFragment($0, part: lines.count == 1 ? .window : nil) }
            )
        }
        let lines = wrapped(whole, width: full, font: font, maxLines: 2)
        return EInkSlotLines(
            leading: lines.map { EInkSlotLineFragment($0, part: lines.count == 1 ? .whole : nil) },
            column: EInkSlotLineFragment(""),
            trailing: []
        )
    }

    /// The same, for a slot whose provider is drawn as a mark rather than
    /// spelled out: there is no SubProvider tier left to keep the figures
    /// company, so the words either fit the column or take a line under it.
    static func slotLines(
        text: String,
        part: EInkSlotLabelPart?,
        column: Int,
        full: Int,
        font: EInkFont = .pixel12(bold: false)
    ) -> EInkSlotLines {
        if fits(text, width: column, font: font) {
            return EInkSlotLines(leading: [], column: EInkSlotLineFragment(text, part: part), trailing: [])
        }
        let lines = wrapped(text, width: full, font: font, maxLines: 2)
        return EInkSlotLines(
            leading: [],
            column: EInkSlotLineFragment(""),
            trailing: lines.map { EInkSlotLineFragment($0, part: lines.count == 1 ? part : nil) }
        )
    }

    /// The width a slot asks of the label column: the whole name when it fits
    /// `maximum`, else just the part that shares the row with the bar.
    static func columnWidth(
        name: String,
        window: String,
        maximum: Int,
        font: EInkFont = .pixel12(bold: false)
    ) -> Int {
        let whole = window.isEmpty ? name : name + separator + window
        if fits(whole, width: maximum, font: font) {
            return EInkTextMetrics.width(whole, font: font) + measurementSlack
        }
        if !window.isEmpty, fits(name, width: maximum, font: font) {
            return EInkTextMetrics.width(name, font: font) + measurementSlack
        }
        return 0
    }
}
