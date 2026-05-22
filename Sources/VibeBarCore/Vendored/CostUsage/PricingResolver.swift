import Foundation

/// Resolves the active pricing data set with a strict precedence:
///
///  1. **Cache** at `~/.vibebar/pricing_cache.json` — populated by
///     `PricingRefresher` when a fresh remote fetch succeeds.
///  2. **Bundled** `pricing.json` shipped in `Bundle.module` (the
///     copy that lives alongside the source).
///  3. **Hardcoded** in-code fallback (`PricingHardcoded.fallback`) —
///     covers test targets that don't ship `Bundle.module` and the
///     pathological case where the bundle resource is missing on
///     disk at runtime.
///
/// The resolved data set is computed exactly once per process. The
/// refresher mutates the on-disk cache asynchronously, but those
/// updates only take effect on the *next* launch — keeps the
/// in-memory pricing table immutable for the rest of the process
/// lifetime and avoids re-running `CostUsageScanner` aggregations
/// with mid-flight rate changes.
public enum PricingResolver {
    /// Override hook for tests. When set, `active` returns this
    /// instead of reading the cache / bundle. Reset to `nil` in the
    /// `tearDown` of any suite that touches it.
    public static var testOverride: PricingDataSet?

    public static var active: PricingDataSet {
        if let testOverride { return testOverride }
        return cachedActive
    }

    private static let cachedActive: PricingDataSet = resolve(
        homeDirectory: RealHomeDirectory.path
    )

    /// Test-friendly entry point. Production code path goes through
    /// `active` which uses the real home directory.
    public static func resolve(homeDirectory: String) -> PricingDataSet {
        if let cached = loadCache(homeDirectory: homeDirectory) {
            return cached
        }
        if let bundled = loadBundled() {
            return bundled
        }
        return PricingHardcoded.fallback
    }

    public static func cacheFileURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("pricing_cache.json")
    }

    static func loadCache(homeDirectory: String) -> PricingDataSet? {
        let url = cacheFileURL(homeDirectory: homeDirectory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > 0, size <= PricingDataSet.maxBytes,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PricingDataSet.self, from: data),
              decoded.schemaVersion == PricingDataSet.currentSchemaVersion
        else { return nil }
        return decoded
    }

    static func loadBundled() -> PricingDataSet? {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PricingDataSet.self, from: data),
              decoded.schemaVersion == PricingDataSet.currentSchemaVersion
        else { return nil }
        return decoded
    }
}
