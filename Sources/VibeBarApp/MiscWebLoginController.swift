import AppKit
import WebKit
import VibeBarCore

/// In-app WebView login flow for browser-cookie misc providers whose
/// cookies can't be lifted out of the user's main browser (typically
/// because Chrome on macOS encrypted them with `v11` / app-bound
/// encryption, which our SweetCookieKit dependency can't read).
///
/// Pattern mirrors `ClaudeWebLoginController`:
/// 1. Open a window with a `WKWebView` pointed at the provider's
///    login URL.
/// 2. Let the user sign in (handles password + SSO + popup flows).
/// 3. Watch the cookie store; once the spec's required cookies are
///    present, minimise them to `name=value; …` form and persist via
///    `CookieHeaderCache.store(for:cookieHeader:sourceLabel:)`.
/// 4. Fire the `onSaved` callback so the caller can kick a refresh.
///
/// Generic on `ToolType` via `Config` — one instance per tool. Use
/// `MiscWebLoginRegistry` from `AppEnvironment` to share controllers
/// across SwiftUI re-renders.
@MainActor
final class MiscWebLoginController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    struct Config {
        let tool: ToolType
        let loginURL: URL
        /// Domain *suffixes* that scope which cookies the controller
        /// captures (e.g. `["xiaomimimo.com"]` matches both
        /// `xiaomimimo.com` and `platform.xiaomimimo.com`).
        let cookieDomainSuffixes: [String]
        /// Cookie names to retain from the WebView store. Anything not
        /// in this set is dropped before `CookieHeaderCache.store`.
        let requiredCookieNames: Set<String>
        /// Hosts the in-app browser is allowed to navigate to. Anything
        /// outside this allowlist opens in the system browser instead.
        let trustedAuthHostSuffixes: [String]
        let windowTitle: String
        let savedConfirmation: String
        let setupHint: String
    }

    private let config: Config
    private var window: NSWindow?
    private var webView: WKWebView?
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?
    private var statusLabel: NSTextField?
    private var onSaved: (() -> Void)?
    private var didSaveCookiesForCurrentWindow = false
    private let websiteDataStore = WKWebsiteDataStore.default()
    private var autofillBridges: [MiscWebLoginAutofillBridge] = []

    init(config: Config) {
        self.config = config
        super.init()
    }

    func open(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let webView = makeWebView(configuration: makeWebViewConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView
        websiteDataStore.httpCookieStore.add(self)

        let browserButton = NSButton(
            title: "Open in Browser",
            target: self,
            action: #selector(openInBrowser(_:))
        )
        browserButton.bezelStyle = .rounded

        let saveButton = NSButton(
            title: "Save Cookies",
            target: self,
            action: #selector(saveCookies(_:))
        )
        saveButton.bezelStyle = .rounded

        let reloadButton = NSButton(
            title: "Reload",
            target: self,
            action: #selector(reloadPage(_:))
        )
        reloadButton.bezelStyle = .rounded

        let statusLabel = NSTextField(labelWithString: "Loading \(config.loginURL.host ?? "login page")…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        self.statusLabel = statusLabel

        let buttonRow = NSStackView(views: [statusLabel, NSView(), browserButton, reloadButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let root = NSStackView(views: [webView, buttonRow])
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.windowTitle
        window.contentView = contentView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        loadLogin()
    }

    @objc private func reloadPage(_ sender: Any?) {
        loadLogin(ignoringCache: true)
    }

    @objc private func openInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(config.loginURL)
        statusLabel?.stringValue = "Use your browser if needed; come back here once you're signed in."
    }

    @objc private func saveCookies(_ sender: Any?) {
        guard webView != nil else { return }
        websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.persistCookies(cookies, manual: true)
            }
        }
    }

    private func persistCookies(_ cookies: [HTTPCookie], manual: Bool) {
        guard let header = minimizedCookieHeader(from: cookies) else {
            if manual {
                showAlert(message: "No \(config.tool.menuTitle) cookies found yet. Finish login in this window first.")
            }
            return
        }
        let stored = CookieHeaderCache.store(
            for: config.tool,
            cookieHeader: header,
            sourceLabel: "WebView login"
        )
        guard stored else {
            if manual {
                showAlert(message: "Could not save \(config.tool.menuTitle) cookies to Keychain.")
            }
            return
        }
        didSaveCookiesForCurrentWindow = true
        statusLabel?.stringValue = config.savedConfirmation
        if manual {
            showAlert(message: config.savedConfirmation)
        }
        onSaved?()
    }

    private func persistCookiesSilentlyIfAvailable() {
        guard !didSaveCookiesForCurrentWindow else { return }
        websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.didSaveCookiesForCurrentWindow else { return }
                self.persistCookies(cookies, manual: false)
            }
        }
    }

    private func minimizedCookieHeader(from cookies: [HTTPCookie]) -> String? {
        // Filter to cookies whose domain matches one of the spec's
        // suffix patterns. If `requiredCookieNames` is non-empty, also
        // restrict to those names; an empty set means "ship the full
        // jar" (used for Tencent/Volcengine, whose HttpOnly session
        // helpers can't be enumerated up front). Sort for stability so
        // identical sessions produce identical headers in Keychain.
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

        // Collapse duplicates (same name, kept latest by sort order).
        var seen = Set<String>()
        var pairs: [String] = []
        for cookie in kept where seen.insert(cookie.name).inserted {
            pairs.append("\(cookie.name)=\(cookie.value)")
        }
        let header = pairs.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func loadLogin(ignoringCache: Bool = false) {
        var request = URLRequest(url: config.loginURL)
        if ignoringCache {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        webView?.load(request)
        statusLabel?.stringValue = "Loading \(config.loginURL.host ?? "login page")…"
    }

    private func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(
            source: MiscWebLoginController.formAutofillScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        let bridge = MiscWebLoginAutofillBridge(controller: self)
        userContent.add(bridge, name: MiscWebLoginController.formAutofillMessageName)
        configuration.userContentController = userContent
        autofillBridges.append(bridge)
        return configuration
    }

    fileprivate static let formAutofillMessageName = "vibebarFormAutofill"

    fileprivate func handleAutofillMessage(
        type: String,
        host: String,
        username: String,
        password: String
    ) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        switch type {
        case "capture":
            let credential = WebFormCredential(host: host, username: username, password: password)
            guard credential.isUsable else { return }
            let saved = WebFormCredentialStore.save(credential, for: config.tool)
            if saved {
                statusLabel?.stringValue = "Saved \(host) credentials to Keychain."
            }
        case "request":
            guard let credential = WebFormCredentialStore.bestMatch(for: host, tool: config.tool) else {
                return
            }
            let payload: [String: String] = [
                "username": credential.username,
                "password": credential.password
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            let js = "window.__vibebarFormAutofill && window.__vibebarFormAutofill.fill(\(json));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
            popupWebView?.evaluateJavaScript(js, completionHandler: nil)
        default:
            break
        }
    }

    private static let formAutofillScript: String = """
    (function() {
        if (window.__vibebarFormAutofillInstalled) { return; }
        window.__vibebarFormAutofillInstalled = true;

        function host() {
            try { return (window.location.host || window.location.hostname || '').toString(); }
            catch (_) { return ''; }
        }

        function isVisible(el) {
            if (!el) { return false; }
            if (el.disabled || el.readOnly) { return false; }
            if (el.type === 'hidden') { return false; }
            if (el.offsetParent === null && el !== document.activeElement) {
                var rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
                if (!rect || (rect.width === 0 && rect.height === 0)) { return false; }
            }
            return true;
        }

        function locateFields() {
            var passwords = Array.prototype.slice.call(
                document.querySelectorAll('input[type="password"]')
            ).filter(isVisible);
            if (!passwords.length) { return null; }
            var password = passwords[0];
            var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
            var passwordIdx = inputs.indexOf(password);
            var username = null;
            var allowedTypes = { 'text': 1, 'email': 1, 'tel': 1, 'search': 1, 'number': 1 };
            for (var i = passwordIdx - 1; i >= 0; i--) {
                var candidate = inputs[i];
                var t = (candidate.type || 'text').toLowerCase();
                if (allowedTypes[t] && isVisible(candidate)) {
                    username = candidate;
                    break;
                }
            }
            return { username: username, password: password };
        }

        function post(payload) {
            try {
                window.webkit.messageHandlers.vibebarFormAutofill.postMessage(payload);
            } catch (_) { /* swallow */ }
        }

        function attach(form, fields) {
            if (!form || form.__vibebarAttached) { return; }
            form.__vibebarAttached = true;
            form.addEventListener('submit', function() {
                var uName = fields.username ? (fields.username.value || '').trim() : '';
                var pWord = fields.password ? (fields.password.value || '') : '';
                if (uName && pWord) {
                    post({ type: 'capture', host: host(), username: uName, password: pWord });
                }
            }, true);
        }

        function bind() {
            var fields = locateFields();
            if (!fields || !fields.password) { return false; }
            var form = fields.password.form;
            if (!form) {
                form = fields.password.closest ? fields.password.closest('form') : null;
            }
            if (!form) { form = document.querySelector('form'); }
            attach(form, fields);
            return true;
        }

        function setNativeValue(el, value) {
            try {
                var proto = Object.getPrototypeOf(el);
                var descriptor = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
                var setter = descriptor && descriptor.set;
                if (setter) { setter.call(el, value); } else { el.value = value; }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
            } catch (_) { el.value = value; }
        }

        function fill(payload) {
            try {
                if (!payload || typeof payload !== 'object') { return; }
                var fields = locateFields();
                if (!fields || !fields.password) { return; }
                if (fields.username && !fields.username.value && payload.username) {
                    setNativeValue(fields.username, String(payload.username));
                }
                if (fields.password && !fields.password.value && payload.password) {
                    setNativeValue(fields.password, String(payload.password));
                }
            } catch (_) { /* swallow */ }
        }

        window.__vibebarFormAutofill = { fill: fill };

        function bootstrap() {
            bind();
            post({ type: 'request', host: host() });
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
        } else {
            bootstrap();
        }

        try {
            var observer = new MutationObserver(function() { bind(); });
            observer.observe(document.documentElement || document.body || document, {
                childList: true,
                subtree: true
            });
        } catch (_) { /* swallow */ }
    })();
    """

    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = safariUserAgent
        return webView
    }

    nonisolated private var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    private func isTrustedAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return config.trustedAuthHostSuffixes.contains { rawSuffix in
            let suffix = rawSuffix.lowercased()
            let normalized = suffix.hasPrefix(".") ? String(suffix.dropFirst()) : suffix
            return host == normalized || host.hasSuffix("." + normalized)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === popupWindow {
            popupWebView?.stopLoading()
            popupWebView?.navigationDelegate = nil
            popupWebView?.uiDelegate = nil
            popupWebView = nil
            popupWindow = nil
            return
        }
        popupWindow?.close()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        websiteDataStore.httpCookieStore.remove(self)
        webView = nil
        statusLabel = nil
        window = nil
        onSaved = nil
        didSaveCookiesForCurrentWindow = false
        for bridge in autofillBridges {
            bridge.detach()
        }
        autofillBridges.removeAll()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusLabel?.stringValue = "Loading \(webView.url?.host ?? config.loginURL.host ?? "page")…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel?.stringValue = config.setupHint
        persistCookiesSilentlyIfAvailable()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        statusLabel?.stringValue = "Web content restarted. Reloading…"
        loadLogin(ignoringCache: true)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if scheme != "http" && scheme != "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if isTrustedAuthHost(url.host) {
            decisionHandler(.allow)
            return
        }
        // Unknown host — hand off to the system browser rather than
        // letting an arbitrary site open inside our login window.
        NSWorkspace.shared.open(url)
        statusLabel?.stringValue = "Opened \(url.host ?? "external link") in your browser."
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard isTrustedAuthHost(navigationAction.request.url?.host) else {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
        let popup = makeWebView(configuration: makeWebViewConfiguration())
        popup.allowsBackForwardNavigationGestures = true

        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = navigationAction.request.url?.host ?? config.windowTitle
        popupWindow.contentView = popup
        popupWindow.delegate = self
        popupWindow.center()
        popupWindow.isReleasedWhenClosed = false
        popupWindow.makeKeyAndOrderFront(nil)

        self.popupWindow = popupWindow
        self.popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWindow?.close()
        }
    }
}

