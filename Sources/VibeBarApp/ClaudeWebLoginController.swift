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
        guard let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.persistClaudeCookies(cookies)
            }
        }
    }

    private func persistClaudeCookies(_ cookies: [HTTPCookie]) {
        let claudeCookies = cookies
            .filter { cookie in
                cookie.domain == "claude.ai" || cookie.domain.hasSuffix(".claude.ai")
            }
            .sorted { $0.name < $1.name }

        let header = claudeCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard !header.isEmpty else {
            showAlert(message: "No claude.ai cookies found yet. Finish login in this window first.")
            return
        }

        do {
            try ClaudeWebCookieStore.writeCookieHeader(header)
            cacheClaudeOrganizationID(from: header)
            showAlert(message: "Claude cookies saved.")
            onSaved?()
        } catch {
            showAlert(message: "Could not save Claude cookies: \(error.localizedDescription)")
        }
    }

    private func cacheClaudeOrganizationID(from cookieHeader: String) {
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
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
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
        webView.evaluateJavaScript("document.body ? document.body.innerText.trim().length : 0") { [weak self, weak webView] result, _ in
            Task { @MainActor in
                guard let self, webView === self.webView else { return }
                if let length = result as? Int, length == 0 {
                    self.statusLabel?.stringValue = "Blank page after redirect. Try Reload, or use Open in Browser for passkeys."
                }
            }
        }
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
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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

        let popup = makeWebView(configuration: configuration)
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
