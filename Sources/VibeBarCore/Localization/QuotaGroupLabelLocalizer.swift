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
        let normalized = contractLabel.trimmingCharacters(in: .whitespaces).lowercased()
        return table[normalized]?() ?? contractLabel
    }

    /// Whether a label is one this translates, for the tests that assert a
    /// model name is *not* in the table.
    public static func isTranslated(_ contractLabel: String) -> Bool {
        table[contractLabel.trimmingCharacters(in: .whitespaces).lowercased()] != nil
    }
}
