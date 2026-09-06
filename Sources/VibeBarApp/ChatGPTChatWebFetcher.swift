import Foundation
import WebKit
import VibeBarCore

/// Reuses the same first-party WebView login as OpenAI Settings. No browser
/// extension, localhost listener, exported token or prompt submission is needed.
@MainActor
enum ChatGPTChatWebFetcher {
    static func fetch(account: AccountIdentity, settings: ChatGPTChatSettings, cookieHeader: String?) async throws -> AccountQuota {
        let transport = ChatGPTChatWebTransport()
        defer { transport.close() }
        try await transport.prepare(cookieHeader: cookieHeader)
        return try await ChatGPTChatClient(transport: transport).fetch(account: account, settings: settings)
    }
}

@MainActor
private final class ChatGPTChatWebTransport: NSObject, ChatGPTChatTransport, WKNavigationDelegate {
    nonisolated let name = "webview"
    private var webView: WKWebView?
    private var navigation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    func prepare(cookieHeader: String?) async throws {
        // Imported cookies belong to their own source; do not overwrite an
        // independently authenticated built-in profile during a failed refresh.
        let store = cookieHeader == nil ? WKWebsiteDataStore.default() : .nonPersistent()
        if let cookieHeader {
            for pair in cookieHeader.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let cookie = HTTPCookie(properties: [
                        .name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                        .value: String(parts[1]), .domain: "chatgpt.com", .path: "/", .secure: "TRUE"
                      ]) else { continue }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    store.httpCookieStore.setCookie(cookie) { done.resume() }
                }
            }
        }
        try Task.checkCancellation()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                view.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
                timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 18_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishNavigation(.failure(QuotaError.needsLogin))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }

    nonisolated func request(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        try await perform(path: path, method: method, bearer: bearer, body: body)
    }

    private func perform(path: String, method: String, bearer: String?, body: Data?) async throws -> Data {
        try Task.checkCancellation()
        guard ChatGPTChatRequestPolicy.allows(path: path, method: method), let webView,
              webView.url?.host == "chatgpt.com", webView.url?.scheme == "https" else { throw QuotaError.needsLogin }
        return try await withTaskCancellationHandler {
            let arguments: [String: Any] = ["path": path, "method": method,
                "token": bearer ?? "", "body": body.flatMap { String(data: $0, encoding: .utf8) } ?? ""]
            let value = try await webView.callAsyncJavaScript(Self.requestScript, arguments: arguments, in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let object = value as? [String: Any], let status = object["status"] as? Int,
                  let text = object["body"] as? String, let data = text.data(using: .utf8) else {
                throw QuotaError.parseFailure("Invalid ChatGPT Chat WebView response.")
            }
            try ChatGPTChatCookieTransport.validate(status: status, size: data.count)
            return data
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
    }

    private static let requestScript = """
    if (location.origin !== 'https://chatgpt.com') throw new Error('origin');
    const headers = {Accept: 'application/json'};
    if (token) headers.Authorization = 'Bearer ' + token;
    if (body) headers['Content-Type'] = 'application/json';
    const response = await fetch(path, {
      method, headers, body: body || undefined, credentials: 'include',
      redirect: 'error', signal: AbortSignal.timeout(12000)
    });
    const reader = response.body.getReader();
    const chunks = []; let bytes = 0;
    while (true) {
      const next = await reader.read(); if (next.done) break;
      bytes += next.value.byteLength;
      if (bytes > 8388608) { await reader.cancel(); throw new Error('read bound'); }
      chunks.push(next.value);
    }
    const joined = new Uint8Array(bytes); let offset = 0;
    for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
    return {status: response.status, body: new TextDecoder().decode(joined)};
    """

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(webView.url?.host == "chatgpt.com" ? .success(()) : .failure(QuotaError.needsLogin))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(QuotaError.needsLogin))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(QuotaError.needsLogin))
    }
    private func finishNavigation(_ result: Result<Void, Error>) {
        timeout?.cancel(); timeout = nil
        let current = navigation; navigation = nil
        current?.resume(with: result)
    }
    func close() {
        finishNavigation(.failure(CancellationError()))
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }
}
