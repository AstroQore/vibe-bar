import Foundation

/// Display helpers for the usage ledger's `Int64` micro-USD money and
/// `Int64` token counts.
///
/// Money is stored and summed as integer micro-USD everywhere; this is the
/// only place it becomes a `Double`, and only to be printed. Conventions
/// match the existing cost cards (`$1.23`, `1.2k tok`, `3.40M tok`) so the
/// new usage surfaces read the same as the ones already shipping.
public enum UsageFormatting {
    /// `1_234_567` → `"$1.23"`. `precision` is clamped to 0…6 (a micro is
    /// the smallest unit stored, so more digits would be invented).
    /// Sub-unit amounts round rather than floor, but a non-zero amount
    /// never prints as `$0.00`: it falls back to `<$0.01` so a long tail of
    /// cheap requests doesn't look free.
    public static func formatMicroUSD(_ micros: Int64, precision: Int = 2) -> String {
        let digits = min(max(0, precision), 6)
        let value = Double(micros) / 1_000_000
        let magnitude = abs(value)
        if micros != 0, magnitude < pow(10, -Double(digits)) / 2 {
            let sign = micros < 0 ? "-" : ""
            let smallest = String(format: "%.\(digits)f", pow(10, -Double(digits)))
            return "\(sign)<$\(smallest)"
        }
        if value < 0 {
            return String(format: "-$%.\(digits)f", magnitude)
        }
        return String(format: "$%.\(digits)f", value)
    }

    /// Money at legend width: `$4.80`, `$47.6`, `$594`, `$11.6k`, `$1.2M`.
    /// Never wider than seven characters, so a trailing value column can pin
    /// its width instead of wrapping a full-precision amount.
    public static func compactUSD(_ micros: Int64) -> String {
        let sign = micros < 0 ? "-" : ""
        let value = Double(micros.magnitude) / 1_000_000
        if micros != 0, value < 0.005 { return "\(sign)<$0.01" }
        if value < 10 { return sign + String(format: "$%.2f", value) }
        if value < 100 { return sign + String(format: "$%.1f", value) }
        if value < 1_000 { return sign + String(format: "$%.0f", value) }
        if value < 100_000 { return sign + String(format: "$%.1fk", value / 1_000) }
        if value < 1_000_000 { return sign + String(format: "$%.0fk", value / 1_000) }
        return sign + String(format: "$%.1fM", value / 1_000_000)
    }

    /// `1_234` → `"1.2k"`, `3_400_000` → `"3.40M"`. No unit suffix — the
    /// caller decides whether to append `" tok"`.
    public static func compactTokens(_ tokens: Int64) -> String {
        let sign = tokens < 0 ? "-" : ""
        let magnitude = Double(tokens.magnitude)
        if magnitude < 1_000 { return "\(tokens)" }
        if magnitude < 1_000_000 { return sign + String(format: "%.1fk", magnitude / 1_000) }
        if magnitude < 1_000_000_000 { return sign + String(format: "%.2fM", magnitude / 1_000_000) }
        return sign + String(format: "%.2fB", magnitude / 1_000_000_000)
    }

    /// `compactTokens` with the `" tok"` suffix the cost cards already use.
    public static func formatTokens(_ tokens: Int64) -> String {
        "\(compactTokens(tokens)) tok"
    }

    /// A 0…1 ratio as a percentage. `nil` — no input-side traffic at all —
    /// prints as an em dash rather than a misleading `0%`.
    public static func formatPercent(_ ratio: Double?, precision: Int = 1) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        let digits = min(max(0, precision), 4)
        return String(format: "%.\(digits)f%%", ratio * 100)
    }
}
