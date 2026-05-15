import AppKit
import WebKit
import VibeBarCore

/// Background cookie refresher for misc providers whose console
/// session cookies expire within hours (Tencent `skey`, Volcengine
/// `csrfToken` + sso tickets, …).
///
/// Pattern: load the provider's authenticated console homepage in a
/// hidden `WKWebView`, let the page's own JS run its silent
/// session-refresh / keepalive flow, then snapshot the freshened
/// cookies and persist them via `CookieHeaderCache`. The user never
/// sees a window — the WebView is offscreen and discarded after each
/// refresh.
///
/// Why this works without reverse-engineering `/touch` or
/// `/refresh`-style endpoints: the page bring-up itself triggers the
/// keepalive (which is exactly what keeps a regular user logged in
/// for weeks at a time). We just borrow the browser engine.
///
/// The data store is shared with `MiscWebLoginController`, so the
/// user's first-time login (skey + long-lived ticket cookies) acts
/// as the bootstrap state. We additionally inject anything cached in
/// `CookieHeaderCache` in case the user came in via SweetCookieKit
/// auto-import rather than the in-app webview.
@MainActor
final class HiddenCookieRefresher {
    static let shared = HiddenCookieRefresher()

    struct Config {
        let tool: ToolType
        let refreshURL: URL
        /// Domain suffixes whose cookies are considered relevant for
        /// the captured header. Matches both bare domain and
        /// subdomains (`tencent.com` matches `cloud.tencent.com`).
        let cookieDomainSuffixes: [String]
        /// Cookie names to retain in the captured header. Empty set
        /// keeps the entire matching jar (used for Tencent/Volcengine
        /// because their HttpOnly session helpers can't be enumerated
        /// from JS).
        let requiredCookieNames: Set<String>
        /// Seconds to wait after `didFinish` before snapshotting
        /// cookies. Console JS typically fires its silent refresh in
        /// the first 1-3s of bring-up; some sites kick a second
        /// /idle ping after a beat.
        let postLoadWait: TimeInterval
    }

    /// Resolve a Config for each tool that needs background refresh.
    /// Tools not listed here are skipped (e.g. MiMo, iFlytek — their
    /// cookies live for days and don't need this).
    enum Registry {
        static func config(for tool: ToolType) -> Config? {
            switch tool {
            case .tencentHunyuan:
                return Config(
                    tool: .tencentHunyuan,
                    refreshURL: URL(string: "https://cloud.tencent.com/account/info")!,
                    cookieDomainSuffixes: ["tencent.com", "qq.com", "qcloud.com"],
                    requiredCookieNames: [],
                    postLoadWait: 8
                )
            case .volcengine:
                return Config(
                    tool: .volcengine,
                    refreshURL: URL(string: "https://console.volcengine.com/iam/")!,
                    cookieDomainSuffixes: ["volcengine.com"],
                    requiredCookieNames: [],
                    postLoadWait: 8
                )
            case .alibaba:
                // Alibaba's bailian/modelstudio console keeps the
                // login ticket alive only when the SPA loads — its
                // /tool/user/info.json keepalive fires inside the
                // Coding Plan widget bring-up. Loading the cn-beijing
                // dashboard URL covers most users; the cookie path
                // adapter falls back to the intl host on its own.
                return Config(
                    tool: .alibaba,
                    refreshURL: URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!,
                    cookieDomainSuffixes: ["aliyun.com", "alibabacloud.com"],
                    requiredCookieNames: [],
                    postLoadWait: 10
                )
            default:
                return nil
            }
        }

        static let supportedTools: [ToolType] = [.tencentHunyuan, .volcengine, .alibaba]
    }

    private var inflight: [ToolType: Task<Bool, Never>] = [:]
    private var pinnedDelegates: [ObjectIdentifier: NavDelegate] = [:]
    private var pinnedWebViews: [ObjectIdentifier: WKWebView] = [:]
    private var pinnedDataStores: [ObjectIdentifier: WKWebsiteDataStore] = [:]

