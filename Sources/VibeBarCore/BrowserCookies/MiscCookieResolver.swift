import Foundation
import os.lock
import SweetCookieKit

/// Picks `Cookie:` headers for a misc-provider adapter at fetch time.
///
/// Vibe Bar lets the user stack multiple cookie sessions per provider
/// (work + personal + trial accounts) and aggregates their quotas. The
/// resolver returns every slot the user has imported for `spec.tool`,
/// filtered by the current `MiscProviderSettings` source mode and the
/// spec's required-credential gate. Adapters fan out a quota query per
/// slot and average the buckets via `MiscQuotaAggregator`.
///
/// Slots live in `MiscCookieSlotStore` (Keychain). The resolver no
/// longer keeps a separate `CookieHeaderCache` layer — slots *are* the
/// cache. The legacy single-cookie state is migrated into slots on
/// first read; see `LegacyCookieMigration`.
public enum MiscCookieResolver {
    /// Browser-credential schema completion is attempted once per slot per app
    /// run. A signed-out or unavailable profile must not turn every scheduled
    /// quota refresh into another full localStorage scan.
    private static let browserCredentialCompletionAttempts =
        OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    /// Per-provider description of which cookies matter and where
    /// to look for them. Adapters declare this as a constant.
    public struct Spec {
        public let tool: ToolType
        /// Cookie domains to query SweetCookieKit for.
        public let domains: [String]
        /// Cookie names to keep when minimising the imported header.
        /// Anything not in this set is dropped — analytics, A/B,
        /// session-flag cookies don't survive into the cached header.
        public let requiredNames: Set<String>
        /// Cookie names that prove the header is actually authenticated.
        /// This is stricter than `requiredNames`: MiniMax, for example,
        /// has non-auth `_gc_*` cookies on the same domains, and caching
        /// those alone causes every refresh to look like "re-login".
        public let credentialNames: Set<String>
        /// Default browser-import order if the user hasn't picked
        /// `MiscProviderSettings.preferredBrowser`.
        public let importOrder: BrowserCookieImportOrder
        /// Browser persistence surface holding the live credential. Cookie
        /// jars remain the default; providers can declaratively map one exact
        /// Chromium localStorage field into the same cookie-shaped slot.
        public let browserCredentialSource: BrowserCredentialSource

        public init(
            tool: ToolType,
            domains: [String],
            requiredNames: Set<String>,
            credentialNames: Set<String> = [],
            importOrder: BrowserCookieImportOrder = BrowserCookieDefaults.importOrder,
            browserCredentialSource: BrowserCredentialSource = .cookieJar
        ) {
            self.tool = tool
            self.domains = domains
            self.requiredNames = requiredNames
            self.credentialNames = credentialNames
            self.importOrder = importOrder
            self.browserCredentialSource = browserCredentialSource
        }

        public func minimizedHeader(from raw: String?) -> String? {
            let normalized: String?
            if requiredNames.isEmpty {
                normalized = CookieHeaderNormalizer.normalize(raw)
            } else {
                normalized = CookieHeaderNormalizer.filteredHeader(from: raw, allowedNames: requiredNames)
            }
            guard let normalized, hasRequiredCredential(in: normalized) else {
                return nil
            }
            return normalized
        }

        public func hasRequiredCredential(in cookieHeader: String) -> Bool {
            guard !credentialNames.isEmpty else { return true }
            return CookieHeaderNormalizer.pairs(from: cookieHeader)
                .contains { credentialNames.contains($0.name) }
        }
    }

    public struct Resolution: Sendable {
        public let slotID: UUID?
        public let header: String
        public let sourceLabel: String

        public init(slotID: UUID?, header: String, sourceLabel: String) {
            self.slotID = slotID
            self.header = header
            self.sourceLabel = sourceLabel
        }
    }

    /// Slot filter derived from the user's source-mode settings.
    enum SlotFilter: Equatable {
        case all
        case browserOnly
        case manualOnly
        case none

