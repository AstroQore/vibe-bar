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
