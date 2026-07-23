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
/// The resolved data set is loaded lazily on first read and then held
/// stable until `reloadIfChanged()` swaps it. The refresher mutates
/// the on-disk cache asynchronously; `CostUsageService` re-adopts it
/// at the start of each `refreshAll()` pass — a pass boundary, before
/// any scan begins — so the table never changes inside a single
/// `CostUsageScanner` aggregation but new model rates still land
/// without an app relaunch.
public enum PricingResolver {
    /// Override hook for tests. When set, `active` returns this
    /// instead of reading the cache / bundle. Reset to `nil` in the
    /// `tearDown` of any suite that touches it.
    public static var testOverride: PricingDataSet?

    /// Guards `loadedState`. `active` is read from detached cost-scan
    /// tasks while `reloadIfChanged` swaps on the main actor — the
    /// previous `static let` got its thread safety from the runtime's
    /// one-time initialization, a mutable table needs a real lock.
    private static let stateLock = NSLock()
    private static var loadedState: PricingDataSet?

    public static var active: PricingDataSet {
        if let testOverride { return testOverride }
        stateLock.lock()
        defer { stateLock.unlock() }
        if let loadedState { return loadedState }
        let resolved = resolve(homeDirectory: RealHomeDirectory.path)
        loadedState = resolved
        return resolved
    }

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

    /// Re-runs the cache → bundle → hardcoded resolution and swaps the
    /// active table when the result differs from the one currently
    /// loaded. Returns `true` only on a content swap (the first load of
    /// the process is not a change). Call at aggregation-pass
    /// boundaries only — `CostUsageService.refreshAll()` does — so any
    /// single cost scan computes against one consistent table. No-op
    /// while `testOverride` is set, keeping service-level tests pinned
    /// to their injected rates.
    @discardableResult
    public static func reloadIfChanged(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        guard testOverride == nil else { return false }
        let fresh = resolve(homeDirectory: homeDirectory)
        stateLock.lock()
        defer { stateLock.unlock() }
        let changed = loadedState != nil && loadedState != fresh
        loadedState = fresh
        return changed
    }

    /// Test hook: drop the loaded table so the next `active` read
    /// re-resolves from disk. Keeps reload tests from leaking a temp
    /// home's pricing into later suites.
    static func forgetCachedStateForTests() {
        stateLock.lock()
        defer { stateLock.unlock() }
        loadedState = nil
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
        guard let url = bundledPricingURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PricingDataSet.self, from: data),
              decoded.schemaVersion == PricingDataSet.currentSchemaVersion
        else { return nil }
        return decoded
    }

    /// SwiftPM's generated `Bundle.module` accessor only knows the absolute
    /// build directory and a bundle next to `Bundle.main.bundleURL`. Neither
    /// location is valid after the executable is installed in a signed macOS
    /// app: the CI build directory is gone, while non-Contents files make
    /// codesign reject the app. The packaging script therefore embeds the
    /// generated resource bundle in the conventional Resources directory.
    private static func bundledPricingURL() -> URL? {
        if let resourcesURL = Bundle.main.resourceURL {
            let embeddedBundleURL = resourcesURL
                .appendingPathComponent("VibeBar_VibeBarCore.bundle", isDirectory: true)
            if let embeddedBundle = Bundle(url: embeddedBundleURL),
               let url = embeddedBundle.url(
                   forResource: "pricing",
                   withExtension: "json"
               )
            {
                return url
            }
        }
        return Bundle.module.url(forResource: "pricing", withExtension: "json")
    }
}
