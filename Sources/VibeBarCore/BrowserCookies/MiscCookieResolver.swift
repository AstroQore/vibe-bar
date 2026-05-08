import Foundation
import SweetCookieKit

/// Picks a `Cookie:` header for a misc-provider adapter at fetch time.
///
/// Resolution order (skipped per `MiscProviderSettings.cookieSource`):
///
/// 1. **Cached** — Keychain entry from a prior successful import.
///    Returned immediately if present.
/// 2. **Browser auto-import** (when source mode permits browser cookies) —
///    SweetCookieKit reads cookies for the provider's domains from
///    every browser in the configured order. Records from the same
///    browser profile are merged across cookie stores before the
///    auth-cookie set is minimized and cached, matching Codex Bar's
///    Kimi/MiniMax/Cursor importers.
/// 3. **Manual paste** (when source mode permits manual cookies) —
///    the value the user pasted in Settings, normalised through
///    `CookieHeaderNormalizer`.
///
/// Adapters call `resolve(for:)` and translate "no header" into a
/// `QuotaError.noCredential` that surfaces a "Sign in" CTA on the
/// misc card.
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
        /// Default browser-import order if the user hasn't picked
        /// `MiscProviderSettings.preferredBrowser`.
        public let importOrder: BrowserCookieImportOrder

        public init(
            tool: ToolType,
            domains: [String],
            requiredNames: Set<String>,
            importOrder: BrowserCookieImportOrder = BrowserCookieDefaults.importOrder
        ) {
            self.tool = tool
            self.domains = domains
            self.requiredNames = requiredNames
            self.importOrder = importOrder
        }
    }

    public struct Resolution {
        public let header: String
        public let sourceLabel: String
    }

    /// Resolve a cookie header for `spec.tool`. Returns `nil` if the
    /// configured sources all came up empty — adapters surface
    /// `noCredential` in that case.
    public static func resolve(for spec: Spec) -> Resolution? {
        let settings = currentSettings(for: spec.tool)
        guard let plan = CookieSourcePlan(settings: settings) else {
            return nil
        }

        // 1. Cached header from a prior import or manual paste.
        if let cached = CookieHeaderCache.load(for: spec.tool),
           plan.acceptsCached(cached) {
            return Resolution(header: cached.cookieHeader, sourceLabel: cached.sourceLabel)
        }

        // 2. Browser auto-import (skipped in `.manual` mode).
        if plan.allowsBrowser,
           let imported = importFromBrowsers(spec: spec, settings: settings) {
            CookieHeaderCache.store(
                for: spec.tool,
                cookieHeader: imported.header,
                sourceLabel: imported.sourceLabel
            )
            return imported
        }

        // 3. Manual paste fallback.
        if plan.allowsManual,
           let manual = MiscCredentialStore.readString(tool: spec.tool, kind: .manualCookieHeader),
           let normalised = minimizedHeader(from: manual, allowedNames: spec.requiredNames),
           !normalised.isEmpty {
            CookieHeaderCache.store(
                for: spec.tool,
                cookieHeader: normalised,
                sourceLabel: "Manual paste"
            )
            return Resolution(header: normalised, sourceLabel: "Manual paste")
        }

        return nil
    }

    /// Force a fresh browser import, ignoring the cache. Settings UI
    /// uses this for the "Import now" button so the user can recover
    /// without waiting for a stale cache to expire.
    public static func forceBrowserImport(for spec: Spec) -> Resolution? {
        CookieHeaderCache.clear(for: spec.tool)
        let settings = currentSettings(for: spec.tool)
        guard CookieSourcePlan(settings: settings)?.allowsBrowser == true else {
            return nil
        }
        guard let imported = importFromBrowsers(
            spec: spec,
            settings: settings,
            allowKeychainPrompt: true
        ) else {
            return nil
        }
        CookieHeaderCache.store(
            for: spec.tool,
            cookieHeader: imported.header,
            sourceLabel: imported.sourceLabel
        )
        return imported
    }

    // MARK: - Internals

    private static func importFromBrowsers(
        spec: Spec,
        settings: MiscProviderSettings,
        allowKeychainPrompt: Bool = false
    ) -> Resolution? {
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
                guard !header.isEmpty else { continue }
                return Resolution(header: header, sourceLabel: session.label)
            }
        }
        return nil
    }

    private struct BrowserSession {
        let label: String
        let records: [BrowserCookieRecord]
    }

    private struct CookieSourcePlan {
        let allowsBrowser: Bool
        let allowsManual: Bool
        let cachePolicy: CachePolicy

        enum CachePolicy {
            case any
            case browserOnly
            case manualOnly
        }

        init?(settings: MiscProviderSettings) {
            switch settings.sourceMode {
            case .off, .apiOnly:
                return nil
            case .browserOnly:
                self.allowsBrowser = true
                self.allowsManual = false
                self.cachePolicy = .browserOnly
                return
            case .manualOnly:
                self.allowsBrowser = false
                self.allowsManual = true
                self.cachePolicy = .manualOnly
                return
            case .auto:
                switch settings.cookieSource {
                case .off:
                    return nil
                case .manual:
                    self.allowsBrowser = false
                    self.allowsManual = true
                    self.cachePolicy = .manualOnly
                    return
                case .auto:
                    self.allowsBrowser = true
                    self.allowsManual = true
                    self.cachePolicy = .any
                    return
                }
            }
        }

        func acceptsCached(_ entry: CookieHeaderCache.Entry) -> Bool {
            let isManual = entry.sourceLabel == "Manual paste"
            switch cachePolicy {
            case .any:
                return true
            case .browserOnly:
                return !isManual
            case .manualOnly:
                return isManual
            }
        }
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

    private static func minimizedHeader(from raw: String?, allowedNames: Set<String>) -> String? {
        if allowedNames.isEmpty {
            return CookieHeaderNormalizer.normalize(raw)
        }
        return CookieHeaderNormalizer.filteredHeader(from: raw, allowedNames: allowedNames)
    }

    private static func currentSettings(for tool: ToolType) -> MiscProviderSettings {
        MiscProviderSettings.current(for: tool)
    }
}
