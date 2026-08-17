import Foundation

/// Canonical Workbench display for model variants learned as human labels.
/// Google publishes `gemini-3.5-flash` (decimal point, not `3-5`) and exposes
/// thinking level separately; AntiGravity labels that level in parentheses,
/// so Vibe Bar appends it as a stable local variant suffix.
public enum UsageModelNaming {
    public static func canonicalDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown model" }
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
