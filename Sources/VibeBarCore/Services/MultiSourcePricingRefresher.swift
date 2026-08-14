import Foundation

/// Refreshes each public catalog independently, keeps the last usable table
/// for each source, then merges from lowest to highest priority:
/// AstroQore -> Portkey -> models.dev -> LiteLLM -> user overrides.
public enum MultiSourcePricingRefresher {
    public struct Endpoints: Sendable {
        public var liteLLM: URL
        public var modelsDev: URL
        public var modelsDevFallback: URL?
        public var portkey: [PricingProviderFamily: URL]
        public var astroQore: URL

        public init(
            liteLLM: URL,
            modelsDev: URL,
            modelsDevFallback: URL? = nil,
            portkey: [PricingProviderFamily: URL],
            astroQore: URL
        ) {
            self.liteLLM = liteLLM
            self.modelsDev = modelsDev
            self.modelsDevFallback = modelsDevFallback
            self.portkey = portkey
            self.astroQore = astroQore
        }

        public static let production = Endpoints(
            liteLLM: PricingRefresher.remoteURL,
            modelsDev: URL(string: "https://models.dev/api.json")!,
            modelsDevFallback: URL(
                string: "https://unpkg.com/@opencode-ai/models@latest/dist/snapshot.js"
            )!,
            portkey: [
                .codex: URL(string: "https://configs.portkey.ai/pricing/openai.json")!,
                .claude: URL(string: "https://configs.portkey.ai/pricing/anthropic.json")!,
                .gemini: URL(string: "https://configs.portkey.ai/pricing/google.json")!,
                .grok: URL(string: "https://configs.portkey.ai/pricing/x-ai.json")!,
            ],
            astroQore: URL(
                string: "https://raw.githubusercontent.com/AstroQore/vibebar-model-pricing/main/pricing.json"
            )!
        )
    }

    public struct Result: Equatable, Sendable {
        public let changed: Bool
        public let status: PricingRefreshStatus

        public init(changed: Bool, status: PricingRefreshStatus) {
            self.changed = changed
            self.status = status
        }
    }

    public static let maxFetchBytes = 12 * 1024 * 1024
    public static let defaultRequestTimeout: TimeInterval = 15