        init(settings: MiscProviderSettings) {
            switch settings.sourceMode {
            case .off, .apiOnly:
                self = .none
            case .browserOnly:
                self = .browserOnly
            case .manualOnly:
                self = .manualOnly
            case .auto:
                switch settings.cookieSource {
                case .off:
                    self = .none
                case .manual:
                    self = .manualOnly
                case .auto:
                    self = .all
                }
            }
        }

        func allows(_ slot: MiscCookieSlot) -> Bool {
            switch self {
            case .all:
                return true
            case .browserOnly:
                return slot.origin != .manual
            case .manualOnly:
                return slot.origin == .manual
            case .none:
                return false
            }
        }
    }

    /// Resolve every cookie slot that's eligible for `spec.tool`.
    /// Returns slots in insertion order. Empty when the user has no
    /// slots, or when the source mode bans cookies entirely
    /// (`apiOnly` / `off`).
    public static func resolveAll(for spec: Spec) -> [Resolution] {
        resolveAll(for: spec, instanceID: spec.tool.rawValue)
    }

    public static func resolveAll(for spec: Spec, account: AccountIdentity) -> [Resolution] {
        resolveAll(
            for: spec,
            instanceID: AccountStore.miscInstanceID(fromAccountID: account.id, fallbackTool: spec.tool)
        )
    }

    public static func resolveAll(for spec: Spec, instanceID: String) -> [Resolution] {
        let settings = currentSettings(for: spec.tool, instanceID: instanceID)
        let filter = SlotFilter(settings: settings)
        guard filter != .none else { return [] }

        var slots = MiscCookieSlotStore.slots(for: spec.tool, instanceID: instanceID)
        // A browser-owned slot imported by an older build can be missing a
        // newly declared localStorage field. Complete that one-time schema
        // migration from the same profile without a Keychain prompt. Manual
        // headers remain fully user-owned and are never touched here.
        let incompleteSlotIDs = Set(slots.compactMap { slot -> UUID? in
            guard slot.origin != .manual,
                  !spec.browserCredentialSource.hasCompleteBrowserCredential(
                      in: slot.cookieHeader
                  ) else {
                return nil
            }
            return slot.id
        })
        let shouldAttemptCompletion = browserCredentialCompletionAttempts.withLock { attempted in
            let unseen = incompleteSlotIDs.subtracting(attempted)
            attempted.formUnion(incompleteSlotIDs)
            return !unseen.isEmpty
        }
        if shouldAttemptCompletion {
            _ = silentReimport(spec: spec, instanceID: instanceID)
            slots = MiscCookieSlotStore.slots(for: spec.tool, instanceID: instanceID)
        }

        return slots.compactMap { slot in
            guard filter.allows(slot) else { return nil }
            guard let header = spec.minimizedHeader(from: slot.cookieHeader),
                  !header.isEmpty else { return nil }
            return Resolution(
                slotID: slot.id,
                header: header,
                sourceLabel: slot.sourceLabel
            )
        }
    }

    /// Resolve the first eligible slot. Kept for callers that haven't
    /// migrated to `resolveAll` yet.
    public static func resolve(for spec: Spec) -> Resolution? {
        resolveAll(for: spec).first
    }

    public static func resolve(for spec: Spec, account: AccountIdentity) -> Resolution? {
        resolveAll(for: spec, account: account).first
    }

    /// Run the SweetCookieKit browser-import dance and add or refresh the
    /// captured browser-profile slot. Returns the stored slot's
    /// Resolution on success, or `nil` if no browser session was
    /// found (or the source mode bans cookies).
    public static func appendBrowserImport(for spec: Spec) -> Resolution? {
        appendBrowserImport(for: spec, instanceID: spec.tool.rawValue)
    }

