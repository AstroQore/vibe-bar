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
    case geminiBrowserCookies
    case antigravityLocalProbe
    case grokAuthJSON
    case grokBrowserCookies

    public var id: String { rawValue }

    public var provider: ToolType {
        switch self {
        case .openAICLI, .openAIOAuth, .openAIBrowserCookies, .openAIWebViewCookies:
            return .codex
        case .claudeBrowserCookies, .claudeWebViewCookies, .claudeOAuth, .claudeCLI:
            return .claude
        case .geminiBrowserCookies:
            return .gemini
        case .antigravityLocalProbe:
            return .antigravity
        case .grokAuthJSON, .grokBrowserCookies:
            return .grok
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
        case .geminiBrowserCookies: return "Chrome/Safari cookies"
        case .antigravityLocalProbe: return "Local language server"
        case .grokAuthJSON: return "~/.grok/auth.json"
        case .grokBrowserCookies: return "Chrome/Safari cookies"
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
        case .geminiBrowserCookies:
            return cookieHealth(
                route: route,
                result: GeminiWebCookieStore.storageState(source: .browser),
                now: now
            )
        case .antigravityLocalProbe:
            return antigravityLocalProbeHealth(route: route, now: now)
        case .grokAuthJSON:
            return grokAuthJSONHealth(route: route, now: now)
        case .grokBrowserCookies:
            return cookieHealth(
                route: route,
                result: GrokWebCookieStore.storageState(source: .browser),
                now: now
            )
        }
    }

    private static func antigravityLocalProbeHealth(
        route: PrimaryProviderRoute,
        now: Date
    ) -> PrimaryProviderRouteHealth {
        if antigravityLanguageServerIsRunning() {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: "Local LSP running",
                checkedAt: now
            )
        }
        let dataRoot = URL(fileURLWithPath: RealHomeDirectory.path)
            .appendingPathComponent(".gemini/antigravity")
        if FileManager.default.fileExists(atPath: dataRoot.path) {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .missing,
                detail: "Local data found; LSP not running",
                checkedAt: now
            )
        }
        return PrimaryProviderRouteHealth(
            route: route,
            status: .missing,
            detail: "No local Antigravity data",
            checkedAt: now
        )
    }

    private static func grokAuthJSONHealth(
        route: PrimaryProviderRoute,
        now: Date
    ) -> PrimaryProviderRouteHealth {
        do {
            let credentials = try GrokCredentialsStore.load()
            if let expiresAt = credentials.expiresAt, expiresAt <= now {
                return PrimaryProviderRouteHealth(
                    route: route,
                    status: .failed,
                    detail: "auth.json expired",
                    checkedAt: now
                )
            }
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: credentials.planLabel ?? "Credentials available",
                checkedAt: now
            )
        } catch let error as QuotaError where error == .noCredential || error == .needsLogin {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .missing,
                detail: "No auth.json",
                checkedAt: now
            )
        } catch {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .failed,
                detail: "Could not read auth.json",
                checkedAt: now
            )
        }
    }

    private static func antigravityLanguageServerIsRunning() -> Bool {
        guard let result = captureProcessOutput(
            executablePath: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        ), result.terminationStatus == 0 else {
            return false
        }
        let output = result.output.lowercased()
        return output.contains("language_server_macos") && output.contains("antigravity")
    }

    static func captureProcessOutput(
        executablePath: String,
        arguments: [String]
    ) -> (terminationStatus: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return (process.terminationStatus, output)
        } catch {
            return nil
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
