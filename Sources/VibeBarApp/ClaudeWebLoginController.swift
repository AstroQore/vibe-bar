import AppKit
import WebKit
import VibeBarCore

@MainActor
final class ClaudeWebLoginController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static let loginURL = URL(string: "https://claude.ai/login")!

    private var window: NSWindow?
    private var webView: WKWebView?
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?
    private var statusLabel: NSTextField?
    private var onSaved: (() -> Void)?
    private var didSaveCookiesForCurrentWindow = false
    private let loginWebsiteDataStore = WKWebsiteDataStore.default()

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
        loginWebsiteDataStore.httpCookieStore.add(self)

        let browserButton = NSButton(
            title: "Open in Browser",
            target: self,
            action: #selector(openInBrowser(_:))
        )
        browserButton.bezelStyle = .rounded

        let saveButton = NSButton(
            title: "Save Claude Cookies",
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

        let statusLabel = NSTextField(labelWithString: "Loading claude.ai login...")
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
        window.title = "Claude Web Login"
        window.contentView = contentView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        loadClaudeLogin()
    }

    @objc private func reloadPage(_ sender: Any?) {
        loadClaudeLogin(ignoringCache: true)
    }

    @objc private func openInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(Self.loginURL)
        statusLabel?.stringValue = "Use your browser for passkeys; use this window to save claude.ai cookies."
    }

    @objc private func saveCookies(_ sender: Any?) {
        guard webView != nil else { return }
        loginWebsiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.persistClaudeCookies(cookies)
            }
        }
    }

    private func persistClaudeCookies(_ cookies: [HTTPCookie]) {
        guard Self.persistClaudeCookiesToKeychain(cookies) else {
            showAlert(message: "No claude.ai cookies found yet. Finish login in this window first.")
            return
        }

        didSaveCookiesForCurrentWindow = true
        showAlert(message: "Claude cookies saved.")
        onSaved?()
    }

    static func importPersistentClaudeCookiesIfAvailable(completion: @escaping @MainActor (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let didImport = Self.persistClaudeCookiesToKeychain(cookies)
            Task { @MainActor in
                completion(didImport)
            }
        }
    }

    private func persistClaudeCookiesSilentlyIfAvailable() {
        guard !didSaveCookiesForCurrentWindow else { return }
        loginWebsiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard Self.persistClaudeCookiesToKeychain(cookies) else { return }
            Task { @MainActor in
                guard let self, !self.didSaveCookiesForCurrentWindow else { return }
                self.didSaveCookiesForCurrentWindow = true
                self.statusLabel?.stringValue = "Claude cookies saved."
                self.onSaved?()
            }
        }
    }

    private static func persistClaudeCookiesToKeychain(_ cookies: [HTTPCookie]) -> Bool {
        guard let minimizedHeader = minimizedClaudeCookieHeader(from: cookies) else {
            return false
        }
        do {
            try ClaudeWebCookieStore.writeCookieHeader(minimizedHeader, source: .webView)
            cacheClaudeOrganizationID(from: minimizedHeader)
            return true
        } catch {
            SafeLog.warn("Saving Claude web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            return false
        }
    }

    private static func minimizedClaudeCookieHeader(from cookies: [HTTPCookie]) -> String? {
        let claudeCookies = cookies
            .filter { cookie in
                cookie.domain == "claude.ai" || cookie.domain.hasSuffix(".claude.ai")
            }
            .sorted { $0.name < $1.name }

        let header = claudeCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        return ClaudeWebCookieStore.minimizedCookieHeader(from: header)
    }

    private static func cacheClaudeOrganizationID(from cookieHeader: String) {
        Task.detached {
            _ = try? await ClaudeOrganizationIDFetcher.fetch(cookieHeader: cookieHeader)
        }
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

    private func loadClaudeLogin(ignoringCache: Bool = false) {
        var request = URLRequest(url: Self.loginURL)
        if ignoringCache {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        webView?.load(request)
        statusLabel?.stringValue = "Loading claude.ai login..."
    }

    private func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Use the app's own persistent WebKit store for Claude login. This is
        // intentionally not Chrome/Safari import: it restores the older
        // "Vibe Bar WebView owns the claude.ai session" path, while still
        // mirroring only the minimal sessionKey into Keychain for quota calls.
        configuration.websiteDataStore = loginWebsiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    static func clearPersistentClaudeWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let claudeRecords = records.filter { record in
                record.displayName == "claude.ai" || record.displayName.hasSuffix(".claude.ai")
            }
            guard !claudeRecords.isEmpty else { return }
            store.removeData(ofTypes: types, for: claudeRecords) {}
        }
    }

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
        loginWebsiteDataStore.httpCookieStore.remove(self)
        webView = nil
        statusLabel = nil
        window = nil
        onSaved = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusLabel?.stringValue = "Loading \(webView.url?.host ?? "claude.ai")..."
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel?.stringValue = "Log in to claude.ai, then save cookies."
        // Only probe page length on hosts in the allowlist. A mid-flight
        // redirect to an unexpected origin must not run our JS there.
        guard Self.isTrustedAuthHost(webView.url?.host) else { return }
        webView.evaluateJavaScript("document.body ? document.body.innerText.trim().length : 0") { [weak self, weak webView] result, _ in
            Task { @MainActor in
                guard let self, webView === self.webView else { return }
                if let length = result as? Int, length == 0 {
                    self.statusLabel?.stringValue = "Blank page after redirect. Try Reload, or use Open in Browser for passkeys."
                }
            }
        }
        persistClaudeCookiesSilentlyIfAvailable()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        statusLabel?.stringValue = "Web content restarted. Reloading claude.ai..."
        loadClaudeLogin(ignoringCache: true)
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
        if Self.isTrustedAuthHost(url.host) {
            decisionHandler(.allow)
            return
        }
        // Unknown host: hand off to the system browser instead of letting
        // claude.ai redirect us into an arbitrary site inside the in-app
        // browser, where the user might mistake it for a legitimate part of
        // the login flow.
        NSWorkspace.shared.open(url)
        statusLabel?.stringValue = "Opened \(url.host ?? "external link") in your browser."
        decisionHandler(.cancel)
    }

    /// Allowlist of hosts the in-app login window may navigate to. Covers
    /// claude.ai, anthropic.com, and the standard SSO providers Anthropic
    /// supports (Google, Apple, GitHub). Anything else is opened in the
    /// system browser.
    private static let trustedAuthHostSuffixes: [String] = [
        "anthropic.com",
        "claude.ai",
        "google.com",
        "googleusercontent.com",
        "gstatic.com",
        "apple.com",
        "icloud.com",
        "github.com",
        "githubusercontent.com",
        "githubassets.com"
    ]

    private static func isTrustedAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return trustedAuthHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else {
            return nil
        }
        // Reject popups whose target origin isn't in our allowlist — never
        // hand a fresh WKWebView to an arbitrary site that the page asks us
        // to open.
        guard Self.isTrustedAuthHost(navigationAction.request.url?.host) else {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        // Use our own configuration rather than reusing the page-supplied
        // one, so popups share Vibe Bar's Claude WebView cookie store.
        let popup = makeWebView(configuration: makeWebViewConfiguration())
        popup.allowsBackForwardNavigationGestures = true

        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = navigationAction.request.url?.host ?? "Claude Login"
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

extension ClaudeWebLoginController: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        persistClaudeCookiesSilentlyIfAvailable()
    }
}
