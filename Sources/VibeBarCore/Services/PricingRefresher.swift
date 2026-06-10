import Foundation

/// Periodically pulls LiteLLM's community-maintained model price map,
/// transforms it into our schema (overlaid on the bundled floor via
/// `LiteLLMPricingTransformer`), and writes the result to
/// `~/.vibebar/pricing_cache.json` so `PricingResolver` picks up new
/// model rates without a rebuild — and without anyone hand-editing
/// `pricing.json` for every new model.
///
/// Refresh policy: best-effort, never blocking. The cache file's
/// mtime gates whether a fresh fetch is worth attempting — the
/// default 24-hour window keeps quiet machines off GitHub's rate
/// limits without pinning to a stale snapshot for weeks. The remote
/// fetch is HTTPS-only and size-capped (`maxFetchBytes`); the
/// transformed payload we persist is re-capped at
/// `PricingDataSet.maxBytes`. Any failure leaves the previous cache in
/// place instead of replacing it with garbage.
///
/// A successful refresh takes effect at the next cost re-scan:
/// `CostUsageService.refreshAll()` re-adopts the rewritten cache via
/// `PricingResolver.reloadIfChanged()` at the start of each pass — a
/// pass boundary — so new rates land without an app relaunch while any
/// single aggregation still runs against one consistent table.
public enum PricingRefresher {
    /// Upstream source of truth: LiteLLM's
    /// `model_prices_and_context_window.json`. The bundled
    /// `pricing.json` is only the offline floor that this overlays.
    public static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Cap for the raw LiteLLM download (~1.5 MB today). Generous
    /// headroom for upstream growth while still rejecting a runaway or
    /// garbage response. The transformed cache we actually persist stays
    /// small and is re-checked against `PricingDataSet.maxBytes`.
    public static let maxFetchBytes = 8 * 1024 * 1024

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
        guard data.count > 0, data.count <= Self.maxFetchBytes else {
            return .oversized
        }
        // Transform LiteLLM's flat price map into our schema, overlaid on
        // the bundled floor so models LiteLLM omits (AntiGravity, anything
        // it prices as null) survive.
        let base = PricingResolver.loadBundled() ?? PricingHardcoded.fallback
        guard let dataSet = LiteLLMPricingTransformer.transform(
            data,
            base: base,
            updatedAt: Self.updatedAtString(for: now)
        ) else {
            SafeLog.warn("PricingRefresher transform: LiteLLM payload not usable")
            return .parseFailure
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(dataSet)
        } catch {
            SafeLog.warn("PricingRefresher encode: \(SafeLog.sanitize(error.localizedDescription))")
            return .parseFailure
        }
        guard encoded.count <= PricingDataSet.maxBytes else {
            return .oversized
        }

        do {
            let parent = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try encoded.write(to: cacheURL, options: .atomic)
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

    private static func updatedAtString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