    public static func appendBrowserImport(for spec: Spec, instanceID: String) -> Resolution? {
        let settings = currentSettings(for: spec.tool, instanceID: instanceID)
        guard SlotFilter(settings: settings) != .none else { return nil }
        guard let imported = attemptBrowserImport(spec: spec, settings: settings).session else {
            return nil
        }
        let slot = MiscCookieSlot(
            cookieHeader: imported.header,
            sourceLabel: imported.sourceLabel,
            importedAt: Date(),
            origin: .browserImport
        )
        guard let stored = MiscCookieSlotStore.upsertBrowserImport(
            slot,
            for: spec.tool,
            instanceID: instanceID
        ) else { return nil }
        return Resolution(
            slotID: stored.id,
            header: imported.header,
            sourceLabel: imported.sourceLabel
        )
    }

    /// `appendBrowserImport` with the reason attached when it fails.
    ///
    /// The Settings row uses this so a declined Keychain prompt reads as a
    /// cooldown with a Retry-now button rather than as "no cookies found".
    public static func appendBrowserImportOutcome(
        for spec: Spec,
        instanceID: String,
        now: Date = Date()
    ) -> BatchImportOutcome.Result {
        let settings = currentSettings(for: spec.tool, instanceID: instanceID)
        guard SlotFilter(settings: settings) != .none else { return .cookiesDisabled }
        let attempt = attemptBrowserImport(spec: spec, settings: settings, now: now)
        guard let imported = attempt.session else { return attempt.emptyOutcome }
        let slot = MiscCookieSlot(
            cookieHeader: imported.header,
            sourceLabel: imported.sourceLabel,
            importedAt: Date(),
            origin: .browserImport
        )
        guard MiscCookieSlotStore.upsertBrowserImport(
            slot,
            for: spec.tool,
            instanceID: instanceID
        ) != nil else { return .saveFailed }
        return .imported(sourceLabel: imported.sourceLabel)
    }

    /// Legacy alias for callers that haven't migrated to
    /// `appendBrowserImport`. Slot semantics are identical.
    public static func forceBrowserImport(for spec: Spec) -> Resolution? {
        appendBrowserImport(for: spec)
    }

    public static func forceBrowserImport(for spec: Spec, instanceID: String) -> Resolution? {
        appendBrowserImport(for: spec, instanceID: instanceID)
    }

    // MARK: - Batch import

    /// One provider instance to import cookies for.
    public struct BatchImportTarget {
        public let spec: Spec
        public let instanceID: String

        public init(spec: Spec, instanceID: String) {
            self.spec = spec
            self.instanceID = instanceID
        }

        public var tool: ToolType { spec.tool }
    }

    /// What happened for one target in a batch import.
    public struct BatchImportOutcome {
        public enum Result: Equatable {
            /// A new (or refreshed) slot now holds a browser session.
            case imported(sourceLabel: String)
            /// The browsers we were allowed to read had no usable
            /// session for this provider's domains.
            case noSessionFound
            /// Every Chromium-family browser we would have read is inside
            /// `BrowserCookieAccessGate`'s denial cooldown, so nothing was
            /// read. Indistinguishable from `.noSessionFound` at the call
            /// site — which is exactly why it needs its own case: telling
            /// the user to sign in again cannot fix a declined Keychain
            /// prompt.
            case keychainCooldown(browser: String, until: Date)
            /// The provider's source mode bans cookies entirely, so we
            /// never looked.
            case cookiesDisabled
            /// A session was found but the Keychain write failed.
            case saveFailed
        }

        public let tool: ToolType
        public let instanceID: String
        public let result: Result

        public init(tool: ToolType, instanceID: String, result: Result) {
            self.tool = tool
            self.instanceID = instanceID
            self.result = result
        }
    }