    /// Trigger a silent refresh for `tool`. Iterates the user's
    /// browser-origin cookie slots and refreshes each one. Manual
    /// slots are skipped — auto-refresh only re-runs a session the
    /// user originally captured via browser import or the in-app web
    /// login. Returns true if at least one slot's header changed.
    /// Concurrent refreshes for the same tool are coalesced.
    @discardableResult
    func refresh(_ tool: ToolType) async -> Bool {
        if let task = inflight[tool] { return await task.value }
        guard let config = Registry.config(for: tool) else { return false }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performRefresh(config)
        }
        inflight[tool] = task
        let result = await task.value
        inflight[tool] = nil
        return result
    }

    private func performRefresh(_ config: Config) async -> Bool {
        let slots = MiscCookieSlotStore.slots(for: config.tool)
            .filter { $0.origin != .manual }
        guard !slots.isEmpty else {
            SafeLog.info("HiddenCookieRefresher skip tool=\(config.tool.rawValue) — no browser-origin slots")
            return false
        }

        var anyChanged = false
        for slot in slots {
            if await performRefreshForSlot(config, slot: slot) {
                anyChanged = true
            }
        }
        if anyChanged {
            NotificationCenter.default.post(
                name: .cookiesRefreshed,
                object: nil,
                userInfo: ["tool": config.tool.rawValue]
            )
        }
        return anyChanged
    }

    private func performRefreshForSlot(_ config: Config, slot: MiscCookieSlot) async -> Bool {
        let beforeHeader = slot.cookieHeader
        let beforeFingerprint = headerFingerprint(beforeHeader)
        SafeLog.info(
            "HiddenCookieRefresher start tool=\(config.tool.rawValue) slot=\(slot.id.uuidString.prefix(8)) beforeLen=\(beforeHeader.count) fp=\(beforeFingerprint)"
        )

        // Fresh ephemeral data store per slot so cookies from one
        // session can't leak into another. The default
        // `WKWebsiteDataStore` is process-shared, which is the wrong
        // shape once we have multiple stacked sessions per provider.
        let dataStore = WKWebsiteDataStore.nonPersistent()

        if !beforeHeader.isEmpty {
            await injectCookies(beforeHeader, into: dataStore.httpCookieStore, config: config)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let webViewConfig = WKWebViewConfiguration()
            webViewConfig.websiteDataStore = dataStore
            webViewConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
            webViewConfig.defaultWebpagePreferences.allowsContentJavaScript = true

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                                    configuration: webViewConfig)
            webView.customUserAgent = Self.safariUserAgent
            let key = ObjectIdentifier(webView)

            let delegate = NavDelegate { [weak self] result in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    defer {
                        self.pinnedDelegates.removeValue(forKey: key)
                        self.pinnedWebViews.removeValue(forKey: key)
                        self.pinnedDataStores.removeValue(forKey: key)
                    }
                    switch result {
                    case .finished:
                        // Sleep on the actor so we don't block the
                        // continuation; the inflight task keeps the
                        // WebView retained until we're done.
                        try? await Task.sleep(nanoseconds: UInt64(config.postLoadWait * 1_000_000_000))
                        let captured = await self.captureAndUpdateSlot(
                            config,
                            slot: slot,
                            store: dataStore.httpCookieStore,
                            beforeFingerprint: beforeFingerprint
                        )
                        continuation.resume(returning: captured)
                    case .failed(let err):
                        SafeLog.warn(
                            "HiddenCookieRefresher load-failed tool=\(config.tool.rawValue) slot=\(slot.id.uuidString.prefix(8)) err=\(err.localizedDescription)"
                        )
                        continuation.resume(returning: false)
                    }
                }
            }
            webView.navigationDelegate = delegate
            self.pinnedDelegates[key] = delegate
            self.pinnedWebViews[key] = webView
            self.pinnedDataStores[key] = dataStore

            var request = URLRequest(url: config.refreshURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            webView.load(request)
        }
    }

    private func captureAndUpdateSlot(_ config: Config,
                                      slot: MiscCookieSlot,
                                      store: WKHTTPCookieStore,
                                      beforeFingerprint: String) async -> Bool {
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }

        let header = minimizedHeader(cookies: cookies, config: config)
        guard !header.isEmpty else {
            SafeLog.warn(
                "HiddenCookieRefresher no-cookies tool=\(config.tool.rawValue) slot=\(slot.id.uuidString.prefix(8)) — page likely redirected to login"
            )
            return false
        }
        let afterFingerprint = headerFingerprint(header)
        let changed = afterFingerprint != beforeFingerprint
        SafeLog.info(
            "HiddenCookieRefresher done tool=\(config.tool.rawValue) slot=\(slot.id.uuidString.prefix(8)) afterLen=\(header.count) fp=\(afterFingerprint) changed=\(changed)"
        )
        guard changed else { return false }

        return MiscCookieSlotStore.updateHeader(
            slotID: slot.id,
            for: config.tool,
            header: header,
            sourceLabel: "Auto-refresh",
            origin: .autoRefresh
        )
    }

    private func minimizedHeader(cookies: [HTTPCookie], config: Config) -> String {
        let kept = cookies
            .filter { cookie in
                let domain = cookie.domain.lowercased()
                let stripped = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                let domainOK = config.cookieDomainSuffixes.contains { suffix in
                    let lowered = suffix.lowercased()
                    let normalized = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
                    return stripped == normalized || stripped.hasSuffix("." + normalized)
                }
                guard domainOK else { return false }
                if config.requiredCookieNames.isEmpty { return true }
                return config.requiredCookieNames.contains(cookie.name)
            }
            .sorted { $0.name < $1.name }

        var seen = Set<String>()
        var pairs: [String] = []
        for cookie in kept where seen.insert(cookie.name).inserted {
            pairs.append("\(cookie.name)=\(cookie.value)")
        }
        return pairs.joined(separator: "; ")
    }

    private func injectCookies(_ header: String,
                               into store: WKHTTPCookieStore,
                               config: Config) async {
        // Use the first listed suffix as the inject domain. WKHTTPCookieStore
        // is forgiving here — once the WebView navigates to the matching host
        // the engine re-keys cookies onto the right exact domain.
        guard let primarySuffix = config.cookieDomainSuffixes.first else { return }
        let domain = primarySuffix.hasPrefix(".") ? primarySuffix : "." + primarySuffix

        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { continue }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            guard let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: "/",
                .secure: true
            ]) else { continue }
            await withCheckedContinuation { cont in
                store.setCookie(cookie) { cont.resume() }
            }
        }
    }

    /// Hash the cookie header so we can log "did this refresh actually
    /// change anything?" without writing the secret to logs.
    nonisolated private func headerFingerprint(_ header: String) -> String {
        guard !header.isEmpty else { return "empty" }
        var hash: UInt64 = 5381
        for byte in header.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    nonisolated private static var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }
}

