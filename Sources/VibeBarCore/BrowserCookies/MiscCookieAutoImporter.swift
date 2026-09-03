import Foundation

/// Opt-in "re-import once, then retry once" wrapper around a misc
/// provider's per-slot quota fetch.
///
/// This is the misc-provider analogue of `ClaudeQuotaAdapter`'s
/// `reimportWebCookieOnStale` hook: a cookie jar that has expired shows
/// up as `QuotaError.needsLogin`, and the browser the user is signed
/// into usually already holds a fresh one. Rather than leaving the card
/// on "Needs re-login" until the user notices, pull the fresh session in
/// and try the request again.
///
/// Three properties are deliberate:
///
/// - **Off by default.** Gated on `AppSettings.miscCookieAutoImportEnabled`,
///   which a settings file written by an older build decodes to `false`.
/// - **Never prompts.** The re-import runs with
///   `allowKeychainPrompt: false`; a browser whose Safe Storage key
///   isn't already unlocked in this process is simply skipped.
/// - **Exactly one retry.** A slot that fails, gets a fresh header, and
///   fails again surfaces the original credential error. No loops.
/// - **At most one re-import per provider instance per cooldown.** A slot
///   that is genuinely signed out stays in a credential-error state, so
///   without a cooldown every quota refresh — the user can set that to a few
///   minutes — paid for a full browser walk (SQLite reads across every
///   profile plus Keychain work) that can only succeed if the user has
///   meanwhile signed back in.
///
/// The hooks are injectable so the gating and merge logic can be tested
/// without a Keychain, a browser, or a network. The cooldown is per
/// *instance* of this type for the same reason: `shared` is the long-lived
/// one adapters use, while a test's own importer starts cold.
public struct MiscCookieAutoImporter: Sendable {
    /// The instance the adapters use.
    public static let shared = MiscCookieAutoImporter()

    /// Six hours. Signing back into a provider in the browser is a
    /// deliberate, infrequent act; anything shorter is just re-reading the
    /// same expired jar.
    public static let defaultReimportCooldown: TimeInterval = 6 * 60 * 60

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
    /// in a credential state (`needsLogin` / `noCredential`), optionally
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
        fetch: @Sendable @escaping (MiscCookieResolver.Resolution) async throws -> AccountQuota
    ) async -> [MiscQuotaAggregator.SlotResult] {
        let first = await MiscQuotaAggregator.gatherSlotResults(resolutions, fetch: fetch)

        let staleSlotIDs = Set(first.compactMap { result -> UUID? in
            guard case let .failure(error) = result.outcome, error.isCredentialState else { return nil }
            return result.slotID
        })
        // Nothing expired, or the user hasn't opted in. Checking the
        // setting last keeps the happy path free of a settings read.
        guard !staleSlotIDs.isEmpty, isEnabled() else { return first }

        let instanceID = AccountStore.miscInstanceID(
            fromAccountID: account.id,
            fallbackTool: spec.tool
        )
        // Claimed before the work, not after: a re-import that finds nothing
        // is exactly the case we must not repeat every refresh.
        guard cooldown.claim(tool: spec.tool, instanceID: instanceID) else { return first }
        guard await reimport(spec, instanceID) else { return first }

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
        let retryTargets = resolve(spec, instanceID).filter { resolution in
            guard let slotID = resolution.slotID, staleSlotIDs.contains(slotID) else { return false }
            return previousHeaders[slotID] != resolution.header
        }
        guard !retryTargets.isEmpty else { return first }

        let retried = await MiscQuotaAggregator.gatherSlotResults(retryTargets, fetch: fetch)
        return Self.merge(original: first, retried: retried)
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
        let key = "\(tool.rawValue)\u{0}\(instanceID)"
        if let last = lastAttempt[key], now >= last, now.timeIntervalSince(last) < interval {
            return false
        }
        lastAttempt[key] = now
        return true
    }
}
