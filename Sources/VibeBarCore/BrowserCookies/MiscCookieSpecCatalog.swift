import Foundation

/// `ToolType` → `MiscCookieResolver.Spec` index for the misc providers
/// whose only credential is a browser cookie jar.
///
/// The specs themselves stay on the adapters (`…QuotaAdapter.cookieSpec`)
/// — the domain list and cookie-name minimisation rules belong next to
/// the code that talks to the provider. This catalog is only the index,
/// and it exists because three callers need "the spec for this
/// `ToolType`" rather than "Kimi's spec": the Settings rows, the
/// all-providers batch browser import, and the silent re-import that
/// runs when a stored jar goes stale.
///
/// The switch is exhaustive on purpose. A new `ToolType` case fails to
/// compile here until it is classified as cookie-sourced or not, and
/// `MiscCookieSpecCatalogTests` additionally asserts every misc-page
/// provider is accounted for — a cookie provider that never made it
/// into the catalog would silently drop out of the batch import.
public enum MiscCookieSpecCatalog {
    public static func spec(for tool: ToolType) -> MiscCookieResolver.Spec? {
        switch tool {
        case .alibaba:           return AlibabaQuotaAdapter.cookieSpec
        case .alibabaTokenPlan:  return AlibabaTokenPlanQuotaAdapter.cookieSpec
        case .baiduQianfan:      return BaiduQianfanQuotaAdapter.cookieSpec
        case .cursor:            return CursorQuotaAdapter.cookieSpec
        case .iflytek:           return IFlyTekQuotaAdapter.cookieSpec
        case .kimi:              return KimiQuotaAdapter.cookieSpec
        case .mimo:              return MimoQuotaAdapter.cookieSpec
        case .ollama:            return OllamaQuotaAdapter.cookieSpec
        case .openCodeGo:        return OpenCodeGoQuotaAdapter.cookieSpec
        case .tencentHunyuan:    return TencentHunyuanQuotaAdapter.cookieSpec
        case .tencentTokenPlan:  return TencentTokenPlanQuotaAdapter.cookieSpec
        case .volcengine:        return VolcengineQuotaAdapter.cookieSpec

        // Not cookie-sourced. API key / device login / AK-SK / local
        // process probe providers, plus the primary and partial-primary
        // families, which carry their own dedicated credential paths.
        case .codex, .claude, .gemini, .antigravity, .grok,
             .copilot, .zai, .minimax, .volcengineAgentPlan,
             .kilo, .kiro, .openRouter, .warp:
            return nil
        }
    }

    public static func isCookieSourced(_ tool: ToolType) -> Bool {
        spec(for: tool) != nil
    }

    /// Cookie-sourced providers in `ToolType.allCases` declaration
    /// order, which is also the Misc page's default order.
    public static var allCookieSourcedTools: [ToolType] {
        ToolType.allCases.filter { isCookieSourced($0) }
    }

    public static var allSpecs: [MiscCookieResolver.Spec] {
        allCookieSourcedTools.compactMap { spec(for: $0) }
    }
}
