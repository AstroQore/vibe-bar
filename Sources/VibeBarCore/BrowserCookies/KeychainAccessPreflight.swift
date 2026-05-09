import Foundation
import LocalAuthentication
import Security

/// Non-interactive Keychain probe.
///
/// Checks whether `SecItemCopyMatching` would succeed without a UI
/// prompt for a given service / account, and returns one of four
/// outcomes:
///
/// - `.allowed` — the item exists and is readable now.
/// - `.interactionRequired` — the item exists but reading it would
///   trigger a system Keychain prompt; back off and don't ask.
/// - `.notFound` — no such item.
/// - `.failure(status)` — anything else; surface the OSStatus.
///
/// Used by `BrowserCookieAccessGate` to decide whether trying to read
/// a Chromium "Safe Storage" entry will silently succeed or annoy the
/// user. Ported from codexbar `KeychainAccessPreflight.swift`,
/// dropping the `KeychainPromptHandler` UX scaffolding since vibe-bar
/// doesn't have an equivalent overlay yet.
public enum KeychainAccessPreflight {
    public enum Outcome: Sendable, Equatable {
        case allowed
        case interactionRequired
        case notFound
        case failure(Int)
    }

    public static func checkGenericPassword(
        service: String,
        account: String?,
        skipItemsRequiringUI: Bool = false
    ) -> Outcome {
        guard !KeychainAccessGate.isDisabled else { return .notFound }
        let query = makeGenericPasswordPreflightQuery(
            service: service,
            account: account,
            skipItemsRequiringUI: skipItemsRequiringUI
        )

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .allowed
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            SafeLog.warn("Keychain preflight unexpected status \(status) for \(service)")
            return .failure(Int(status))
        }
    }

    static func makeGenericPasswordPreflightQuery(
        service: String,
        account: String?,
        skipItemsRequiringUI: Bool = false
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Preflight should never trigger UI. Avoid `kSecReturnData`
            // — some macOS configurations have been observed to show
            // the legacy keychain prompt for Safe Storage entries
            // unless the query is strictly non-interactive.
            kSecReturnAttributes as String: true
        ]
        KeychainNoUIQuery.apply(
            to: &query,
            uiPolicy: skipItemsRequiringUI ? .skip : .fail
        )
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}
