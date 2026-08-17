import Foundation

/// Resolves one Cursor account without mixing identities.
///
/// Automatic mode prefers Cursor.app's active session. Browser/manual cookie
/// slots remain a fallback for machines where Cursor.app is absent or logged
/// out, and preserve the existing `misc-cursor` Keychain account during the
/// move from the Misc page into the Grok product family.
enum CursorSessionResolver {
    static let stableAccountID = AccountStore.miscAccountId(for: .cursor)

    static func resolutions(
        account: AccountIdentity? = nil,
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date()
    ) -> [MiscCookieResolver.Resolution] {
        if let session = try? CursorAppAuthStore(homeDirectory: homeDirectory).loadSession(now: now),
           let header = try? session.cookieHeader() {
            return [
                MiscCookieResolver.Resolution(
                    slotID: nil,
                    header: header,
                    sourceLabel: "Cursor.app"
                )
            ]
        }

        if let account {
            return MiscCookieResolver.resolveAll(for: CursorQuotaAdapter.cookieSpec, account: account)
        }
        return MiscCookieResolver.resolveAll(
            for: CursorQuotaAdapter.cookieSpec,
            instanceID: ToolType.cursor.rawValue
        )
    }

    static func accountIdentity(
        homeDirectory: String = RealHomeDirectory.path,
        now: Date = Date()
    ) -> AccountIdentity {
        let appSession = try? CursorAppAuthStore(homeDirectory: homeDirectory).loadSession(now: now)
        let identity = appSession?.identity
        let hasCookieFallback = MiscCookieSlotStore.hasAnySlot(for: .cursor)
        let source: CredentialSource = appSession != nil
            ? .cliDetected
            : (hasCookieFallback ? .browserCookie : .notConfigured)
        return AccountIdentity(
            id: stableAccountID,
            tool: .cursor,
            email: identity?.email,
            alias: "Cursor Agent",
            source: source,
            allowsWebFallback: hasCookieFallback,
            allowsCLIFallback: appSession != nil,
            allowsOAuthFallback: false,
            createdAt: now,
            updatedAt: now
        )
    }
}
