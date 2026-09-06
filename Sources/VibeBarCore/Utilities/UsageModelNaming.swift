import Foundation

/// Canonical Workbench display for model variants learned as human labels.
/// Google publishes `gemini-3.5-flash` (decimal point, not `3-5`) and exposes
/// thinking level separately; AntiGravity labels that level in parentheses,
/// so Vibe Bar appends it as a stable local variant suffix.
public enum UsageModelNaming {
    /// AntiGravity records some turns under an internal model enum —
    /// `MODEL_PLACEHOLDER_M318` and the like — for which no human label has
    /// been learned. It is an identifier for the pricing side to key on,
    /// not a name anyone should read.
    public static func isUnlabelledModelEnum(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("MODEL_"), trimmed.count > 6 else { return false }
        return trimmed.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    public static func canonicalDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown model" }
        if isUnlabelledModelEnum(trimmed) { return "Unlabelled model" }
        guard trimmed.lowercased().hasPrefix("gemini ") else {
            return trimmed
        }

        let base: String
        let variant: String?
        if let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") {
            base = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            variant = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            base = trimmed
            variant = nil
        }

        let slug = base.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        guard let variant, !variant.isEmpty else { return slug }
        let variantSlug = variant.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        return "\(slug)-\(variantSlug)"
    }
}