    /// Import browser cookies for many provider instances in one pass.
    ///
    /// This is the "do all of them" version of `appendBrowserImport`,
    /// and it exists for two reasons beyond saving the user twelve
    /// clicks:
    ///
    /// 1. `BrowserDetection` caches its filesystem probes **per
    ///    instance**, so building one per provider re-stats every
    ///    browser profile twelve times over. One shared instance turns
    ///    that into a single pass. (The Chromium "Safe Storage" key
    ///    itself is cached per browser in a SweetCookieKit static, so
    ///    the user sees at most one Keychain prompt per distinct
    ///    Chromium browser regardless — but the shared
    ///    `BrowserCookieClient` keeps the whole batch on one handle.)
    /// 2. Targets are walked **sequentially**. Every append rewrites the
    ///    same Keychain item through `VibeBarCredentialVault`, so
    ///    parallel writes would just contend on the vault's lock and
    ///    risk interleaved read-modify-write.
    ///
    /// The one-Chromium-browser-per-call prompt cap in
    /// `cookieImportCandidates` still applies per target, which is what
    /// keeps a batch from fanning out into a stack of password prompts.
    public static func appendBrowserImports(
        for targets: [BatchImportTarget]
    ) -> [BatchImportOutcome] {
        let context = BrowserImportContext()
        return targets.map { target in
            let settings = currentSettings(for: target.tool, instanceID: target.instanceID)
            guard SlotFilter(settings: settings) != .none else {
                return BatchImportOutcome(
                    tool: target.tool,
                    instanceID: target.instanceID,
                    result: .cookiesDisabled
                )
            }
            let attempt = attemptBrowserImport(
                spec: target.spec,
                settings: settings,
                context: context
            )
            guard let imported = attempt.session else {
                return BatchImportOutcome(
                    tool: target.tool,
                    instanceID: target.instanceID,
                    // Per target, not per batch: one provider blocked by a
                    // Chromium cooldown says nothing about the next one,
                    // which may not read cookie jars at all.
                    result: attempt.emptyOutcome
                )
            }
            let slot = MiscCookieSlot(
                cookieHeader: imported.header,
                sourceLabel: imported.sourceLabel,
                importedAt: Date(),
                origin: .browserImport
            )
            guard MiscCookieSlotStore.upsertBrowserImport(
                slot,
                for: target.tool,
                instanceID: target.instanceID
            ) != nil else {
                return BatchImportOutcome(
                    tool: target.tool,
                    instanceID: target.instanceID,
                    result: .saveFailed
                )
            }
            return BatchImportOutcome(
                tool: target.tool,
                instanceID: target.instanceID,
                result: .imported(sourceLabel: imported.sourceLabel)
            )
        }
    }

    // MARK: - Silent re-import

