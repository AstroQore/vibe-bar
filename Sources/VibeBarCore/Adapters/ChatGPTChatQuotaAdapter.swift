import Foundation

public struct ChatGPTChatQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .chatgptChat
    public typealias WebFallback = @Sendable (AccountIdentity, ChatGPTChatSettings, String?) async throws -> AccountQuota
    private let fallback: WebFallback?
    private let settings: @Sendable () -> ChatGPTChatSettings
    private let cookies: @Sendable () throws -> String
    private let codexCredential: @Sendable () throws -> CodexCredential

    public init(webFallback: WebFallback? = nil,
                settings: @escaping @Sendable () -> ChatGPTChatSettings = {
                    ((try? VibeBarLocalStore.readJSON(AppSettings.self, from: VibeBarLocalStore.settingsURL)) ?? .default).chatGPTChat
                }, cookies: @escaping @Sendable () throws -> String = {
                    guard let value = OpenAIWebCookieStore.cachedCookieHeader() else { throw QuotaError.noCredential }
                    return value
                },
                // The Codex CLI's OAuth material first, the Keychain mirror
                // second — the same order the Codex quota reads it in.
                codexCredential: @escaping @Sendable () throws -> CodexCredential = {
                    if let oauth = try? CodexCredentialReader.loadFromOAuth() { return oauth }
                    return try CodexCredentialReader.loadFromCLI()
                }) {
        fallback = webFallback
        self.settings = settings
        self.cookies = cookies
        self.codexCredential = codexCredential
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let settings = settings().sanitized
        guard settings.enabled else { throw QuotaError.noCredential }
        // A Codex login is a Chat login: its bearer reads the same
        // allowances, so someone who never opened the web login window is
        // not sent to it. Anything but a rate limit falls through to the
        // cookie and WebView paths, which read the same account.
        if let credential = try? codexCredential() {
            let transport = ChatGPTChatOAuthTransport(credential: credential)
            defer { transport.close() }
            do { return try await ChatGPTChatClient(transport: transport).fetch(account: account, settings: settings) }
            catch {
                try Task.checkCancellation()
                if let error = error as? QuotaError, error == .rateLimited { throw error }
            }
        }
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
