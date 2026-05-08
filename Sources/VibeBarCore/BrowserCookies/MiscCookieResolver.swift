import Foundation
import SweetCookieKit

/// Picks a `Cookie:` header for a misc-provider adapter at fetch time.
///
/// Resolution order (skipped per `MiscProviderSettings.cookieSource`):
///
/// 1. **Cached** — Keychain entry from a prior successful import.
///    Returned immediately if present.
/// 2. **Browser auto-import** (when `cookieSource ∈ [.auto, .browserOnly]`) —
///    SweetCookieKit reads cookies for the provider's domains from
///    every browser in the configured order; the first non-empty
///    match wins, gets minimised to the auth-cookie set, and is
///    cached.
/// 3. **Manual paste** (when `cookieSource ∈ [.auto, .manualOnly]`) —
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
        let cookieSource = settings.cookieSource

        // Off — never try a cookie path.
        if cookieSource == .off {
            return nil
        }

        // 1. Cached header from a prior import or manual paste.
        if let cached = CookieHeaderCache.load(for: spec.tool) {
            return Resolution(header: cached.cookieHeader, sourceLabel: cached.sourceLabel)
        }

        // 2. Browser auto-import (skipped in `.manual` mode).
        if cookieSource != .manual,
           let imported = importFromBrowsers(spec: spec, settings: settings) {
            CookieHeaderCache.store(
                for: spec.tool,
                cookieHeader: imported.header,
                sourceLabel: imported.sourceLabel
            )
            return imported
        }

        // 3. Manual paste fallback.
        if let manual = MiscCredentialStore.readString(tool: spec.tool, kind: .manualCookieHeader),
           let normalised = CookieHeaderNormalizer.filteredHeader(
               from: manual,
               allowedNames: spec.requiredNames
           ),
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
        guard let imported = importFromBrowsers(spec: spec, settings: settings) else {
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
        settings: MiscProviderSettings
    ) -> Resolution? {
        let detection = BrowserDetection()
        let preferred: [Browser]
        if let kind = settings.preferredBrowser {
            preferred = kind.sweetCookieKitBrowsers
        } else {
            preferred = spec.importOrder
        }
        let candidates = preferred.cookieImportCandidates(using: detection)
        guard !candidates.isEmpty else { return nil }

        let query = BrowserCookieQuery(
            domains: spec.domains,
            domainMatch: .suffix,
            origin: .domainBased
        )

        let client = BrowserCookieClient()
        for browser in candidates {
            let records: [BrowserCookieStoreRecords]
            do {
                records = try client.vibeBarRecords(matching: query, in: browser, logger: nil)
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                continue
            }
            for storeRecords in records {
                let cookies = storeRecords.records
                guard !cookies.isEmpty else { continue }
                let pairs = cookies.compactMap { record -> String? in
                    guard spec.requiredNames.contains(record.name) else { return nil }
                    return "\(record.name)=\(record.value)"
                }
                guard !pairs.isEmpty else { continue }
                let header = pairs.joined(separator: "; ")
                let label = "\(browser.displayName) (\(storeRecords.store.profile.name))"
                return Resolution(header: header, sourceLabel: label)
            }
        }
        return nil
    }

    private static func currentSettings(for tool: ToolType) -> MiscProviderSettings {
        let appSettings = (try? VibeBarLocalStore.readJSON(
            AppSettings.self,
            from: VibeBarLocalStore.settingsURL
        )) ?? .default
        return appSettings.miscProvider(tool)
    }
}