    @discardableResult
    public static func refreshAll(
        homeDirectory: String = RealHomeDirectory.path,
        overrides: [ModelPricingOverride] = [],
        session: URLSession = .shared,
        endpoints: Endpoints = .production,
        requestTimeout: TimeInterval = Self.defaultRequestTimeout,
        now: Date = Date()
    ) async -> Result {
        let base = PricingResolver.loadBundled() ?? PricingHardcoded.fallback
        let updatedAt = updatedAtString(for: now)
        let calculationVersion = base.calculationVersion

        async let liteLLM = refreshSource(
            .liteLLM,
            homeDirectory: homeDirectory,
            now: now
        ) {
            guard let data = try await fetch(
                endpoints.liteLLM, session: session, timeout: requestTimeout
            ) else { throw RefreshError.invalidResponse }
            guard let transformed = LiteLLMPricingTransformer.transform(
                data,
                base: .empty(updatedAt: updatedAt, calculationVersion: calculationVersion),
                updatedAt: updatedAt
            ) else { throw RefreshError.invalidPayload }
            return transformed
        }

        async let modelsDev = refreshSource(
            .modelsDev,
            homeDirectory: homeDirectory,
            now: now
        ) {
            let candidates = [endpoints.modelsDev, endpoints.modelsDevFallback].compactMap { $0 }
            guard let data = try await fetchFirst(
                candidates, session: session, timeout: requestTimeout
            ) else { throw RefreshError.invalidResponse }
            guard let transformed = ModelsDevPricingTransformer.transform(
                data,
                updatedAt: updatedAt,
                calculationVersion: calculationVersion
            ) else { throw RefreshError.invalidPayload }
            return transformed
        }

        async let portkey = refreshSource(
            .portkey,
            homeDirectory: homeDirectory,
            now: now
        ) {
            var payloads: [PricingProviderFamily: Data] = [:]
            await withTaskGroup(
                of: (PricingProviderFamily, Data?).self
            ) { group in
                for (family, url) in endpoints.portkey {
                    group.addTask {
                        do {
                            return (
                                family,
                                try await fetch(
                                    url, session: session, timeout: requestTimeout
                                )
                            )
                        } catch {
                            return (family, nil)
                        }
                    }
                }
                for await (family, data) in group {
                    if let data { payloads[family] = data }
                }
            }
            guard let transformed = PortkeyPricingTransformer.transform(
                payloads,
                updatedAt: updatedAt,
                calculationVersion: calculationVersion
            ) else { throw RefreshError.invalidPayload }
            return transformed
        }

        let higherPrioritySnapshots = await [portkey, modelsDev, liteLLM]
        var inheritanceBase = base
        for snapshot in higherPrioritySnapshots {
            if let dataSet = snapshot.dataSet {
                inheritanceBase = PricingDataSetMerger.overlay(
                    dataSet,
                    onto: inheritanceBase,
                    updatedAt: updatedAt
                )
            }
        }
        let resolvedInheritanceBase = inheritanceBase

        let astroQore = await refreshSource(
            .astroQore, homeDirectory: homeDirectory, now: now
        ) {
            guard let data = try await fetch(
                endpoints.astroQore, session: session, timeout: requestTimeout
            ) else { throw RefreshError.invalidResponse }
            guard let transformed = AstroQorePricingTransformer.transform(
                data,
                updatedAt: updatedAt,
                calculationVersion: calculationVersion,
                inheritanceBase: resolvedInheritanceBase
            ) else { throw RefreshError.invalidPayload }
            return transformed
        }

        let snapshots = [astroQore] + higherPrioritySnapshots
        return persistMerged(
            snapshots,
            base: base,
            homeDirectory: homeDirectory,
            overrides: overrides,
            now: now
        )
    }

    /// Re-applies Settings overrides immediately without waiting for or
    /// starting network I/O. Used while a user edits a rate card.
    @discardableResult
    public static func rebuildFromCaches(
        homeDirectory: String = RealHomeDirectory.path,
        overrides: [ModelPricingOverride],
        now: Date = Date()
    ) -> Result {
        let base = PricingResolver.loadBundled() ?? PricingHardcoded.fallback
        let previous = loadStatus(homeDirectory: homeDirectory)
        let snapshots = PricingSourceID.allCases.reversed().map { source in
            SourceSnapshot(
                source: source,
                dataSet: loadSourceCache(source, homeDirectory: homeDirectory),
                status: previous.sources.first { $0.source == source }
                    ?? PricingSourceStatus(source: source)
            )
        }
        return persistMerged(
            snapshots,
            base: base,
            homeDirectory: homeDirectory,
            overrides: overrides,
            now: now
        )
    }

    public static func loadStatus(
        homeDirectory: String = RealHomeDirectory.path
    ) -> PricingRefreshStatus {
        (try? VibeBarLocalStore.readJSON(
            PricingRefreshStatus.self,
            from: statusURL(homeDirectory: homeDirectory)
        )) ?? .empty
    }

    private struct SourceSnapshot: Sendable {
        let source: PricingSourceID
        let dataSet: PricingDataSet?
        let status: PricingSourceStatus
    }

    private enum RefreshError: Error {
        case invalidResponse
        case invalidPayload
        case oversized
    }

