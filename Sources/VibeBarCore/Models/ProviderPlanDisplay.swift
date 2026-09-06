import Foundation

/// Presentation only; the account's raw plan remains the identity used by quota learning.
public enum SubscriptionNameFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case full
    case name
    case tier
    case tierWithMultiplier
    case multiplier

    public var id: String { rawValue }

    public var example: String {
        ProviderPlanDisplay.displayName(for: .codex, rawPlan: "pro", format: self)!
    }
}

public enum ProviderPlanDisplay {
    /// Render a canonical provider plan in the user's chosen label format.
    /// Only explicit numeric multiplier suffixes are removed; "Ultra Lite",
    /// "Pro+", and unfamiliar tier names keep their meaning.
    public static func displayName(
        for tool: ToolType, rawPlan: String?, format: SubscriptionNameFormat
    ) -> String? {
        guard let canonical = displayName(for: tool, rawPlan: rawPlan) else { return nil }
        let brand: String
        switch tool {
        case .codex, .chatgptChat: brand = "ChatGPT"
        case .claude: brand = "Claude"
        case .gemini, .antigravity: brand = "Google AI"
        case .grok: brand = canonical.lowercased().hasPrefix("supergrok") ? "SuperGrok" : "Grok"
        default: brand = tool.productName
        }
        var tier = canonical
        if tier.lowercased().hasPrefix(brand.lowercased() + " ") {
            tier = String(tier.dropFirst(brand.count + 1))
        }
        var multiplier: String?
        let range = NSRange(tier.startIndex..., in: tier)
        if let match = multiplierSuffix.firstMatch(in: tier, range: range),
           let numberRange = Range(match.range(at: 1), in: tier),
           let suffixRange = Range(match.range, in: tier) {
            multiplier = String(tier[numberRange]) + "x"
            tier.removeSubrange(suffixRange)
            tier = tier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A response containing only a multiplier still has a useful label.
        if tier.isEmpty { return multiplier ?? canonical }
        let tierWithMultiplier = [tier, multiplier].compactMap { $0 }.joined(separator: " ")
        switch format {
        case .full: return prefixed(tierWithMultiplier, brand: brand)
        case .name: return prefixed(tier, brand: brand)
        case .tier: return tier
        case .tierWithMultiplier: return tierWithMultiplier
        case .multiplier: return multiplier ?? tier
        }
    }

    private static let multiplierSuffix = try! NSRegularExpression(pattern: #"(?:^|\s)(\d+(?:\.\d+)?)\s*[xX×]$"#)

    public static func displayName(for tool: ToolType, rawPlan: String?) -> String? {
        switch tool {
        case .codex, .chatgptChat:
            return prefixed(openAIPlanName(rawPlan), brand: "ChatGPT")
        case .claude:
            return prefixed(claudeDisplayName(rawPlan), brand: "Claude")
        case .gemini, .antigravity:
            return prefixed(codexDisplayName(rawPlan), brand: "Google AI")
        case .grok:
            return grokDisplayName(rawPlan)
        case .cursor:
            // Cursor left the Misc bucket when it became a dedicated card in
            // the SpaceXAI family, so it gets its own case rather than
            // riding on the misc fall-through. `CursorQuotaAdapter`
            // already normalizes `membershipType` (`ultra` -> `Ultra`,
            // `free_trial` -> `Free Trial`), so the generic formatter is
            // still the right one and the rendered names do not change.
            // No brand prefix: the card is already titled "Cursor".
            return codexDisplayName(rawPlan)
        case .alibaba, .alibabaTokenPlan, .copilot, .zai, .minimax, .kimi, .mimo, .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine, .volcengineAgentPlan, .baiduQianfan, .openCodeGo, .kilo, .kiro, .ollama, .openRouter, .warp:
            // Misc providers feed `plan` straight through. Each adapter
            // is responsible for normalizing the raw API response
            // (e.g. `Pro Coding` → `Pro`) before it reaches this map.
            return codexDisplayName(rawPlan)
        }
    }

    /// OpenAI's API distinguishes the $200 plan as pro and $100 as prolite.
    /// Keep that mapping local to OpenAI; other providers also use "pro".
    public static func openAIPlanName(_ rawPlan: String?) -> String? {
        guard let raw = trimmed(rawPlan) else { return nil }
        switch raw.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "pro", "pro20x": return "Pro 20x"
        case "prolite", "pro5x": return "Pro 5x"
        default: return codexDisplayName(raw)
        }
    }

    /// Google Code Assist tier ids are more specific than the generic name
    /// returned by some clients. Keep Ultra Lite distinct; no multiplier guessed.
    public static func googleAIPlanName(tierId: String?, reportedName: String?) -> String? {
        let name = trimmed(reportedName)
        if let name, name.contains("5x") || name.contains("20x") { return name }
        switch trimmed(tierId)?.lowercased() {
        case "free-tier": return "Free"
        case "g1-pro-tier": return "Google AI Pro"
        case "g1-ultra-tier": return "Google AI Ultra"
        case "g1-ultra-lite-tier": return "Google AI Ultra Lite"
        default: return name
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
        if let multiplier = claudeMaxMultiplier(raw) { return "Max " + multiplier }
        if let plan = ClaudePlan.fromCompatibilityLoginMethod(raw) {
            return plan.compactLoginMethod
        }
        return codexDisplayName(raw)
    }

    public static func claudeDisplayName(rateLimitTier: String?, billingType: String? = nil) -> String? {
        if let multiplier = claudeMaxMultiplier(rateLimitTier) { return "Max " + multiplier }
        return ClaudePlan.webPlan(rateLimitTier: rateLimitTier, billingType: billingType)?.compactLoginMethod
    }

    public static func grokDisplayName(_ rawPlan: String?) -> String? {
        guard let display = codexDisplayName(rawPlan) else { return nil }
        let compact = display.replacingOccurrences(of: " ", with: "").lowercased()
        switch compact {
        case "supergrokheavy": return "SuperGrok Heavy"
        case "supergrokplus": return "SuperGrok Plus"
        case "supergrokpro": return "SuperGrok Pro"
        case "supergrok": return "SuperGrok"
        case "supergroklite": return "SuperGrok Lite"
        default: return display
        }
    }

    private static func claudeMaxMultiplier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if token.hasSuffix("max20x") { return "20x" }
        if token.hasSuffix("max5x") { return "5x" }
        return nil
    }

    private static func prefixed(_ plan: String?, brand: String) -> String? {
        guard let plan else { return nil }
        if plan.lowercased().hasPrefix(brand.lowercased() + " ") ||
            plan.caseInsensitiveCompare(brand) == .orderedSame {
            return plan
        }
        return "\(brand) \(plan)"
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
