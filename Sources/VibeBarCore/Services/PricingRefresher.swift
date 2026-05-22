import Foundation

/// Periodically pulls `pricing.json` from the canonical GitHub raw
/// URL and writes it to `~/.vibebar/pricing_cache.json` so the
/// `PricingResolver` picks up new model rates without a rebuild.
///
/// Refresh policy: best-effort, never blocking. The cache file's
/// mtime gates whether a fresh fetch is worth attempting — the
/// default 24-hour window keeps quiet machines off GitHub's rate
/// limits without pinning to a stale snapshot for weeks. The remote
/// fetch is HTTPS-only, size-capped (`PricingDataSet.maxBytes`), and
/// schema-validated; any failure leaves the previous cache in place
/// instead of replacing it with garbage.
///
/// Because `PricingResolver.cachedActive` snapshots on first read,
/// a successful refresh only takes effect on the *next* app launch.
/// That keeps cost calculations stable mid-process and avoids
/// re-aggregating today's data with mid-flight rate changes.
public enum PricingRefresher {
    /// Bundled JSON is the floor; the remote pulls from the same
    /// repository so updates ship by editing one file and merging.
    public static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/AstroQore/vibe-bar/main/Sources/VibeBarCore/Resources/pricing.json"
    )!

    /// Minimum time between fetches — equivalent to "refresh at most
    /// once per app session per day". Override in tests.
    public static let defaultRefreshInterval: TimeInterval = 24 * 3600

    /// Short network timeout — the resolver's already loaded a value
    /// by the time this runs, so we shouldn't hold the run loop on a
    /// hung GitHub edge node.
    public static let defaultRequestTimeout: TimeInterval = 10

    public enum Outcome: Equatable, Sendable {
        case skippedFresh
        case fetched
        case unchanged
        case networkFailure
        case parseFailure
        case schemaMismatch
        case oversized
    }

    /// Refresh the on-disk cache if the existing copy is older than
    /// `interval`. Pass `force: true` to bypass the freshness check
    /// (used by tests and by an explicit user-triggered refresh).
    @discardableResult
    public static func refresh(
        homeDirectory: String = RealHomeDirectory.path,
        session: URLSession = .shared,
        endpoint: URL = Self.remoteURL,
        interval: TimeInterval = Self.defaultRefreshInterval,
        requestTimeout: TimeInterval = Self.defaultRequestTimeout,
        force: Bool = false,
        now: Date = Date()
    ) async -> Outcome {
        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: homeDirectory)

        if !force,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modDate = attrs[.modificationDate] as? Date,
           now.timeIntervalSince(modDate) < interval
        {
            return .skippedFresh
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("VibeBar/pricing-refresh", forHTTPHeaderField: "User-Agent")
        // Conditional GET: tell GitHub raw to short-circuit if the
        // file hasn't changed since the cached copy.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
           let modDate = attrs[.modificationDate] as? Date
        {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            request.setValue(formatter.string(from: modDate),
                             forHTTPHeaderField: "If-Modified-Since")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SafeLog.warn("PricingRefresher network: \(SafeLog.sanitize(error.localizedDescription))")
            return .networkFailure
        }
        guard let http = response as? HTTPURLResponse else { return .networkFailure }
        if http.statusCode == 304 {
            // Touch the cache mtime so the freshness window resets
            // without rewriting identical bytes.
            try? FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: cacheURL.path
            )
            return .unchanged
        }
        guard http.statusCode == 200 else {
            return .networkFailure
        }
        guard data.count > 0, data.count <= PricingDataSet.maxBytes else {
            return .oversized
        }
        let decoded: PricingDataSet
        do {
            decoded = try JSONDecoder().decode(PricingDataSet.self, from: data)
        } catch {
            SafeLog.warn("PricingRefresher decode: \(SafeLog.sanitize(error.localizedDescription))")
            return .parseFailure
        }
        guard decoded.schemaVersion == PricingDataSet.currentSchemaVersion else {
            return .schemaMismatch
        }

        do {
            let parent = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: cacheURL.path
            )
        } catch {
            SafeLog.warn("PricingRefresher cache write: \(SafeLog.sanitize(error.localizedDescription))")
            return .networkFailure
        }
        return .fetched
    }
}