    private static func refreshSource(
        _ source: PricingSourceID,
        homeDirectory: String,
        now: Date,
        loader: @escaping @Sendable () async throws -> PricingDataSet
    ) async -> SourceSnapshot {
        let old = loadStatus(homeDirectory: homeDirectory).sources.first {
            $0.source == source
        }
        do {
            let dataSet = try await loader()
            let encoded = try JSONEncoder().encode(dataSet)
            guard encoded.count <= PricingDataSet.maxBytes else {
                throw RefreshError.oversized
            }
            let cached = loadSourceCache(source, homeDirectory: homeDirectory)
            try VibeBarLocalStore.writeJSON(
                dataSet,
                to: sourceCacheURL(source, homeDirectory: homeDirectory),
                base: VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
            )
            return SourceSnapshot(
                source: source,
                dataSet: dataSet,
                status: PricingSourceStatus(
                    source: source,
                    result: cached == dataSet ? .unchanged : .ready,
                    modelCount: dataSet.modelCount,
                    lastAttemptAt: now,
                    lastSuccessAt: now,
                    detail: nil
                )
            )
        } catch {
            let cached = loadSourceCache(source, homeDirectory: homeDirectory)
            let detail: String
            switch error {
            case RefreshError.oversized: detail = "Response exceeded the local size limit."
            case RefreshError.invalidPayload: detail = "The upstream schema was not usable."
            default: detail = "Refresh failed; using the last cached copy."
            }
            SafeLog.warn("Pricing source \(source.rawValue): \(detail)")
            return SourceSnapshot(
                source: source,
                dataSet: cached,
                status: PricingSourceStatus(
                    source: source,
                    result: .failed,
                    modelCount: cached?.modelCount ?? 0,
                    lastAttemptAt: now,
                    lastSuccessAt: old?.lastSuccessAt,
                    detail: detail
                )
            )
        }
    }

    private static func persistMerged(
        _ snapshots: [SourceSnapshot],
        base: PricingDataSet,
        homeDirectory: String,
        overrides: [ModelPricingOverride],
        now: Date
    ) -> Result {
        let updatedAt = updatedAtString(for: now)
        var merged = base
        for snapshot in snapshots {
            if let dataSet = snapshot.dataSet {
                merged = PricingDataSetMerger.overlay(
                    dataSet,
                    onto: merged,
                    updatedAt: updatedAt
                )
            }
        }
        merged = ModelPricingOverrideApplier.apply(
            overrides,
            to: merged,
            updatedAt: updatedAt
        )

        let old = PricingResolver.loadCache(homeDirectory: homeDirectory)
        let cacheURL = PricingResolver.cacheFileURL(homeDirectory: homeDirectory)
        do {
            try VibeBarLocalStore.writeJSON(
                merged,
                to: cacheURL,
                base: VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
            )
        } catch {
            SafeLog.warn("Pricing merged cache: \(SafeLog.sanitize(error.localizedDescription))")
        }

        let statuses = PricingSourceID.allCases.compactMap { source in
            snapshots.first { $0.source == source }?.status
        }
        let status = PricingRefreshStatus(
            mergedAt: now,
            mergedModelCount: merged.modelCount,
            sources: statuses
        )
        try? VibeBarLocalStore.writeJSON(
            status,
            to: statusURL(homeDirectory: homeDirectory),
            base: VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
        )
        return Result(changed: old != merged, status: status)
    }

    private static func fetch(
        _ url: URL,
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("VibeBar/pricing-refresh", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        guard !data.isEmpty, data.count <= maxFetchBytes else {
            throw RefreshError.oversized
        }
        return data
    }

    private static func fetchFirst(
        _ urls: [URL],
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> Data? {
        var lastError: Error?
        for url in urls {
            do {
                if let data = try await fetch(url, session: session, timeout: timeout) {
                    return data
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func sourceCacheURL(
        _ source: PricingSourceID,
        homeDirectory: String
    ) -> URL {
        VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("pricing_sources", isDirectory: true)
            .appendingPathComponent("\(source.rawValue).json")
    }

    private static func statusURL(homeDirectory: String) -> URL {
        VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("pricing_refresh_status.json")
    }

    private static func loadSourceCache(
        _ source: PricingSourceID,
        homeDirectory: String
    ) -> PricingDataSet? {
        let url = sourceCacheURL(source, homeDirectory: homeDirectory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0, size <= PricingDataSet.maxBytes
        else { return nil }
        return try? VibeBarLocalStore.readJSON(PricingDataSet.self, from: url)
    }

    private static func updatedAtString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
