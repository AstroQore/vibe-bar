import AppKit
import VibeBarCore

/// Explicit, read-only diagnostic for an unmerged build. Starts no scheduler,
/// menu item or MCP server and never prints credentials or conversation text.
@MainActor
enum ChatGPTChatProbe {
    static func run() async -> Int32 {
        var config = ChatGPTChatSettings()
        config.enabled = true
        config.trackProModels = CommandLine.arguments.contains("--pro")
        let settings = config
        let fallback: ChatGPTChatQuotaAdapter.WebFallback?
        if CommandLine.arguments.contains("--cookie-only") {
            fallback = nil
        } else {
            fallback = { account, settings, cookie in
                try await ChatGPTChatWebFetcher.fetch(account: account, settings: settings, cookieHeader: cookie)
            }
        }
        let adapter = ChatGPTChatQuotaAdapter(webFallback: fallback, settings: { settings }, cookies: {
            if CommandLine.arguments.contains("--webview-only") { throw QuotaError.noCredential }
            return try OpenAIWebCookieStore.readCookieHeader()
        })
        do {
            let result = try await adapter.fetch(for: AccountIdentity(id: "chat-probe", tool: .chatgptChat, source: .webCookie))
            struct Output: Encodable {
                let transport: String
                let buckets: [MCPQuotaBucketDTO]
                let plan: String?
                let history: MCPChatAllowanceDTO?
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Output(transport: result.chatGPTChat?.transport ?? "unknown",
                buckets: result.buckets.map { MCPQuotaBucketDTO(bucket: $0, forecast: nil) },
                plan: result.plan, history: result.chatGPTChat.map(MCPChatAllowanceDTO.init)))
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch {
            let message = (error as? QuotaError)?.logSafeMessage ?? "ChatGPT Chat connection failed."
            print(message)
            return 1
        }
    }
}
