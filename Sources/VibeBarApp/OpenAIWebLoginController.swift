import AppKit
import WebKit
import VibeBarCore

@MainActor
final class OpenAIWebLoginController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private static let loginURL = URL(string: "https://chatgpt.com/")!

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var onSaved: (() -> Void)?
    private var didSaveCookiesForCurrentWindow = false
    private let websiteDataStore = WKWebsiteDataStore.default()

    func open(onSaved: @escaping () -> Void) {
        self.onSaved = onSaved

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView

        let saveButton = NSButton(title: "Save OpenAI Cookies", target: self, action: #selector(saveCookies(_:)))
        saveButton.bezelStyle = .rounded
        let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reloadPage(_:)))
        reloadButton.bezelStyle = .rounded
        let browserButton = NSButton(title: "Open in Browser", target: self, action: #selector(openInBrowser(_:)))
        browserButton.bezelStyle = .rounded

        let statusLabel = NSTextField(labelWithString: "Loading ChatGPT...")
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
        window.title = "OpenAI Web Login"
        window.contentView = contentView
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        loadLogin()
    }

    @objc private func saveCookies(_ sender: Any?) {
        websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                self?.persistOpenAICookies(cookies, alertOnFailure: true)
            }
        }
    }

    @objc private func reloadPage(_ sender: Any?) {
        loadLogin(ignoringCache: true)
    }

    @objc private func openInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(Self.loginURL)
        statusLabel?.stringValue = "Use your browser if WebView login is blocked, then import from browser."
    }

    static func importPersistentOpenAICookiesIfAvailable(completion: @escaping @MainActor (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let didImport = persistOpenAICookiesToStore(cookies)
            Task { @MainActor in
                completion(didImport)
            }
        }
    }

    static func clearPersistentOpenAIWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let openAIRecords = records.filter { record in
                record.displayName == "chatgpt.com"
                    || record.displayName == "openai.com"
                    || record.displayName.hasSuffix(".chatgpt.com")
                    || record.displayName.hasSuffix(".openai.com")
            }
            guard !openAIRecords.isEmpty else { return }
            store.removeData(ofTypes: types, for: openAIRecords) {}
        }
    }

    private func loadLogin(ignoringCache: Bool = false) {
        var request = URLRequest(url: Self.loginURL)
        if ignoringCache {
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        webView?.load(request)
        statusLabel?.stringValue = "Loading ChatGPT..."
    }

    private func persistOpenAICookies(_ cookies: [HTTPCookie], alertOnFailure: Bool) {
        guard Self.persistOpenAICookiesToStore(cookies) else {
            if alertOnFailure {
                showAlert(message: "No ChatGPT session cookies found yet. Finish login first.")
            }
            return
        }
        didSaveCookiesForCurrentWindow = true
        statusLabel?.stringValue = "OpenAI cookies saved."
        if alertOnFailure {
            showAlert(message: "OpenAI cookies saved.")
        }
        onSaved?()
    }

    private static func persistOpenAICookiesToStore(_ cookies: [HTTPCookie]) -> Bool {
        let relevant = cookies
            .filter { cookie in
                cookie.domain == "chatgpt.com"
                    || cookie.domain.hasSuffix(".chatgpt.com")
                    || cookie.domain == "openai.com"
                    || cookie.domain.hasSuffix(".openai.com")
            }
            .sorted { $0.name < $1.name }
            .map { (name: $0.name, value: $0.value) }
        guard let header = OpenAIWebCookieStore.cookieHeader(from: relevant) else { return false }
        do {
            try OpenAIWebCookieStore.writeCookieHeader(header, source: .webView)
            return true
        } catch {
            SafeLog.warn("Saving OpenAI web cookies failed: \(SafeLog.sanitize(error.localizedDescription))")
            return false
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

    nonisolated private var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        statusLabel?.stringValue = "Loading \(webView.url?.host ?? "ChatGPT")..."
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        statusLabel?.stringValue = "Log in to ChatGPT, then save cookies."
        guard !didSaveCookiesForCurrentWindow else { return }
        websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.didSaveCookiesForCurrentWindow else { return }
                self.persistOpenAICookies(cookies, alertOnFailure: false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        statusLabel?.stringValue = "Load failed: \(SafeLog.sanitize(error.localizedDescription))"
    }

    func windowWillClose(_ notification: Notification) {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        statusLabel = nil
        window = nil
        onSaved = nil
    }
}
