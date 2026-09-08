import Foundation

/// Opt-in recovery for cookie-backed misc providers. Every failed fetch gets
/// one non-interactive browser re-read. Retry only changed browser-owned slots;
/// never overwrite pasted cookies, recurse, or prompt for Keychain access.
/// Empty resolution lists get one attempt to recover a browser session too.
public struct MiscCookieAutoImporter: Sendable {
    /// The instance the adapters use.
    public static let shared = MiscCookieAutoImporter()

    /// Each failed refresh can observe a newly signed-in browser session.
    /// Callers may still opt into a cooldown, but the shared importer does not.
    public static let defaultReimportCooldown: TimeInterval = 0

    private let isEnabled: @Sendable () -> Bool
    private let reimport: @Sendable (MiscCookieResolver.Spec, String) async -> Bool
    private let resolve: @Sendable (MiscCookieResolver.Spec, String) -> [MiscCookieResolver.Resolution]
    private let cooldown: ReimportCooldown

    public init(
        isEnabled: (@Sendable () -> Bool)? = nil,
        reimport: (@Sendable (MiscCookieResolver.Spec, String) async -> Bool)? = nil,
        resolve: (@Sendable (MiscCookieResolver.Spec, String) -> [MiscCookieResolver.Resolution])? = nil,
        reimportCooldown: TimeInterval = MiscCookieAutoImporter.defaultReimportCooldown
    ) {
        self.isEnabled = isEnabled ?? Self.defaultIsEnabled
        self.reimport = reimport ?? Self.defaultReimport
        self.resolve = resolve ?? Self.defaultResolve
        self.cooldown = ReimportCooldown(interval: reimportCooldown)
    }

