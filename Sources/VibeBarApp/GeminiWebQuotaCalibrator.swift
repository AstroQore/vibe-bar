import Foundation
import WebKit
import VibeBarCore

/// Learns Gemini Web's current private usage request from the page itself.
/// This is only entered after the lightweight URLSession replay fails.
@MainActor
final class GeminiWebQuotaCalibrator {
    static let shared = GeminiWebQuotaCalibrator()

    private var inflight: [String: Task<AccountQuota, Error>] = [:]
    private var sessions: [ObjectIdentifier: GeminiCalibrationSession] = [:]

    func fetch(account: AccountIdentity, cookieHeader: String) async throws -> AccountQuota {
        if let task = inflight[account.id] {
            return try await task.value
        }
        let task = Task { @MainActor [weak self] () throws -> AccountQuota in
            guard let self else {
                throw QuotaError.unknown("Gemini Web calibration was cancelled.")
            }
            return try await self.perform(account: account, cookieHeader: cookieHeader)
        }
        inflight[account.id] = task
        defer { inflight[account.id] = nil }
        return try await task.value
    }

    private func perform(account: AccountIdentity, cookieHeader: String) async throws -> AccountQuota {
        let session = GeminiCalibrationSession(account: account, cookieHeader: cookieHeader)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        defer { sessions[key] = nil }
        return try await session.start()
    }
}

