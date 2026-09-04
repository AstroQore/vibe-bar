import Foundation

/// The seam between the two naming axes and the translated layer.
///
/// `AGENTS.md` § 7.1 makes the quota axis — L1 company, L2 SubProvider,
/// L3 group — a shared contract: `docs/contracts/quota-naming-v1.json`
/// is what this app and Vibe Bar Desktop both arrange providers by, and
/// a bucket filed under one name here and another there is two things to
/// the reader. So those values are never translated. They are also not
/// all proper nouns: "Weekly", "5 Hours", "All Models" are English words
/// a Chinese reader has no reason to meet in the middle of a Chinese
/// card.
///
/// Both are true at once, and this is how: the contract keeps its English
/// value, and this maps a *known* set of generic window and coverage
/// words onto the catalog on the way to the screen. Anything it does not
/// recognize — "Sonnet", "Codex Spark", "Gemini Models", a bucket
/// discovered at runtime — comes back exactly as it arrived, because a
/// model or product name is not something a translation may improve.
///
/// The table is deliberately exhaustive rather than pattern-matched. A
/// rule like "translate any label containing 'Weekly'" would rename
/// "Weekly Fable" and invent a Chinese name for a model.
///
/// One kind of part cannot be listed, because it is not a fixed string: a
/// *measurement* an adapter composed, like MiniMax's "90% left". See
/// `measured(_:)` for why an anchored numeric form is safe where a
/// substring rule is not.
public enum QuotaGroupLabelLocalizer {
    /// Contract label → catalog key. Keys are compared case-insensitively
    /// so a discovered bucket's `groupTitle` spelling cannot slip past.
    private static let table: [String: () -> String] = [
        "weekly": { L10n.Quota.groupWeekly },
        "monthly": { L10n.Quota.groupMonthly },
        "daily": { L10n.Quota.groupDaily },
        "5 hours": { L10n.Quota.groupFiveHours },
        "all models": { L10n.Quota.groupAllModels },
        "other models": { L10n.Quota.groupOtherModels },
        "other": { L10n.Quota.groupOther },
        "weekly credits": { L10n.Quota.groupWeeklyCredits },
    ]

    /// The label to show for a contract group name.
    public static func display(_ contractLabel: String) -> String {
        let trimmed = contractLabel.trimmingCharacters(in: .whitespaces)
        if let table = table[trimmed.lowercased()]?() { return table }
        return measured(trimmed) ?? contractLabel
    }

    /// A contract part that is a *measurement* rather than a name.
    ///
    /// The table above is a list and not a rule on purpose — "translate
    /// anything containing 'Weekly'" would rename "Weekly Fable" and invent
    /// a Chinese name for a model. That reasoning is about names, and it is
    /// exactly why an adapter cannot fix this by adding a table entry: a
    /// percentage is not a fixed string, so there is no key to list.
    ///
    /// MiniMax's percentage-metered plans emit `"90% left · 5 hours"` as a
    /// bucket's `groupTitle`. `groupTitle` is a contract value — it is
    /// cached in `~/.vibebar/quotas/`, projected over MCP, and shared with
    /// the cross-platform client — so it stays English at rest, and the
    /// window half already translates here. The other half was a sentence
    /// of ours smuggled into a contract field, and a Chinese reader got
    /// "90% left · 5 小时".
    ///
    /// The match is whole-part and admits nothing but ASCII digits before
    /// the suffix, so unlike a substring rule it cannot reach a product or
    /// model name: nothing is called "90% left", and "Fable 90% left" is
    /// not a part this ever sees whole. The wording comes from
    /// `quota.forecast.value.left`, the key the forecast row and the mini
    /// window already say this with, so the app says it one way.
    private static let leftSuffix = "% left"

    private static func measured(_ part: String) -> String? {
        guard part.lowercased().hasSuffix(leftSuffix) else { return nil }
        let digits = part.dropLast(leftSuffix.count)
        guard !digits.isEmpty,
              digits.count <= 3,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let percent = Int(digits) else { return nil }
        return L10n.Quota.forecastValueLeft(percent: percent)
    }

    /// The separator a composed contract label is built with, on every
    /// surface that builds one: "ChatGPT · All Models", "Claude · Weekly".
    private static let separator = " · "

    /// The label to show for a contract label that may be *composed*.
    ///
    /// `display` is a whole-string lookup, so it returns "All Models · Weekly"
    /// untouched — both halves are in the table, and neither gets translated
    /// because the joined string is not. This resolves part by part instead,
    /// which is the only rule that gets both of these right at once:
    ///
    /// - "All Models · Weekly" translates both halves.
    /// - "GPT-5.3 Codex Spark · 5 Hours" keeps the product name and
    ///   translates only the window.
    ///
    /// A label with no separator is one part, so this agrees with `display`
    /// on every simple label and can be used wherever a label is drawn.
    ///
    /// Splitting on the separator rather than on whitespace is what keeps
    /// "All Models" whole; a word-by-word rule would look up "All" and
    /// "Models" separately and translate neither.
    public static func displayComposed(_ contractLabel: String) -> String {
        guard contractLabel.contains(separator) else { return display(contractLabel) }
        return contractLabel
            .components(separatedBy: separator)
            .map(display)
            .joined(separator: separator)
    }

    /// Whether a label is one this translates, for the tests that assert a
    /// model name is *not* in the table.
    public static func isTranslated(_ contractLabel: String) -> Bool {
        let trimmed = contractLabel.trimmingCharacters(in: .whitespaces)
        return table[trimmed.lowercased()] != nil || measured(trimmed) != nil
    }
}
