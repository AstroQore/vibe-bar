import Foundation
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

        public init(
            tool: ToolType,
            domains: [String],
            requiredNames: Set<String>,
            credentialNames: Set<String> = [],
            importOrder: BrowserCookieImportOrder = BrowserCookieDefaults.importOrder
        ) {
            self.tool = tool
            self.domains = domains
            self.requiredNames = requiredNames
            self.credentialNames = credentialNames
            self.importOrder = importOrder
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

    public struct Resolution {
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
        let settings = currentSettings(for: spec.tool)
        let filter = SlotFilter(settings: settings)
        guard filter != .none else { return [] }

        return MiscCookieSlotStore.slots(for: spec.tool).compactMap { slot in
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

    /// Run the SweetCookieKit browser-import dance and append the
    /// captured header as a new slot. Returns the appended slot's
    /// Resolution on success, or `nil` if no browser session was
    /// found (or the source mode bans cookies).
    public static func appendBrowserImport(for spec: Spec) -> Resolution? {
        let settings = currentSettings(for: spec.tool)
        guard SlotFilter(settings: settings) != .none else { return nil }
        guard let imported = importFromBrowsers(
            spec: spec,
            settings: settings,
            allowKeychainPrompt: true
        ) else {
            return nil
        }
        let slot = MiscCookieSlot(
            cookieHeader: imported.header,
            sourceLabel: imported.sourceLabel,
            importedAt: Date(),
            origin: .browserImport
        )
        guard MiscCookieSlotStore.append(slot, for: spec.tool) else { return nil }
        return Resolution(
            slotID: slot.id,
            header: imported.header,
            sourceLabel: imported.sourceLabel
        )
    }

    /// Legacy alias for callers that haven't migrated to
    /// `appendBrowserImport`. Slot semantics are identical — every
    /// invocation appends a new slot rather than replacing one.
    public static func forceBrowserImport(for spec: Spec) -> Resolution? {
        appendBrowserImport(for: spec)
    }

    // MARK: - Internals

    private struct BrowserImportResult {
        let header: String
        let sourceLabel: String
    }

    private static func importFromBrowsers(
        spec: Spec,
        settings: MiscProviderSettings,
        allowKeychainPrompt: Bool = false
    ) -> BrowserImportResult? {
        let detection = BrowserDetection()
        let preferred: [Browser]
        if let kind = settings.preferredBrowser {
            preferred = kind.sweetCookieKitBrowsers
        } else {
            preferred = spec.importOrder
        }
        let candidates = preferred.cookieImportCandidates(
            using: detection,
            allowKeychainPrompt: allowKeychainPrompt
        )
        guard !candidates.isEmpty else { return nil }

        let query = BrowserCookieQuery(domains: spec.domains)

        let client = BrowserCookieClient()
        for browser in candidates {
            let records: [BrowserCookieStoreRecords]
            do {
                records = try client.vibeBarRecords(
                    matching: query,
                    in: browser,
                    allowKeychainPrompt: allowKeychainPrompt,
                    logger: nil
                )
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                continue
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
                return BrowserImportResult(header: header, sourceLabel: session.label)
            }
        }
        return nil
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

    private static func currentSettings(for tool: ToolType) -> MiscProviderSettings {
        MiscProviderSettings.current(for: tool)
    }
}