    /// Refresh the provider's existing browser-origin slots from the
    /// browser without ever prompting for the Keychain password.
    ///
    /// Used by `MiscCookieAutoImporter` when a fetch came back
    /// `needsLogin`. Slots are replaced **in place** with origin
    /// `.autoRefresh`; `origin == .manual` slots are left alone, the
    /// same policy `HiddenCookieRefresher` follows — a cookie the user
    /// pasted by hand is theirs to manage.
    ///
    /// Returns `true` when at least one slot's header actually changed,
    /// which is the caller's signal that a retry is worth a round-trip.
    @discardableResult
    public static func silentReimport(spec: Spec, instanceID: String) -> Bool {
        // One shared context across silent re-imports, for the reason
        // `appendBrowserImports` documents: `BrowserDetection` caches its
        // filesystem probes per instance, so a fresh context re-stats every
        // browser profile. Refreshed on a TTL so a browser installed after
        // launch is still discovered, and the lock keeps these sequential —
        // the objects it holds are not thread-safe, and silent re-imports
        // arrive from per-provider detached tasks.
        silentContextLock.lock()
        defer { silentContextLock.unlock() }
        let context = sharedSilentContext()
        let settings = currentSettings(for: spec.tool, instanceID: instanceID)
        // Only when browser-origin slots can actually be used. `manualOnly` is
        // an explicit "do not touch my browser" — reading the cookie stores
        // for a slot the resolver would then filter out anyway would be a
        // background read the user opted out of. (Source modes are normalized
        // to auto today, but this guard is what honors them if they return.)
        switch SlotFilter(settings: settings) {
        case .all, .browserOnly:
            break
        case .manualOnly, .none:
            return false
        }

        let refreshable = MiscCookieSlotStore
            .slots(for: spec.tool, instanceID: instanceID)
            .filter { $0.origin != .manual }
        guard !refreshable.isEmpty else { return false }

        let sessions = browserSessions(
            spec: spec,
            settings: settings,
            allowKeychainPrompt: false,
            context: context,
            maxSessions: nil
        )
        guard !sessions.isEmpty else { return false }

        var unclaimed = sessions
        var changed = false
        for slot in refreshable {
            // Prefer the browser session whose label matches the slot's
            // — that's how a user with stacked work / personal profiles
            // keeps each slot pointed at its own account. With exactly
            // one refreshable slot and one session, fall back to taking
            // that session so the common case still self-heals; the
            // slot's `sourceLabel` is rewritten too, so if the browser
            // has since switched accounts the Settings row says which
            // profile the slot now follows rather than hiding it.
            let matchIndex = unclaimed.firstIndex { $0.sourceLabel == slot.sourceLabel }
                ?? (refreshable.count == 1 && unclaimed.count == 1 ? 0 : nil)
            guard let matchIndex else { continue }
            let session = unclaimed.remove(at: matchIndex)
            guard session.header != slot.cookieHeader else { continue }
            let ok = MiscCookieSlotStore.updateHeader(
                slotID: slot.id,
                for: spec.tool,
                instanceID: instanceID,
                header: session.header,
                sourceLabel: session.sourceLabel,
                importedAt: Date(),
                origin: .autoRefresh
            )
            if ok {
                changed = true
                // Length + hash only. A cookie header is a live
                // credential and never belongs in a log line.
                SafeLog.info(
                    "MiscCookieResolver auto re-import tool=\(spec.tool.rawValue) slot=\(slot.id.uuidString.prefix(8)) len=\(session.header.count) fp=\(headerFingerprint(session.header))"
                )
            }
        }
        // `MiscCookieSlotStore.updateHeader` posts its own change
        // notification, which is what redraws the Settings slot list.
        // No quota refresh is posted here: the caller is mid-fetch and
        // retries with the fresh header itself.
        return changed
    }

    // MARK: - Chromium Keychain warmth

    /// Browsers whose Chromium "Safe Storage" key SweetCookieKit has
    /// already decrypted in this process, courtesy of a user-initiated
    /// import that was allowed to prompt.
    ///
    /// This exists to bridge a mismatch: SweetCookieKit caches that key
    /// in a process-wide `[Browser: Data]` static, but
    /// `BrowserCookieAccessGate`'s non-interactive preflight can still
    /// report `interactionRequired` and install a 6-hour cooldown —
    /// vetoing a silent read that would in fact have decrypted fine from
    /// the cache. Once a browser is warm we ask for its records with
    /// `allowKeychainPrompt: true`, which is the gate's own documented
    /// bypass rather than a poke at its internals, and which cannot
    /// actually surface a prompt while that browser's key is cached.
    ///
    /// Tracked per browser, not as one global flag, because the upstream
    /// cache is per browser: Chrome being unlocked says nothing about
    /// whether reading Brave would prompt.
    private static let warmKeychainBrowsers = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func markKeychainWarm(_ browser: Browser) {
        guard browser.usesKeychainForCookieDecryption else { return }
        warmKeychainBrowsers.withLock { $0.insert(browser.rawValue) }
    }

    static func clearKeychainWarmth(_ browser: Browser) {
        warmKeychainBrowsers.withLock { $0.remove(browser.rawValue) }
    }

    static var warmKeychainBrowserIDs: Set<String> {
        warmKeychainBrowsers.withLock { $0 }
    }

    /// Test hook — process-global state has to be resettable between
    /// cases or the suite's ordering starts to matter.
    static func resetKeychainWarmthForTesting() {
        warmKeychainBrowsers.withLock { $0.removeAll() }
    }

    // MARK: - Internals

