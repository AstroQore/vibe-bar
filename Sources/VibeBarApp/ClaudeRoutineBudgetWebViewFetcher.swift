import AppKit
import Foundation
import WebKit
import VibeBarCore

@MainActor
enum ClaudeRoutineBudgetWebViewFetcher {
    static func fetch(timeout: TimeInterval = 18) async -> ClaudeRoutinesFetcher.Result? {
        let perAttemptTimeout = max(6, timeout / Double(Self.userAgents.count))
        for userAgent in Self.userAgents {
            let runner = ClaudeRoutineBudgetWebViewFetchRunner(timeout: perAttemptTimeout, userAgent: userAgent)
            if let result = await runner.fetch() {
                return result
            }
        }
        return nil
    }

    private static let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    ]
}

@MainActor
private final class ClaudeRoutineBudgetWebViewFetchRunner: NSObject, WKNavigationDelegate {
    private static let endpoint = URL(string: "https://claude.ai/v1/code/routines/run-budget")!

    private let timeout: TimeInterval
    private let userAgent: String
    private var webView: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<ClaudeRoutinesFetcher.Result?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(timeout: TimeInterval, userAgent: String) {
        self.timeout = timeout
        self.userAgent = userAgent
    }

    func fetch() async -> ClaudeRoutinesFetcher.Result? {
        let configuration = WKWebViewConfiguration()
        // Fresh in-memory store per attempt: cookies we seed for this fetch
        // don't accumulate in the global WebKit data store, and the routine
        // budget probe never sees stale state from a previous run.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = userAgent
        self.webView = webView
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        self.window = window

        if let header = ClaudeWebCookieStore.candidateCookieHeaders().first {
            await setCookies(from: header, in: configuration.websiteDataStore.httpCookieStore)
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: Self.endpoint)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.timeoutInterval = timeout
            webView.load(request)
            let timeout = self.timeout
            timeoutTask = Task { [weak self, timeout] in
                let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    self?.finish(nil)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Only run JS if we ended up on the expected origin. Cookie-rejected
        // redirects can drop us on an interstitial or a Cloudflare page; we
        // shouldn't extract innerText from arbitrary hosts.
        guard webView.url?.host == "claude.ai" else {
            finish(nil)
            return
        }
        readBudgetBody(from: webView, attempt: 0)
    }

    private func readBudgetBody(from webView: WKWebView, attempt: Int) {
        guard webView.url?.host == "claude.ai" else {
            finish(nil)
            return
        }
        let script = "document.body ? document.body.innerText : ''"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            Task { @MainActor in
                guard let self, !self.isFinished else { return }
                if
                    let body = value as? String,
                    let bodyData = body.data(using: .utf8),
                    let result = ClaudeRoutinesFetcher.parse(data: bodyData)
                {
                    self.finish(result)
                    return
                }
                guard attempt < 4 else {
                    self.finish(nil)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !self.isFinished, let webView = self.webView else {
                    self.finish(nil)
                    return
                }
                self.readBudgetBody(from: webView, attempt: attempt + 1)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ result: ClaudeRoutinesFetcher.Result?) {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        window?.close()
        window = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func setCookies(from header: String, in store: WKHTTPCookieStore) async {
        for cookie in httpCookies(from: header) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func httpCookies(from header: String) -> [HTTPCookie] {
        ClaudeWebCookieStore.normalizedCookieHeader(from: header)
            .split(separator: ";")
            .compactMap { part -> HTTPCookie? in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return HTTPCookie(properties: [
                    .domain: "claude.ai",
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: true
                ])
            }
    }

}