extension MiscWebLoginController: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.persistCookiesSilentlyIfAvailable()
        }
    }
}

/// Lightweight WKScriptMessageHandler bridge holding a weak ref back
/// to `MiscWebLoginController` so the user-content controller can
/// outlive the controller without leaking.
@MainActor
final class MiscWebLoginAutofillBridge: NSObject, WKScriptMessageHandler {
    private weak var controller: MiscWebLoginController?

    init(controller: MiscWebLoginController) {
        self.controller = controller
        super.init()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit invokes script-message handlers on the main thread,
        // but the protocol surface is `nonisolated`, so we assume the
        // MainActor context to read the (also `@MainActor`-annotated)
        // `body` property without bouncing through a `Task`.
        MainActor.assumeIsolated {
            let dict = message.body as? [String: Any] ?? [:]
            let type = (dict["type"] as? String) ?? ""
            let host = (dict["host"] as? String) ?? ""
            let username = (dict["username"] as? String) ?? ""
            let password = (dict["password"] as? String) ?? ""
            controller?.handleAutofillMessage(
                type: type,
                host: host,
                username: username,
                password: password
            )
        }
    }

    func detach() {
        controller = nil
    }
}

// MARK: - Registry

/// Owns one `MiscWebLoginController` per `ToolType`. Lives in
/// `AppEnvironment` so the controller (and its window) survive
/// SwiftUI view re-renders.
@MainActor
final class MiscWebLoginRegistry {
    private var controllers: [ToolType: MiscWebLoginController] = [:]

