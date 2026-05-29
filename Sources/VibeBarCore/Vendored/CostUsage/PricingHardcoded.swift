import Foundation

/// Hardcoded floor for `PricingResolver`. The bundled `pricing.json`
/// is the *real* source of truth in production builds, but tests
/// (and any pathological "bundle resource missing at runtime" case)
/// need a viable fallback so cost calculations don't silently start
/// returning `nil` for every model.
///
/// Keep this in sync with `Resources/pricing.json` when adding new
/// models. The PR template review checklist covers this; if a future
/// agent forgets, the new tests in `PricingResolverTests` will fail
/// because the loaded data set won't match the hardcoded one for
/// known models.
enum PricingHardcoded {
    static let fallback: PricingDataSet = PricingDataSet(
        schemaVersion: 1,
        updatedAt: "2026-05-29",
        calculationVersion: 5,
        providers: PricingDataSet.Providers(
            codex: codex,
            claude: claude,
            gemini: gemini,
            grok: grok,
            antigravity: antigravity
        )
    )

    private static let codex = PricingDataSet.ProviderTable<PricingDataSet.CodexEntry>(
        displayName: "OpenAI",
        models: [
            "gpt-5":               .init(input: 1.25e-6, output: 1e-5,    cacheRead: 1.25e-7),
            "gpt-5-codex":         .init(input: 1.25e-6, output: 1e-5,    cacheRead: 1.25e-7),
            "gpt-5-mini":          .init(input: 2.5e-7,  output: 2e-6,    cacheRead: 2.5e-8),
            "gpt-5-nano":          .init(input: 5e-8,    output: 4e-7,    cacheRead: 5e-9),
            "gpt-5-pro":           .init(input: 1.5e-5,  output: 1.2e-4,  cacheRead: nil),
            "gpt-5.1":             .init(input: 1.25e-6, output: 1e-5,    cacheRead: 1.25e-7),
            "gpt-5.1-codex":       .init(input: 1.25e-6, output: 1e-5,    cacheRead: 1.25e-7),
            "gpt-5.1-codex-max":   .init(input: 1.25e-6, output: 1e-5,    cacheRead: 1.25e-7),
            "gpt-5.1-codex-mini":  .init(input: 2.5e-7,  output: 2e-6,    cacheRead: 2.5e-8),
            "gpt-5.2":             .init(input: 1.75e-6, output: 1.4e-5,  cacheRead: 1.75e-7),
            "gpt-5.2-codex":       .init(input: 1.75e-6, output: 1.4e-5,  cacheRead: 1.75e-7),
            "gpt-5.2-pro":         .init(input: 2.1e-5,  output: 1.68e-4, cacheRead: nil),
            "gpt-5.3-codex":       .init(input: 1.75e-6, output: 1.4e-5,  cacheRead: 1.75e-7),
            "gpt-5.3-codex-spark": .init(input: 0,       output: 0,       cacheRead: 0,
                                         displayLabel: "Research Preview"),
            "gpt-5.4":             .init(input: 2.5e-6,  output: 1.5e-5,  cacheRead: 2.5e-7),
            "gpt-5.4-mini":        .init(input: 7.5e-7,  output: 4.5e-6,  cacheRead: 7.5e-8),
            "gpt-5.4-nano":        .init(input: 2e-7,    output: 1.25e-6, cacheRead: 2e-8),
            "gpt-5.4-pro":         .init(input: 3e-5,    output: 1.8e-4,  cacheRead: nil),
            "gpt-5.5":             .init(input: 5e-6,    output: 3e-5,    cacheRead: 5e-7),
            "gpt-5.5-pro":         .init(input: 3e-5,    output: 1.8e-4,  cacheRead: nil)
        ]
    )