@MainActor
private final class GeminiCalibrationSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct Candidate {
        let recipe: GeminiWebUsageRecipe
        let snapshot: GeminiWebQuotaSnapshot
    }

    private let account: AccountIdentity
    private let cookieHeader: String
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<AccountQuota, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var candidate: Candidate?
    private var resolved = false
    private var didRetryUsageNavigation = false

    init(account: AccountIdentity, cookieHeader: String) {
        self.account = account
        self.cookieHeader = cookieHeader
        super.init()
    }

    func start() async throws -> AccountQuota {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        await injectCookies(into: dataStore.httpCookieStore)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let controller = WKUserContentController()
            controller.addUserScript(WKUserScript(
                source: Self.observerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            ))
            controller.add(self, name: Self.messageName)

            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            config.userContentController = controller
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.preferences.javaScriptCanOpenWindowsAutomatically = false

            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
                configuration: config
            )
            webView.customUserAgent = Self.safariUserAgent
            webView.navigationDelegate = self
            self.webView = webView

            let request = URLRequest(
                url: URL(string: "https://gemini.google.com/usage?pli=1&hl=en")!,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
            )
            webView.load(request)

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let candidate = self.candidate {
                    self.finish(with: .success(self.quota(from: candidate)))
                } else {
                    self.finish(with: .failure(QuotaError.parseFailure(
                        "Gemini usage page did not expose a recognizable quota request."
                    )))
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let payload = message.body as? [String: Any],
              let rpcID = payload["rpcID"] as? String,
              let argument = payload["argument"] as? String,
              let response = payload["response"] as? String else {
            return
        }
        let recipe = GeminiWebUsageRecipe(rpcID: rpcID, argument: argument)
        guard recipe.isValid,
              let data = response.data(using: .utf8),
              let snapshot = try? GeminiWebResponseParser.parse(
                data: data,
                rpcID: rpcID,
                now: Date()
              ),
              Self.hasCanonicalBuckets(snapshot) else {
            return
        }

        let candidate = Candidate(recipe: recipe, snapshot: snapshot)
        self.candidate = candidate
        Task { @MainActor [weak self] in
            // Give Angular one rendering turn so page text and network data
            // describe the same response before cross-checking.
            try? await Task.sleep(nanoseconds: 450_000_000)
            await self?.validateAgainstRenderedPage(candidate, attempt: 0)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(QuotaError.network(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(with: .failure(QuotaError.network(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didRetryUsageNavigation else { return }
        didRetryUsageNavigation = true
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let webView, !self.resolved, self.candidate == nil else { return }
            // Some Gemini builds fill the first usage visit from bootstrap
            // data and only issue the quota RPC on the next entry.
            var components = URLComponents(string: "https://gemini.google.com/usage")
            components?.queryItems = [
                URLQueryItem(name: "pli", value: "1"),
                URLQueryItem(name: "hl", value: "en"),
                URLQueryItem(name: "_vibebar_probe", value: UUID().uuidString)
            ]
            guard let url = components?.url else { return }
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
    }

    private func validateAgainstRenderedPage(_ candidate: Candidate, attempt: Int) async {
        guard !resolved, self.candidate?.recipe == candidate.recipe, let webView else { return }
        let text = (try? await webView.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"
        )) as? String ?? ""
        let rendered = Self.renderedUsedPercents(in: text)

        if !rendered.isEmpty {
            let expected = candidate.snapshot.buckets
                .filter { $0.id == GeminiWebResponseParser.currentUsageBucketId
                    || $0.id == GeminiWebResponseParser.weeklyUsageBucketId }
                .map(\.usedPercent)
            let matches = expected.allSatisfy { value in
                rendered.contains { abs($0 - value) <= 2.0 }
            }
            guard matches else { return }
            finish(with: .success(quota(from: candidate)))
            return
        }

        // Localized or still-loading pages may not expose the English
        // "% used" labels immediately. Retry twice; the semantic two-bucket
        // validation remains the final fallback at the session timeout.
        guard attempt < 2 else { return }
        try? await Task.sleep(nanoseconds: 700_000_000)
        await validateAgainstRenderedPage(candidate, attempt: attempt + 1)
    }

    private func quota(from candidate: Candidate) -> AccountQuota {
        try? GeminiWebUsageRecipeStore.save(candidate.recipe)
        return AccountQuota(
            accountId: account.id,
            tool: .gemini,
            buckets: candidate.snapshot.buckets,
            plan: candidate.snapshot.planName,
            email: candidate.snapshot.email,
            queriedAt: Date(),
            error: nil
        )
    }

    private func finish(with result: Result<AccountQuota, Error>) {
        guard !resolved else { return }
        resolved = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let controller = webView?.configuration.userContentController as WKUserContentController? {
            controller.removeScriptMessageHandler(forName: Self.messageName)
        }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private func injectCookies(into store: WKHTTPCookieStore) async {
        for pair in cookieHeader.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "="), equals != trimmed.startIndex else { continue }
            let name = String(trimmed[..<equals])
            let value = String(trimmed[trimmed.index(after: equals)...])
            guard let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".gemini.google.com",
                .path: "/",
                .secure: true
            ]) else { continue }
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private static func hasCanonicalBuckets(_ snapshot: GeminiWebQuotaSnapshot) -> Bool {
        let ids = Set(snapshot.buckets.map(\.id))
        return ids.contains(GeminiWebResponseParser.currentUsageBucketId)
            && ids.contains(GeminiWebResponseParser.weeklyUsageBucketId)
    }

    private static func renderedUsedPercents(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d{1,3}(?:\.\d+)?)\s*%\s*used"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> Double? in
                guard match.numberOfRanges > 1 else { return nil }
                return Double(ns.substring(with: match.range(at: 1)))
            }
    }

    private static let messageName = "vibeBarGeminiUsageCapture"

    /// MAIN-world interception is required because isolated-world scripts
    /// cannot wrap the page's own fetch/XMLHttpRequest functions.
    private static let observerScript = #"""
    (() => {
      if (window.__vibeBarUsageObserverInstalled) return;
      window.__vibeBarUsageObserverInstalled = true;
      const handler = window.webkit?.messageHandlers?.vibeBarGeminiUsageCapture;
      if (!handler) return;

      const recipes = (url, body) => {
        try {
          if (!String(url || '').includes('/batchexecute')) return [];
          const params = new URLSearchParams(typeof body === 'string' ? body : '');
          const raw = params.get('f.req');
          if (!raw) return [];
          const parsed = JSON.parse(raw);
          const found = [];
          const visit = value => {
            if (!Array.isArray(value)) return;
            if (typeof value[0] === 'string' &&
                typeof value[1] === 'string' &&
                value.length >= 2) {
              found.push({ rpcID: value[0], argument: value[1] });
            }
            for (const child of value) visit(child);
          };
          visit(parsed);
          return found;
        } catch (_) {
          return [];
        }
      };

      const publish = (url, body, response) => {
        if (typeof response !== 'string' || response.length === 0) return;
        for (const recipe of recipes(url, body)) {
          try { handler.postMessage({ ...recipe, response }); } catch (_) {}
        }
      };

      const nativeFetch = window.fetch;
      window.fetch = async function(input, init) {
        let url = typeof input === 'string'
          ? input
          : (input instanceof Request ? input.url : String(input || ''));
        let body = init?.body;
        if (body instanceof URLSearchParams) body = body.toString();
        if (typeof body !== 'string' && input instanceof Request) {
          try { body = await input.clone().text(); } catch (_) {}
        }
        const response = await nativeFetch.apply(this, arguments);
        try {
          const text = await response.clone().text();
          publish(url, body, text);
        } catch (_) {}
        return response;
      };

      const nativeOpen = XMLHttpRequest.prototype.open;
      const nativeSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__vibeBarURL = String(url || '');
        return nativeOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        this.__vibeBarBody = typeof body === 'string' ? body : '';
        this.addEventListener('load', () => {
          try { publish(this.__vibeBarURL, this.__vibeBarBody, this.responseText); } catch (_) {}
        }, { once: true });
        return nativeSend.apply(this, arguments);
      };
    })();
    """#

    private nonisolated static var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    }
}