extension Notification.Name {
    /// Posted when `HiddenCookieRefresher` writes a freshened cookie
    /// header to `CookieHeaderCache`. `userInfo["tool"]` carries the
    /// `ToolType.rawValue`. AppDelegate listens and kicks an
    /// out-of-band `QuotaService.refresh` so the misc card flips
    /// from "Needs re-login" to live data within seconds, instead of
    /// waiting for the next `QuotaRefreshScheduler` tick.
    static let cookiesRefreshed = Notification.Name("com.astroqore.VibeBar.cookiesRefreshed")
}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    enum Outcome { case finished, failed(Error) }
    private let onComplete: (Outcome) -> Void
    private var resolved = false

    init(onComplete: @escaping (Outcome) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !resolved else { return }
        resolved = true
        onComplete(.finished)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !resolved else { return }
        resolved = true
        onComplete(.failed(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !resolved else { return }
        resolved = true
        onComplete(.failed(error))
    }
}

/// Periodic driver for `HiddenCookieRefresher`. Kicks an initial
/// refresh shortly after launch, then re-runs on a jittered ~30
/// minute cadence per tool.
@MainActor
final class CookieRefreshScheduler {
    static let shared = CookieRefreshScheduler()

    /// Minutes between background refreshes. Jittered ±20 % to avoid a
    /// detectable beat pattern.
    private static let basePeriodSeconds: TimeInterval = 30 * 60
    /// First refresh after launch. Long enough that StatusItemController
    /// has finished bringing up the popover, short enough that the
    /// initial misc-card render still gets fresh cookies.
    private static let firstRefreshDelaySeconds: TimeInterval = 60

    private var tasks: [ToolType: Task<Void, Never>] = [:]

    func start() {
        for tool in HiddenCookieRefresher.Registry.supportedTools {
            scheduleNext(for: tool, after: Self.firstRefreshDelaySeconds)
        }
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// Force an out-of-band refresh (e.g. when an adapter reports
    /// `needsLogin` and we want to retry once before surfacing the
    /// error to the user). Runs synchronously through the in-flight
    /// coalescer so two adapter retries don't fire two refreshes.
    @discardableResult
    func refreshNow(_ tool: ToolType) async -> Bool {
        await HiddenCookieRefresher.shared.refresh(tool)
    }

    private func scheduleNext(for tool: ToolType, after delay: TimeInterval) {
        tasks[tool]?.cancel()
        let jitter = Self.basePeriodSeconds * Double.random(in: -0.2...0.2)
        let next = max(60, Self.basePeriodSeconds + jitter)
        tasks[tool] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            _ = await HiddenCookieRefresher.shared.refresh(tool)
            guard !Task.isCancelled else { return }
            self?.scheduleNext(for: tool, after: next)
        }
    }
}
