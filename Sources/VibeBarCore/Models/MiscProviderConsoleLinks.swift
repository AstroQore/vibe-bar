import Foundation

/// Where a misc provider's credential is issued, given how that instance
/// is configured.
///
/// `ToolType.statusPageURL` holds one fixed URL per tool, which is wrong
/// for the providers that ship two consoles behind one card: a Z.ai
/// instance set to China mainland was still sent to www.z.ai, and a
/// MiniMax China instance to platform.minimax.io, so the "Open console"
/// link landed on a site that does not hold the key the card is asking
/// for. This picks by the instance's Region setting instead, and offers
/// both when the region is on "Auto" — either console could be the one
/// that issued the key.
///
/// Lives in Core rather than beside the SwiftUI row so the choice is
/// testable without a view.
public enum MiscProviderConsole {
    public struct Link: Equatable, Sendable, Identifiable {
        /// Button copy, naming the destination rather than saying
        /// "console" for the providers whose page is a product site or a
        /// settings screen.
        public let title: String
        public let url: URL

        public var id: String { url.absoluteString }

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    /// One link for most providers, two when a region-aware provider is
    /// left on "Auto". Never empty for a misc-page provider.
    public static func links(for tool: ToolType, settings: MiscProviderSettings) -> [Link] {
        switch tool {
        case .zai:
            return zaiLinks(region: settings.region)
        case .minimax:
            return minimaxLinks(region: settings.region)
        case .alibaba:
            return alibabaLinks(region: settings.region, tokenPlan: false)
        case .alibabaTokenPlan:
            return alibabaLinks(region: settings.region, tokenPlan: true)
        default:
            return [Link(title: defaultTitle(for: tool), url: defaultURL(for: tool))]
        }
    }

    // MARK: - Region-aware providers

    /// Keys minted on z.ai do not work on open.bigmodel.cn and vice
    /// versa, which is the whole reason the Region picker exists.
    private static func zaiLinks(region: String?) -> [Link] {
        let global = Link(title: "Open z.ai API keys", url: URL(string: "https://z.ai/manage-apikey/apikey-list")!)
        let mainland = Link(title: "Open open.bigmodel.cn", url: URL(string: "https://open.bigmodel.cn/usercenter/apikeys")!)
        switch normalized(region) {
        case "global":       return [global]
        case "bigmodel-cn":  return [mainland]
        default:             return [global, mainland]   // Auto
        }
    }

    private static func minimaxLinks(region: String?) -> [Link] {
        let global = Link(title: "Open platform.minimax.io", url: URL(string: "https://platform.minimax.io/")!)
        let mainland = Link(title: "Open platform.minimaxi.com", url: URL(string: "https://platform.minimaxi.com/")!)
        // Matches `MiniMaxRegion.resolve`: only the explicit mainland
        // spellings pin the China host; everything else starts Global.
        switch normalized(region) {
        case "cn", "china", "china-mainland", "cn-beijing":
            return [mainland]
        default:
            return [global]
        }
    }

    /// Bailian's two consoles are a different Aliyun account surface each,
    /// so an instance pinned to a region must not offer the other one.
    private static func alibabaLinks(region: String?, tokenPlan: Bool) -> [Link] {
        let international = Link(
            title: "Open Model Studio console",
            url: tokenPlan
                ? URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1?tab=plan#/efm/subscription/token-plan")!
                : URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/detail")!
        )
        let mainland = Link(
            title: "Open Bailian console",
            url: tokenPlan
                ? URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
                : URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!
        )
        // Same spellings `AlibabaRegion.resolve` accepts.
        switch normalized(region) {
        case "ap-southeast-1", "intl", "international":
            return [international]
        case "cn-beijing", "cn", "china":
            return [mainland]
        default:
            return [mainland, international]   // Auto
        }
    }

    private static func normalized(_ region: String?) -> String {
        region?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    // MARK: - Everything else

    /// `statusPageURL` is already the console for every misc provider
    /// except Copilot, whose entry there is GitHub's *status* page rather
    /// than anywhere a token can be obtained.
    static func defaultURL(for tool: ToolType) -> URL {
        switch tool {
        case .copilot:
            return URL(string: "https://github.com/settings/copilot")!
        default:
            return tool.statusPageURL
        }
    }

    static func defaultTitle(for tool: ToolType) -> String {
        switch tool {
        case .alibaba, .alibabaTokenPlan:         return "Open Bailian console"
        case .copilot:                            return "Open GitHub Copilot settings"
        case .zai:                                return "Open z.ai"
        case .minimax:                            return "Open platform.minimax.io"
        case .kimi:                               return "Open kimi.com"
        case .mimo:                               return "Open platform.xiaomimimo.com"
        case .iflytek:                            return "Open maas.xfyun.cn"
        case .tencentHunyuan, .tencentTokenPlan:  return "Open Tencent Cloud console"
        case .volcengine:                         return "Open Ark console"
        case .volcengineAgentPlan:                return "Open Agent Plan console"
        case .baiduQianfan:                       return "Open Qianfan console"
        case .openCodeGo:                         return "Open opencode.ai"
        case .kilo:                               return "Open app.kilo.ai"
        case .kiro:                               return "Open kiro.dev"
        case .ollama:                             return "Open ollama.com"
        case .openRouter:                         return "Open openrouter.ai"
        case .warp:                               return "Open app.warp.dev"
        case .codex, .claude, .gemini, .antigravity, .grok, .cursor:
            return "Open status page"
        }
    }
}