    /// Shared browser-access objects. Building one per import is the
    /// wrong shape for a batch: `BrowserDetection`'s probe cache and
    /// SweetCookieKit's decrypted-key state both live on the instance, while
    /// the localStorage cache prevents duplicate full-profile scans for clones.
    struct BrowserImportContext {
        let detection: BrowserDetection
        let client: BrowserCookieClient
        let localStorageCache: ChromiumLocalStorageCredentialImporter.Cache
        let homeDirectory: URL

        init(
            detection: BrowserDetection = BrowserDetection(),
            client: BrowserCookieClient = BrowserCookieClient(),
            localStorageCache: ChromiumLocalStorageCredentialImporter.Cache = .init(),
            homeDirectory: URL = RealHomeDirectory.url
        ) {
            self.detection = detection
            self.client = client
            self.localStorageCache = localStorageCache
            self.homeDirectory = homeDirectory
        }
    }

    struct BrowserImportResult {
        let header: String
        let sourceLabel: String
    }

    // MARK: - Shared silent-re-import context

    /// Serialises silent re-imports and guards `silentContext`.
    private static let silentContextLock = NSLock()
    private static var silentContext: (context: BrowserImportContext, builtAt: Date)?
    /// Long enough that a burst of provider re-imports shares one set of
    /// browser probes, short enough that installing a browser is picked up
    /// without a relaunch.
    private static let silentContextTTL: TimeInterval = 10 * 60

    /// Caller must hold `silentContextLock`.
    private static func sharedSilentContext(now: Date = Date()) -> BrowserImportContext {
        if let existing = silentContext,
           now >= existing.builtAt,
           now.timeIntervalSince(existing.builtAt) < silentContextTTL {
            return existing.context
        }
        let fresh = BrowserImportContext()
        silentContext = (fresh, now)
        return fresh
    }

    /// What one user-initiated import actually did.
    ///
    /// `blockedByCooldown` is scoped to *this* attempt: the browsers this
    /// walk was refused by or skipped over, never the process-wide denial
    /// map. That distinction is the whole point — a Kimi import reads
    /// Chromium localStorage and never touches the Keychain gate, so an
    /// unrelated Chrome cooldown must not turn its empty result into
    /// "Chrome Keychain access was declined".
    struct AttemptedImport {
        let session: BrowserImportResult?
        let blockedByCooldown: [BrowserCookieAccessGate.Cooldown]

        /// How to report an attempt that stored nothing.
        var emptyOutcome: BatchImportOutcome.Result {
            guard let blocked = blockedByCooldown.min(by: { $0.until < $1.until }) else {
                return .noSessionFound
            }
            return .keychainCooldown(browser: blocked.browserName, until: blocked.until)
        }
    }

    /// Mutable scratch for one walk. A plain class because the walk is
    /// synchronous and single-threaded; it never escapes the call.
    final class BrowserImportAttempt {
        private(set) var blocked: [BrowserCookieAccessGate.Cooldown] = []

        func record(_ cooldown: BrowserCookieAccessGate.Cooldown) {
            guard !blocked.contains(where: { $0.browserName == cooldown.browserName }) else { return }
            blocked.append(cooldown)
        }
    }

    /// Run one user-initiated import and report both the session it found
    /// and what got in the way, without touching the slot store.
    static func attemptBrowserImport(
        spec: Spec,
        settings: MiscProviderSettings,
        context: BrowserImportContext = BrowserImportContext(),
        now: Date = Date()
    ) -> AttemptedImport {
        let attempt = BrowserImportAttempt()
        let session = browserSessions(
            spec: spec,
            settings: settings,
            allowKeychainPrompt: true,
            context: context,
            maxSessions: 1,
            attempt: attempt,
            now: now
        ).first
        return AttemptedImport(session: session, blockedByCooldown: attempt.blocked)
    }

