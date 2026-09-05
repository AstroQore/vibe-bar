import Foundation

public struct ChatGPTChatQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .chatgptChat
    public typealias WebFallback = @Sendable (AccountIdentity, ChatGPTChatSettings, String?) async throws -> AccountQuota
    private let fallback: WebFallback?
    private let settings: @Sendable () -> ChatGPTChatSettings
    private let cookies: @Sendable () throws -> String

    public init(webFallback: WebFallback? = nil,
                settings: @escaping @Sendable () -> ChatGPTChatSettings = {
                    ((try? VibeBarLocalStore.readJSON(AppSettings.self, from: VibeBarLocalStore.settingsURL)) ?? .default).chatGPTChat
                }, cookies: @escaping @Sendable () throws -> String = {
                    guard let value = OpenAIWebCookieStore.cachedCookieHeader() else { throw QuotaError.noCredential }
                    return value
                }) {
        fallback = webFallback
        self.settings = settings
        self.cookies = cookies
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = settings().sanitized
        guard settings.enabled else { throw QuotaError.noCredential }
        let cookie = try? cookies()
        if let cookie {
            let transport = ChatGPTChatCookieTransport(cookieHeader: cookie)
            defer { transport.close() }
            do { return try await ChatGPTChatClient(transport: transport).fetch(account: account, settings: settings) }
            catch {
                try Task.checkCancellation()
                if let error = error as? QuotaError, error == .rateLimited { throw error }
                guard fallback != nil else { throw error }
            }
        }
        guard let fallback else { throw QuotaError.needsLogin }
        return try await fallback(account, settings, cookie)
    }
}
