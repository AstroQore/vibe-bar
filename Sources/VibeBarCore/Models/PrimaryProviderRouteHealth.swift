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
        case .antigravityLocalProbe: return "Local Antigravity / agy"
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
        check(PrimaryProviderRoute.allCases, now: now)
    }

    public static func check(
        _ routes: [PrimaryProviderRoute],
        now: Date = Date()
    ) -> [PrimaryProviderRoute: PrimaryProviderRouteHealth] {
        Dictionary(
            uniqueKeysWithValues: routes.map { route in
                (route, check(route, now: now))
            }
        )
    }

    /// Same answers, computed off the calling actor.
    ///
    /// Every route here does blocking work — Keychain round trips, credential
    /// file reads, and for AntiGravity a `/bin/ps` spawn drained
    /// synchronously — and the App re-checks routes on every refresh. None of
    /// that belongs on the main actor while the popover is drawing.
    public static func checkOffActor(
        _ routes: [PrimaryProviderRoute],
        now: Date = Date()
    ) async -> [PrimaryProviderRoute: PrimaryProviderRouteHealth] {
        await Task.detached(priority: .userInitiated) {
            check(routes, now: now)
        }.value
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
        let dataRoot = URL(fileURLWithPath: RealHomeDirectory.path)
            .appendingPathComponent(".gemini/antigravity")
        return antigravityLocalProbeHealth(
            route: route,
            languageServerRunning: antigravityLanguageServerIsRunning(now: now),
            cliAvailable: AntigravityCLIQuotaFetcher.resolveBinary() != nil,
            hasLocalData: FileManager.default.fileExists(atPath: dataRoot.path),
            now: now
        )
    }

    /// Separates the AntiGravity availability semantics from process and file
    /// probing so app, CLI, and stale-cache states remain testable. Cached
    /// quota may still render for continuity, but it is not reported healthy
    /// when neither the app language server nor `agy` can refresh it.
    static func antigravityLocalProbeHealth(
        route: PrimaryProviderRoute = .antigravityLocalProbe,
        languageServerRunning: Bool,
        cliAvailable: Bool = false,
        hasLocalData: Bool,
        now: Date
    ) -> PrimaryProviderRouteHealth {
        if languageServerRunning {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: "Local LSP running",
                checkedAt: now
            )
        }
        if cliAvailable {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .ok,
                detail: "agy CLI available",
                checkedAt: now
            )
        }
        if hasLocalData {
            return PrimaryProviderRouteHealth(
                route: route,
                status: .failed,
                detail: "Cached data only; live quota unavailable",
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

    /// How long a language-server probe result is reused.
    ///
    /// The probe spawns `/bin/ps -ax`, drains its whole stdout and waits for it
    /// to exit — tens of milliseconds of blocking work for a question whose
    /// answer is "is AntiGravity open". Route health is re-checked on every
    /// refresh and on every per-provider refresh, so without a TTL a Gemini
    /// card refresh alone spawned it twice. A language server does not start
    /// and stop inside a minute of itself, and a stale "running" reading only
    /// delays the switch to the cached-data wording by that minute.
    private static let languageServerProbeTTL: TimeInterval = 60
    private static let languageServerProbeLock = NSLock()
    private nonisolated(unsafe) static var languageServerProbe: (checkedAt: Date, isRunning: Bool)?

    static func antigravityLanguageServerIsRunning(
        now: Date = Date(),
        probe: () -> Bool = probeAntigravityLanguageServer
    ) -> Bool {
        languageServerProbeLock.lock()
        let cached = languageServerProbe
        languageServerProbeLock.unlock()
        if let cached, now.timeIntervalSince(cached.checkedAt) < languageServerProbeTTL {
            return cached.isRunning
        }

        let isRunning = probe()
        languageServerProbeLock.lock()
        languageServerProbe = (now, isRunning)
        languageServerProbeLock.unlock()
        return isRunning
    }

    /// Drops the cached probe result. Test hook, and the honest thing to call
    /// if a future caller learns AntiGravity just launched.
    public static func invalidateLanguageServerProbeCache() {
        languageServerProbeLock.lock()
        languageServerProbe = nil
        languageServerProbeLock.unlock()
    }

    private static func probeAntigravityLanguageServer() -> Bool {
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