    /// Walk the candidate browsers and return every usable session for
    /// `spec`'s domains.
    ///
    /// `maxSessions: 1` reproduces the single-import behaviour exactly —
    /// stop at the first usable session so we never touch a browser we
    /// didn't need to. Pass `nil` only when the caller genuinely needs
    /// the full list (the silent re-import matches sessions to slots by
    /// label).
    static func browserSessions(
        spec: Spec,
        settings: MiscProviderSettings,
        allowKeychainPrompt: Bool,
        context: BrowserImportContext,
        maxSessions: Int?,
        attempt: BrowserImportAttempt = BrowserImportAttempt(),
        now: Date = Date()
    ) -> [BrowserImportResult] {
        let preferred: [Browser]
        if let kind = settings.preferredBrowser {
            preferred = kind.sweetCookieKitBrowsers
        } else {
            preferred = spec.importOrder
        }

        switch spec.browserCredentialSource {
        case .cookieJar:
            return cookieBrowserSessions(
                spec: spec,
                preferred: preferred,
                allowKeychainPrompt: allowKeychainPrompt,
                context: context,
                maxSessions: maxSessions,
                attempt: attempt,
                now: now
            )
        case let .chromiumLocalStorage(credential):
            return chromiumLocalStorageBrowserSessions(
                credentials: [credential],
                spec: spec,
                preferred: preferred,
                context: context,
                maxSessions: maxSessions
            )
        case let .chromiumLocalStorageFields(credentials):
            return chromiumLocalStorageBrowserSessions(
                credentials: credentials,
                spec: spec,
                preferred: preferred,
                context: context,
                maxSessions: maxSessions
            )
        }
    }

