import Foundation

/// HTTPS download to a file with a hard ceiling enforced *while* streaming.
///
/// `HTTPResponseLimit` covers the small JSON/HTML responses Vibe Bar reads into
/// memory; this is its counterpart for the one thing that must land on disk —
/// a GitHub repository zipball. The difference matters: `URLSession.data(for:)`
/// buffers the whole body before anyone can look at its size, so a hostile or
/// broken host can exhaust memory before the check runs. Here the byte count is
/// tested on every delivered chunk and the task is cancelled the moment it goes
/// over, with the partial file removed.
///
/// Three other rules are enforced for the same reason the skills feature exists
/// at all — it fetches third-party content:
/// 1. `https` only, and the origin host must be in `allowedHosts`;
/// 2. redirects are re-checked against the same allowlist, so a 302 cannot walk
///    the download off github.com (this is not hypothetical: the archive URL
///    legitimately redirects to codeload.github.com, which is why the allowlist
///    is a set rather than a single host);
/// 3. a `Content-Length` that already exceeds the cap is refused before a
///    single body byte is accepted.
///
/// The session is created per download from a caller-supplied configuration —
/// ephemeral by default, so nothing is cached, and injectable so tests can
/// stub `URLProtocol`.
public struct BoundedDownloader: Sendable {
    public typealias ConfigurationProvider = @Sendable () -> URLSessionConfiguration

    public enum DownloadError: Error, Equatable, Sendable {
        case insecureScheme(String)
        case hostNotAllowed(String)
        case redirectHostNotAllowed(String)
        case notHTTP
        case httpStatus(Int)
        case tooLarge(limit: Int64)
        case cannotCreateFile(String)
    }

    private let makeConfiguration: ConfigurationProvider

    public init(configuration: @escaping ConfigurationProvider = { .ephemeral }) {
        self.makeConfiguration = configuration
    }

    /// Streams `url` into `fileURL`, replacing whatever was there.
    ///
    /// Throws before touching the network on a non-https URL or a host outside
    /// `allowedHosts`; throws mid-stream once more than `maxBytes` have
    /// arrived. `fileURL` only exists when this returns normally.
    public func download(
        from url: URL,
        to fileURL: URL,
        maxBytes: Int64,
        timeout: TimeInterval,
        allowedHosts: Set<String>
    ) async throws {
        let hosts = Set(allowedHosts.map { $0.lowercased() })
        try Self.validate(url: url, allowedHosts: hosts)

        let fm = FileManager.default
        try? fm.removeItem(at: fileURL)
        try fm.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fm.createFile(atPath: fileURL.path, contents: nil) else {
            throw DownloadError.cannotCreateFile(fileURL.lastPathComponent)
        }
        let handle = try FileHandle(forWritingTo: fileURL)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("VibeBar/skills", forHTTPHeaderField: "User-Agent")

        let configuration = makeConfiguration()
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let sink = Sink(handle: handle, maxBytes: maxBytes, allowedHosts: hosts)
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: queue)
        defer { session.invalidateAndCancel() }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sink.onFinish = { continuation.resume(with: $0) }
                session.dataTask(with: request).resume()
            }
        } catch {
            try? handle.close()
            try? fm.removeItem(at: fileURL)
            SafeLog.net("BoundedDownloader failed for \(Self.safeDescription(of: url))")
            throw error
        }
        try handle.close()
    }

    // MARK: - Internals

    static func validate(url: URL, allowedHosts: Set<String>) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw DownloadError.insecureScheme(url.scheme ?? "")
        }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw DownloadError.hostNotAllowed(url.host ?? "")
        }
    }

    /// Host plus path only — a download URL's query is never log material.
    static func safeDescription(of url: URL) -> String {
        "\(url.host ?? "?")\(url.path)"
    }

    /// Owns the byte budget for one download. Every callback lands on the
    /// session's serial delegate queue, so the counters need no locking; the
    /// one cross-thread hand-off (`onFinish`) is installed before the task is
    /// resumed and read only from that queue.
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let maxBytes: Int64
        private let allowedHosts: Set<String>
        private var received: Int64 = 0
        private var failure: Error?

        var onFinish: ((Result<Void, Error>) -> Void)?

        init(handle: FileHandle, maxBytes: Int64, allowedHosts: Set<String>) {
            self.handle = handle
            self.maxBytes = maxBytes
            self.allowedHosts = allowedHosts
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                failure = DownloadError.notHTTP
                completionHandler(.cancel)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                failure = DownloadError.httpStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > 0, http.expectedContentLength > maxBytes {
                failure = DownloadError.tooLarge(limit: maxBytes)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            received += Int64(data.count)
            if received > maxBytes {
                failure = DownloadError.tooLarge(limit: maxBytes)
                dataTask.cancel()
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard
                let url = request.url,
                url.scheme?.lowercased() == "https",
                let host = url.host?.lowercased(),
                allowedHosts.contains(host)
            else {
                failure = DownloadError.redirectHostNotAllowed(request.url?.host ?? "")
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let finish = onFinish
            onFinish = nil
            if let failure {
                finish?(.failure(failure))
            } else if let error {
                finish?(.failure(error))
            } else {
                finish?(.success(()))
            }
        }
    }
}

extension BoundedDownloader.DownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .insecureScheme(scheme):
            return "Refusing a non-HTTPS download (scheme \"\(scheme)\")."
        case let .hostNotAllowed(host):
            return "Downloads from \"\(host)\" are not allowed."
        case let .redirectHostNotAllowed(host):
            return "The download was redirected to \"\(host)\", which is not allowed."
        case .notHTTP:
            return "The server did not return an HTTP response."
        case let .httpStatus(code):
            return "The server returned HTTP \(code)."
        case let .tooLarge(limit):
            return "The download exceeded its \(limit)-byte limit."
        case let .cannotCreateFile(name):
            return "Could not create \"\(name)\"."
        }
    }
}