    /// Returns `true` if a webview-login flow is configured for `tool`.
    /// Used by the Settings UI to decide whether to render a "Sign in
    /// via Web" affordance.
    static func isSupported(for tool: ToolType) -> Bool {
        config(for: tool) != nil
    }

    func openLogin(for tool: ToolType, onSaved: @escaping () -> Void) {
        guard let config = Self.config(for: tool) else { return }
        let controller = controllers[tool] ?? MiscWebLoginController(config: config)
        controllers[tool] = controller
        controller.open(onSaved: onSaved)
    }

    private static func config(for tool: ToolType) -> MiscWebLoginController.Config? {
        switch tool {
        case .mimo:
            return MiscWebLoginController.Config(
                tool: .mimo,
                loginURL: URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!,
                cookieDomainSuffixes: ["xiaomimimo.com"],
                requiredCookieNames: MimoQuotaAdapter.cookieSpec.requiredNames,
                trustedAuthHostSuffixes: [
                    // Xiaomi MiMo platform + own console assets.
                    "xiaomimimo.com",
                    // Xiaomi SSO + login flow assets.
                    "xiaomi.com",
                    "mi.com",
                    "mi-img.com",
                    // miVerify captcha (slider / click).
                    "sec.xiaomi.com"
                ],
                windowTitle: "Xiaomi MiMo Login",
                savedConfirmation: "MiMo cookies saved.",
                setupHint: "Sign in to Xiaomi MiMo, then click Save Cookies."
            )
        case .volcengine:
            return MiscWebLoginController.Config(
                tool: .volcengine,
                loginURL: URL(string: "https://console.volcengine.com/ark")!,
                cookieDomainSuffixes: ["volcengine.com"],
                requiredCookieNames: [],  // ship full jar
                trustedAuthHostSuffixes: [
                    "volcengine.com",
                    "volccdn.com",
                    "zijieapi.com",       // Bytedance internal monitoring CDN
                    "douyincdn.com",
                    "bytedance.com"
                ],
                windowTitle: "Volcengine Doubao Login",
                savedConfirmation: "Doubao cookies saved.",
                setupHint: "Sign in to Volcengine console (sub-user works), then click Save Cookies."
            )
        case .tencentHunyuan:
            return MiscWebLoginController.Config(
                tool: .tencentHunyuan,
                loginURL: URL(string: "https://hunyuan.cloud.tencent.com/")!,
                cookieDomainSuffixes: ["cloud.tencent.com", "tencent.com"],
                // Empty set tells the controller to ship every cookie
                // for the matching domains, mirroring the adapter's
                // `cookieSpec.requiredNames = []`. Tencent stitches
                // identity from a handful of HttpOnly helpers we can't
                // enumerate from JS.
                requiredCookieNames: [],
                trustedAuthHostSuffixes: [
                    // Tencent Cloud console + Hunyuan console.
                    "cloud.tencent.com",
                    "tencent.com",
                    "qq.com",                     // QQ login + assets
                    "qcloud.com",                 // legacy Tencent Cloud
                    "tencent-cloud.com",          // public CDN
                    "wx.qq.com",                  // WeChat scan login
                    "captcha.qcloud.com",         // Tencent captcha
                    "captcha.gtimg.com"           // captcha assets
                ],
                windowTitle: "Tencent Hunyuan Login",
                savedConfirmation: "Hunyuan cookies saved.",
                setupHint: "Sign in to Tencent Cloud (sub-user works), then click Save Cookies."
            )
        case .alibaba:
            return MiscWebLoginController.Config(
                tool: .alibaba,
                loginURL: URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!,
                cookieDomainSuffixes: ["aliyun.com", "alibabacloud.com"],
                requiredCookieNames: [],  // ship full jar (HttpOnly login tickets)
                trustedAuthHostSuffixes: [
                    "aliyun.com",
                    "alibabacloud.com",
                    "alibaba.com",
                    "alibaba-inc.com",
                    "alicdn.com",
                    "alipay.com",
                    "taobao.com",
                    "alibabausercontent.com"
                ],
                windowTitle: "Alibaba Bailian / ModelStudio Login",
                savedConfirmation: "Alibaba console cookies saved.",
                setupHint: "Sign in to Bailian (CN) or ModelStudio (Intl); use the same console where your Coding Plan lives. Then click Save Cookies."
            )
        default:
            return nil
        }
    }
}
