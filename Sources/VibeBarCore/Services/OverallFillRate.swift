import Foundation

/// Aggregate "how full are my subscription plans, overall" across the
/// four primary providers. Used by the Cost summary card to replace
/// the empty RPM cell with a meaningful single number.
///
/// Aggregation rules:
///   - Claude  → bucket id "weekly" with no `groupTitle` (sub-buckets
///               like weekly_sonnet/weekly_opus are ignored to avoid
///               double-counting Claude's plan).
///   - Codex   → bucket id "weekly".
///   - Grok    → bucket id "monthly".
///   - Gemini  → arithmetic mean of all of that account's buckets
///               (per-model dailies).
///
/// Multiple accounts of the same tool are averaged within the tool
/// first; tool-level averages then contribute equally to the overall
/// mean. Tools without data are skipped. Returns nil when no tool
/// contributes a finite value.
public enum OverallFillRate {
    public static func average(_ quotas: [String: AccountQuota]) -> Double? {
        var perTool: [ToolType: [Double]] = [:]
        for (_, quota) in quotas {
            guard let value = headlineValue(for: quota) else { continue }
            perTool[quota.tool, default: []].append(value)
        }
        let toolMeans: [Double] = perTool.values.compactMap { values in
            let finite = values.filter { $0.isFinite }
            guard !finite.isEmpty else { return nil }
            return finite.reduce(0, +) / Double(finite.count)
        }
        guard !toolMeans.isEmpty else { return nil }
        return toolMeans.reduce(0, +) / Double(toolMeans.count)
    }

    private static func headlineValue(for quota: AccountQuota) -> Double? {
        switch quota.tool {
        case .claude:
            return quota.buckets
                .first(where: { $0.id == "weekly" && $0.groupTitle == nil })
                .flatMap { $0.usedPercent.isFinite ? $0.usedPercent : nil }
        case .codex:
            return quota.buckets
                .first(where: { $0.id == "weekly" })
                .flatMap { $0.usedPercent.isFinite ? $0.usedPercent : nil }
        case .grok:
            return quota.buckets
                .first(where: { $0.id == "monthly" })
                .flatMap { $0.usedPercent.isFinite ? $0.usedPercent : nil }
        case .gemini:
            let valid = quota.buckets.filter { $0.usedPercent.isFinite }
            guard !valid.isEmpty else { return nil }
            return valid.reduce(0.0) { $0 + $1.usedPercent } / Double(valid.count)
        default:
            return nil
        }
    }
}
