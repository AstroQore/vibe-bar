import Foundation

public enum PrimaryProviderRoute: String, CaseIterable, Identifiable, Sendable {
    case openAICLI
    case openAIOAuth
    case openAIBrowserCookies
    case openAIWebViewCookies
    case claudeBrowserCookies
    case claudeWebViewCookies
    case claudeOAuth
    case claudeCLI

    public var id: String { rawValue }

    public var provider: ToolType {
        switch self {
        case .openAICLI, .openAIOAuth, .openAIBrowserCookies, .openAIWebViewCookies:
            return .codex
        case .claudeBrowserCookies, .claudeWebViewCookies, .claudeOAuth, .claudeCLI:
            return .claude
        }
    }

    public var label: String {
        switch self {
        case .openAICLI: return "CLI"
        case .openAIOAuth: return "OAuth"
        case .openAIBrowserCookies: return "Chrome/Safari cookies"
        case .openAIWebViewCookies: return "WebView cookies"
        case .claudeBrowserCookies: return "Chrome/Safari cookies"
        case .claudeWebViewCookies: return "WebView cookies"
        case .claudeOAuth: return "OAuth"
        case .claudeCLI: return "CLI"
        }
    }

    public static func routes(for provider: ToolType) -> [PrimaryProviderRoute] {
        allCases.filter { $0.provider == provider }
    }
}

public enum PrimaryProviderRouteHealthStatus: String, Sendable, Equatable {
    case ok
    case missing
    case blocked
    case failed

    public var isHealthy: Bool { self == .ok }
}

public struct PrimaryProviderRouteHealth: Identifiable, Sendable, Equatable {
    public let route: PrimaryProviderRoute
    public let status: PrimaryProviderRouteHealthStatus
    public let detail: String
    public let checkedAt: Date

    public var id: PrimaryProviderRoute { route }

    public init(
        route: PrimaryProviderRoute,
        status: PrimaryProviderRouteHealthStatus,
        detail: String,
        checkedAt: Date = Date()
    ) {
        self.route = route
        self.status = status
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public enum PrimaryProviderRouteHealthChecker {
    public static func checkAll(now: Date = Date()) -> [PrimaryProviderRoute: PrimaryProviderRouteHealth] {
        Dictionary(
            uniqueKeysWithValues: PrimaryProviderRoute.allCases.map { route in
                (route, check(route, now: now))
            }
        )
    }

    public static func check(_ route: PrimaryProviderRoute, now: Date = Date()) -> PrimaryProviderRouteHealth {
        switch route {
        case .openAICLI:
            return credentialHealth(route: route, now: now) {
                _ = try CodexCredentialReader.loadFromCLI()
            }
        case .openAIOAuth:
            return credentialHealth(route: route, now: now) {
                _ = try CodexCredentialReader.loadFromOAuth()
            }
        case .openAIBrowserCookies:
            return cookieHealth(
                route: route,
                result: OpenAIWebCookieStore.storageState(source: .browser),
                now: now
            )
        case .openAIWebViewCookies:
            return cookieHealth(
                route: route,
                result: OpenAIWebCookieStore.storageState(source: .webView),
                now: now
            )
        case .claudeBrowserCookies:
            return cookieHealth(
                route: route,
                result: ClaudeWebCookieStore.storageState(source: .browser),
                now: now
            )
        case .claudeWebViewCookies:
            return cookieHealth(
                route: route,
                result: ClaudeWebCookieStore.storageState(source: .webView),
                now: now
            )
        case .claudeOAuth:
            return credentialHealth(route: route, now: now) {
                _ = try ClaudeCredentialReader.loadFromOAuth()
            }
        case .claudeCLI:
            return credentialHealth(route: route, now: now) {
                _ = try ClaudeCredentialReader.loadFromCLI()
            }
        }
    }

    private static func credentialHealth(
        route: PrimaryProviderRoute,
        now: Date,
        _ load: () throws -> Void
    ) -> PrimaryProviderRouteHealth {
        do {
            try load()
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: "Credentials available",
                checkedAt: now
            )
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .blocked,
                detail: "Keychain locked",
                checkedAt: now
            )
        } catch let error as QuotaError where error == .noCredential || error == .needsLogin {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .missing,
                detail: "No credential found",
                checkedAt: now
            )
        } catch {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .failed,
                detail: "Could not read credential",
                checkedAt: now
            )
        }
    }

    private static func cookieHealth(
        route: PrimaryProviderRoute,
        result: SecureCookieHeaderStore.LoadResult,
        now: Date
    ) -> PrimaryProviderRouteHealth {
        switch result {
        case .found:
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: "Saved in Keychain",
                checkedAt: now
            )
        case .missing:
            return PrimaryProviderRouteHealth(
                route: route,
                status: .missing,
                detail: "No saved cookie",
                checkedAt: now
            )
        case .temporarilyUnavailable:
            return PrimaryProviderRouteHealth(
                route: route,
                status: .blocked,
                detail: "Keychain locked",
                checkedAt: now
            )
        case .invalid:
            return PrimaryProviderRouteHealth(
                route: route,
                status: .failed,
                detail: "Invalid cookie data",
                checkedAt: now
            )
        }
    }
}