    /// Fan `fetch` out across `resolutions`, and when a slot comes back
    /// with an error, optionally
    /// re-import that provider's cookies from the browser and retry the
    /// affected slots once.
    ///
    /// Drop-in replacement for `MiscQuotaAggregator.gatherSlotResults`;
    /// the returned results go straight into
    /// `MiscQuotaAggregator.aggregate` exactly as before.
    public func gatherSlotResults(
        spec: MiscCookieResolver.Spec,
        account: AccountIdentity,
        resolutions: [MiscCookieResolver.Resolution],
        resolutionFilter: @Sendable (MiscCookieResolver.Resolution) -> Bool = { _ in true },
        fetch: @Sendable @escaping (MiscCookieResolver.Resolution) async throws -> AccountQuota
    ) async -> [MiscQuotaAggregator.SlotResult] {
        let first = await MiscQuotaAggregator.gatherSlotResults(resolutions, fetch: fetch)
        guard !Task.isCancelled else { return first }
        let failedSlotIDs = Set(first.compactMap { result -> UUID? in
            guard case .failure = result.outcome else { return nil }
            return result.slotID
        })
        guard (resolutions.isEmpty || !failedSlotIDs.isEmpty), isEnabled() else { return first }
        let instanceID = AccountStore.miscInstanceID(
            fromAccountID: account.id, fallbackTool: spec.tool
        )
        guard cooldown.claim(tool: spec.tool, instanceID: instanceID),
              await reimport(spec, instanceID), !Task.isCancelled else { return first }
        let refreshed = resolve(spec, instanceID).filter(resolutionFilter)
        if resolutions.isEmpty {
            // This is already the recovery attempt. A failed recovered fetch
            // is returned directly, without a second re-import.
            return await MiscQuotaAggregator.gatherSlotResults(refreshed, fetch: fetch)
        }

        // Retry only the slots we actually tried and that actually
        // changed. Restricting to the original slot IDs also preserves
        // any adapter-side filtering of the resolution list (Ollama
        // drops slots without a recognised session cookie) — a slot the
        // adapter excluded was never in `resolutions` and stays out.
        let previousHeaders = Dictionary(
            resolutions.compactMap { resolution -> (UUID, String)? in
                guard let slotID = resolution.slotID else { return nil }
                return (slotID, resolution.header)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let retryTargets = refreshed.filter { resolution in
            guard let slotID = resolution.slotID, failedSlotIDs.contains(slotID) else { return false }
            return previousHeaders[slotID] != resolution.header
        }
        guard !retryTargets.isEmpty else { return first }

        let retried = await MiscQuotaAggregator.gatherSlotResults(retryTargets, fetch: fetch)
        return Self.merge(original: first, retried: retried)
    }

    /// Forget the re-import cooldown for one provider instance, or for every
    /// instance of `tool` when `instanceID` is `nil`.
    ///
    /// The cooldown only ever meant "a *scheduled* refresh should not keep
    /// re-reading a browser that was signed out a minute ago". A user who
    /// presses Refresh, signs back in, reloads credentials, or imports a
    /// cookie by hand is telling us the browser state changed, and the whole
    /// point of the retry is to pick that up now — not in six hours or after
    /// a relaunch. Mirrors how `AppEnvironment` drops its routine-budget
    /// failure cooldowns on the same paths.
    public func resetCooldown(for tool: ToolType, instanceID: String? = nil) {
        cooldown.reset(tool: tool, instanceID: instanceID)
    }

    /// Forget every re-import cooldown. Used by the explicit
    /// "reload credentials and refresh" path, which is also where the global
    /// Refresh button lands.
    public func resetCooldowns() {
        cooldown.resetAll()
    }

    /// Replace each original result with its retried counterpart,
    /// keeping the original ordering and any slot that wasn't retried.
    static func merge(
        original: [MiscQuotaAggregator.SlotResult],
        retried: [MiscQuotaAggregator.SlotResult]
    ) -> [MiscQuotaAggregator.SlotResult] {
        guard !retried.isEmpty else { return original }
        var bySlotID: [UUID: MiscQuotaAggregator.SlotResult] = [:]
        for result in retried {
            guard let slotID = result.slotID else { continue }
            bySlotID[slotID] = result
        }
        return original.map { result in
            guard let slotID = result.slotID, let replacement = bySlotID[slotID] else { return result }
            return replacement
        }
    }

    // MARK: - Defaults

    @Sendable
    private static func defaultIsEnabled() -> Bool {
        let settings = (try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        )) ?? .default
        return settings.miscCookieAutoImportEnabled
    }

    /// Offloaded to a detached task for the same reason
    /// `ClaudeQuotaAdapter` does it: the browser read is SQLite plus
    /// Keychain work and has no business running on the executor that
    /// is driving the quota fetch.
    @Sendable
    private static func defaultReimport(
        _ spec: MiscCookieResolver.Spec,
        _ instanceID: String
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            MiscCookieResolver.silentReimport(spec: spec, instanceID: instanceID)
        }.value
    }

    @Sendable
    private static func defaultResolve(
        _ spec: MiscCookieResolver.Spec,
        _ instanceID: String
    ) -> [MiscCookieResolver.Resolution] {
        MiscCookieResolver.resolveAll(for: spec, instanceID: instanceID)
    }
}

/// Last re-import attempt per `(tool, instanceID)`. In memory only: the
/// cooldown exists to keep a permanently signed-out slot from re-reading the
/// browser on every refresh, and a relaunch is a fine moment to try once more.
private final class ReimportCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var lastAttempt: [String: Date] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Records an attempt and reports whether it may proceed.
    func claim(tool: ToolType, instanceID: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(tool: tool, instanceID: instanceID)
        if let last = lastAttempt[key], now >= last, now.timeIntervalSince(last) < interval {
            return false
        }
        lastAttempt[key] = now
        return true
    }

    func reset(tool: ToolType, instanceID: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let instanceID else {
            let prefix = "\(tool.rawValue)\u{0}"
            lastAttempt = lastAttempt.filter { !$0.key.hasPrefix(prefix) }
            return
        }
        lastAttempt.removeValue(forKey: Self.key(tool: tool, instanceID: instanceID))
    }

    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        lastAttempt.removeAll()
    }

    private static func key(tool: ToolType, instanceID: String) -> String {
        "\(tool.rawValue)\u{0}\(instanceID)"
    }
}
