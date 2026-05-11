import Foundation

public enum ProviderPlanDisplay {
    public static func displayName(for tool: ToolType, rawPlan: String?) -> String? {
        switch tool {
        case .codex:
            return codexDisplayName(rawPlan)
        case .claude:
            return claudeDisplayName(rawPlan)
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine, .openCodeGo, .kilo, .kiro, .ollama, .openRouter:
            // Misc providers feed `plan` straight through. Each adapter
            // is responsible for normalizing the raw API response
            // (e.g. `Pro Coding` → `Pro`) before it reaches this map.
            return codexDisplayName(rawPlan)
        }
    }

    public static func codexDisplayName(_ rawPlan: String?) -> String? {
        guard let raw = trimmed(rawPlan) else { return nil }
        let lower = raw.lowercased()
        if let exact = codexExactDisplayNames[lower] {
            return exact
        }

        let cleaned = cleanPlanName(raw)
        let components = cleaned
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return cleaned.isEmpty ? raw : cleaned }
        let formatted = components.map(wordDisplayName).joined(separator: " ")
        return formatted.isEmpty ? raw : formatted
    }

    public static func claudeDisplayName(_ rawPlan: String?) -> String? {
        guard let raw = trimmed(rawPlan) else { return nil }
        if let plan = ClaudePlan.fromCompatibilityLoginMethod(raw) {
            return plan.compactLoginMethod
        }
        return codexDisplayName(raw)
    }

    public static func claudeDisplayName(rateLimitTier: String?, billingType: String? = nil) -> String? {
        ClaudePlan.webPlan(rateLimitTier: rateLimitTier, billingType: billingType)?.compactLoginMethod
    }

    private static let codexExactDisplayNames: [String: String] = [
        "prolite": "Pro Lite",
        "pro_lite": "Pro Lite",
        "pro-lite": "Pro Lite",
        "pro lite": "Pro Lite"
    ]

    private static let uppercaseWords: Set<String> = [
        "cbp",
        "k12"
    ]

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func cleanPlanName(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if lower.hasSuffix(" plan") {
            cleaned.removeLast(5)
        } else if lower.hasSuffix(" account") {
            cleaned.removeLast(8)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordDisplayName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let exact = codexExactDisplayNames[lower] {
            return exact
        }
        if uppercaseWords.contains(lower) {
            return lower.uppercased()
        }
        if raw == raw.uppercased(), raw.contains(where: \.isLetter) {
            return raw
        }
        if let first = raw.first, first.isLowercase {
            return raw.prefix(1).uppercased() + String(raw.dropFirst())
        }
        return raw
    }
}

public enum ClaudePlan: String, CaseIterable, Sendable {
    case max
    case pro
    case team
    case enterprise
    case ultra

    public var compactLoginMethod: String {
        switch self {
        case .max:        return "Max"
        case .pro:        return "Pro"
        case .team:       return "Team"
        case .enterprise: return "Enterprise"
        case .ultra:      return "Ultra"
        }
    }

    public static func webPlan(rateLimitTier: String?, billingType: String?) -> Self? {
        if let plan = fromRateLimitTier(rateLimitTier) {
            return plan
        }

        let tier = normalized(rateLimitTier)
        let billing = normalized(billingType)
        if billing.contains("stripe"), tier.contains("claude") {
            return .pro
        }
        return nil
    }

    public static func fromCompatibilityLoginMethod(_ loginMethod: String?) -> Self? {
        let words = normalizedWords(loginMethod)
        if words.contains("max") {
            return .max
        }
        if words.contains("pro") {
            return .pro
        }
        if words.contains("team") {
            return .team
        }
        if words.contains("enterprise") {
            return .enterprise
        }
        if words.contains("ultra") {
            return .ultra
        }
        return nil
    }

    private static func fromRateLimitTier(_ rateLimitTier: String?) -> Self? {
        let tier = normalized(rateLimitTier)
        if tier.contains("max") {
            return .max
        }
        if tier.contains("pro") {
            return .pro
        }
        if tier.contains("team") {
            return .team
        }
        if tier.contains("enterprise") {
            return .enterprise
        }
        if tier.contains("ultra") {
            return .ultra
        }
        return nil
    }

    private static func normalized(_ text: String?) -> String {
        text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func normalizedWords(_ text: String?) -> [String] {
        normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