    private static func chromiumLocalStorageBrowserSessions(
        credentials: [ChromiumLocalStorageCredential],
        spec: Spec,
        preferred: [Browser],
        context: BrowserImportContext,
        maxSessions: Int?
    ) -> [BrowserImportResult] {
        let candidates = preferred
            .filter(\.usesChromiumProfileStore)
            .browsersWithProfileData(using: context.detection)
        guard !candidates.isEmpty else { return [] }
        let roots = ChromiumProfileLocator.roots(
            for: candidates,
            homeDirectories: [context.homeDirectory]
        )
        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credentials: credentials,
            roots: roots,
            cache: context.localStorageCache,
            maxSessions: maxSessions
        )
        return sessions.compactMap {
            guard let header = spec.minimizedHeader(from: $0.header) else { return nil }
            return BrowserImportResult(header: header, sourceLabel: $0.sourceLabel)
        }
    }

    /// Split a preference list into the browsers a *prompting* import may
    /// read right now and the ones the denial cooldown is holding back.
    ///
    /// "The user clicked Import" is permission to show a Keychain prompt;
    /// it is not permission to show the same prompt again for a browser
    /// whose prompt the user just declined — which is what the card means
    /// when it says Vibe Bar will not ask again until a stated time. The
    /// only way past a live cooldown is the explicit "Retry now" / "Reset
    /// browser-cookie cooldown" control, which clears the gate first.
    ///
    /// Filtering happens on the preference list rather than after
    /// `cookieImportCandidates`, so its one-Chromium-browser-per-click cap
    /// lands on the first browser we can actually read. A cooled-down
    /// browser is only reported as blocking *this* attempt when it is
    /// installed with usable cookie data — otherwise we would not have
    /// read it either way.
    static func cooldownPartition(
        _ preferred: [Browser],
        detection: BrowserDetection,
        now: Date = Date()
    ) -> (eligible: [Browser], blocked: [BrowserCookieAccessGate.Cooldown]) {
        var blocked: [BrowserCookieAccessGate.Cooldown] = []
        let eligible = preferred.filter { browser in
            guard let until = BrowserCookieAccessGate.blockedUntil(browser, now: now) else {
                return true
            }
            if detection.isCookieSourceAvailable(browser) {
                blocked.append(
                    BrowserCookieAccessGate.Cooldown(browserName: browser.displayName, until: until)
                )
            }
            return false
        }
        return (eligible, blocked)
    }

    private static func cookieBrowserSessions(
        spec: Spec,
        preferred: [Browser],
        allowKeychainPrompt: Bool,
        context: BrowserImportContext,
        maxSessions: Int?,
        attempt: BrowserImportAttempt = BrowserImportAttempt(),
        now: Date = Date()
    ) -> [BrowserImportResult] {
        let warm = allowKeychainPrompt ? [] : warmKeychainBrowserIDs
        // A silent read already consults the gate inside
        // `cookieImportCandidates`; a prompting one used to bypass it
        // entirely, so the prompt could reappear the moment the user
        // clicked Import again.
        let searchOrder: [Browser]
        if allowKeychainPrompt {
            let partition = cooldownPartition(preferred, detection: context.detection, now: now)
            partition.blocked.forEach(attempt.record)
            searchOrder = partition.eligible
        } else {
            searchOrder = preferred
        }
        let candidates = searchOrder.cookieImportCandidates(
            using: context.detection,
            allowKeychainPrompt: allowKeychainPrompt,
            warmKeychainBrowsers: warm
        )
        guard !candidates.isEmpty else { return [] }

        let query = BrowserCookieQuery(domains: spec.domains)

        var collected: [BrowserImportResult] = []
        for browser in candidates {
            let mayPrompt = allowKeychainPrompt || warm.contains(browser.rawValue)
            let records: [BrowserCookieStoreRecords]
            do {
                records = try context.client.vibeBarRecords(
                    matching: query,
                    in: browser,
                    allowKeychainPrompt: mayPrompt,
                    logger: nil
                )
            } catch {
                // A refusal that lands *now* belongs to this attempt just
                // as much as one carried over from an earlier click.
                if let cooldown = BrowserCookieAccessGate.recordIfNeeded(error, now: now) {
                    attempt.record(cooldown)
                }
                // A warm browser that suddenly refuses means the cached
                // Safe Storage key is gone (keychain relocked, browser
                // rotated it). Forget the warmth so we stop bypassing
                // the gate and risking a prompt the user didn't ask for.
                clearKeychainWarmth(browser)
                continue
            }
            if allowKeychainPrompt, !records.isEmpty {
                markKeychainWarm(browser)
            }
            for session in mergedSessions(from: records) {
                let cookies = session.records
                guard !cookies.isEmpty else { continue }
                let pairs = cookies.compactMap { record -> String? in
                    guard spec.requiredNames.isEmpty || spec.requiredNames.contains(record.name) else { return nil }
                    return "\(record.name)=\(record.value)"
                }
                guard spec.requiredNames.isEmpty || !pairs.isEmpty else { continue }
                let header = pairs.joined(separator: "; ")
                guard !header.isEmpty, spec.hasRequiredCredential(in: header) else { continue }
                collected.append(BrowserImportResult(header: header, sourceLabel: session.label))
                if let maxSessions, collected.count >= maxSessions { return collected }
            }
        }
        return collected
    }

    /// Hash a cookie header so a log line can say "did this change?"
    /// without writing the secret anywhere. Same idiom as
    /// `HiddenCookieRefresher`.
    static func headerFingerprint(_ header: String) -> String {
        guard !header.isEmpty else { return "empty" }
        var hash: UInt64 = 5381
        for byte in header.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    private struct BrowserSession {
        let label: String
        let records: [BrowserCookieRecord]
    }

    private static func mergedSessions(from sources: [BrowserCookieStoreRecords]) -> [BrowserSession] {
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        return grouped.values
            .sorted { lhs, rhs in mergedLabel(for: lhs) < mergedLabel(for: rhs) }
            .map { group in
                BrowserSession(label: mergedLabel(for: group), records: mergeRecords(group))
            }
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else {
            return "Unknown"
        }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted {
            storePriority($0.store.kind) < storePriority($1.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = recordKey(record)
                if let existing = mergedByKey[key] {
                    if shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?):
            rhs > lhs
        case (nil, .some):
            true
        case (.some, nil):
            false
        case (nil, nil):
            false
        }
    }

    private static func currentSettings(for tool: ToolType, instanceID: String) -> MiscProviderSettings {
        MiscProviderSettings.current(for: tool, instanceID: instanceID)
    }
}