    private static let claude = PricingDataSet.ProviderTable<PricingDataSet.ClaudeEntry>(
        displayName: "Anthropic",
        models: [
            "claude-haiku-4-5-20251001": .init(
                input: 1e-6, output: 5e-6,
                cacheCreation: 1.25e-6, cacheRead: 1e-7),
            "claude-haiku-4-5": .init(
                input: 1e-6, output: 5e-6,
                cacheCreation: 1.25e-6, cacheRead: 1e-7),
            "claude-opus-4-5-20251101": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-opus-4-5": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-opus-4-6-20260205": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-opus-4-6": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-opus-4-7": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-opus-4-8": .init(
                input: 5e-6, output: 2.5e-5,
                cacheCreation: 6.25e-6, cacheRead: 5e-7),
            "claude-sonnet-4-5": .init(
                input: 3e-6, output: 1.5e-5,
                cacheCreation: 3.75e-6, cacheRead: 3e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 6e-6, outputAboveThreshold: 2.25e-5,
                cacheCreationAboveThreshold: 7.5e-6, cacheReadAboveThreshold: 6e-7),
            "claude-sonnet-4-6": .init(
                input: 3e-6, output: 1.5e-5,
                cacheCreation: 3.75e-6, cacheRead: 3e-7),
            "claude-sonnet-4-5-20250929": .init(
                input: 3e-6, output: 1.5e-5,
                cacheCreation: 3.75e-6, cacheRead: 3e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 6e-6, outputAboveThreshold: 2.25e-5,
                cacheCreationAboveThreshold: 7.5e-6, cacheReadAboveThreshold: 6e-7),
            "claude-opus-4-20250514": .init(
                input: 1.5e-5, output: 7.5e-5,
                cacheCreation: 1.875e-5, cacheRead: 1.5e-6),
            "claude-opus-4-1": .init(
                input: 1.5e-5, output: 7.5e-5,
                cacheCreation: 1.875e-5, cacheRead: 1.5e-6),
            "claude-sonnet-4-20250514": .init(
                input: 3e-6, output: 1.5e-5,
                cacheCreation: 3.75e-6, cacheRead: 3e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 6e-6, outputAboveThreshold: 2.25e-5,
                cacheCreationAboveThreshold: 7.5e-6, cacheReadAboveThreshold: 6e-7)
        ]
    )

    private static let gemini = PricingDataSet.ProviderTable<PricingDataSet.GeminiEntry>(
        displayName: "Google Gemini",
        models: [
            "gemini-2.5-pro": .init(
                input: 1.25e-6, output: 1e-5, cacheRead: 3.1e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 2.5e-6, outputAboveThreshold: 1.5e-5,
                cacheReadAboveThreshold: 6.25e-7),
            "gemini-2.5-flash": .init(input: 3e-7,  output: 2.5e-6, cacheRead: 7.5e-8),
            "gemini-2.5-flash-lite": .init(input: 1e-7,  output: 4e-7,  cacheRead: 2.5e-8),
            "gemini-3-pro": .init(
                input: 2e-6, output: 1.2e-5, cacheRead: 5e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 4e-6, outputAboveThreshold: 1.8e-5,
                cacheReadAboveThreshold: 1e-6),
            "gemini-3-pro-preview": .init(
                input: 2e-6, output: 1.2e-5, cacheRead: 5e-7,
                thresholdTokens: 200_000,
                inputAboveThreshold: 4e-6, outputAboveThreshold: 1.8e-5,
                cacheReadAboveThreshold: 1e-6),
            "gemini-3-flash": .init(input: 3.5e-7, output: 2.8e-6, cacheRead: 8.75e-8),
            "gemini-3-flash-lite": .init(input: 1.25e-7, output: 5e-7, cacheRead: 3.1e-8)
        ]
    )

    private static let grok = PricingDataSet.ProviderTable<PricingDataSet.GrokEntry>(
        displayName: "xAI Grok",
        models: [
            "grok-build":       .init(input: 1e-6,    output: 2e-6,    cacheRead: nil),
            "grok-build-0.1":   .init(input: 1e-6,    output: 2e-6,    cacheRead: nil),
            "grok-4":           .init(input: 3e-6,    output: 1.5e-5,  cacheRead: 7.5e-7),
            "grok-4-fast":      .init(input: 2e-7,    output: 5e-7,    cacheRead: 5e-8),
            "grok-4.1-fast":    .init(input: 2e-7,    output: 5e-7,    cacheRead: 5e-8),
            "grok-4.3":         .init(input: 1.25e-6, output: 2.5e-6,  cacheRead: 3.1e-7),
            "grok-4.20":        .init(input: 2e-6,    output: 6e-6,    cacheRead: 2e-7),
            "grok-3":           .init(input: 3e-6,    output: 1.5e-5,  cacheRead: 7.5e-7),
            "grok-3-mini":      .init(input: 3e-7,    output: 5e-7,    cacheRead: 7.5e-8),
            "grok-code-fast-1": .init(input: 2e-7,    output: 1.5e-6,  cacheRead: 2e-8)
        ]
    )

    private static let antigravity = PricingDataSet.ProviderTable<PricingDataSet.AntigravityEntry>(
        displayName: "Google AntiGravity (shadow rates)",
        models: [
            "antigravity-default": .init(
                input: 3e-6, output: 1.5e-5,
                cacheRead: 3e-7, cacheCreation: 3.75e-6,
                displayLabel: "Sonnet-rate est."),
            "antigravity-claude-sonnet": .init(
                input: 3e-6, output: 1.5e-5,
                cacheRead: 3e-7, cacheCreation: 3.75e-6),
            "antigravity-claude-opus": .init(
                input: 5e-6, output: 2.5e-5,
                cacheRead: 5e-7, cacheCreation: 6.25e-6),
            "antigravity-claude-haiku": .init(
                input: 1e-6, output: 5e-6,
                cacheRead: 1e-7, cacheCreation: 1.25e-6),
            "antigravity-gemini-pro": .init(
                input: 1.25e-6, output: 1e-5,
                cacheRead: 3.1e-7, cacheCreation: 0),
            "antigravity-gemini-flash": .init(
                input: 3e-7, output: 2.5e-6,
                cacheRead: 7.5e-8, cacheCreation: 0)
        ]
    )
}
