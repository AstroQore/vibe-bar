import Foundation

/// Keychain-backed store for misc-provider secrets.
///
/// All sensitive values for the eight misc providers live under one
/// Keychain service (`com.astroqore.VibeBar.misc-secrets`); the account
/// names follow `<provider-rawValue>.<kind>`. The matching
/// non-sensitive fields (region, source mode, enterprise host) live
/// in `~/.vibebar/settings.json` — see `MiscProviderSettings`.
public enum MiscCredentialStore {
    public static let keychainService = "com.astroqore.VibeBar.misc-secrets"
    private static let legacyKeychainService = "com.astroqore.VibeBar.misc"

    /// Account-name suffixes for the secret kinds vibe-bar's misc
    /// adapters need. Adding a new kind requires updating this enum
    /// (and the per-provider Settings UI that writes to it).
    public enum Kind: String, CaseIterable, Sendable {
        case apiKey
        case manualCookieHeader
        case importedCookieHeader
        case oauthAccessToken
        case oauthRefreshToken
        case oauthExpiry
    }

    public static func keychainAccount(tool: ToolType, kind: Kind) -> String {
        precondition(tool.isMisc, "MiscCredentialStore is misc-only; got \(tool)")
        return "\(tool.rawValue).\(kind.rawValue)"
    }

    public static func readString(tool: ToolType, kind: Kind) -> String? {
        guard tool.isMisc else { return nil }
        let account = keychainAccount(tool: tool, kind: kind)
        if let value = try? KeychainStore.readString(
            service: keychainService,
            account: account,
            useDataProtectionKeychain: true
        ) {
            return value
        }

        return readLegacyString(tool: tool, kind: kind, account: account)
    }

    @discardableResult
    public static func writeString(_ value: String, tool: ToolType, kind: Kind) -> Bool {
        guard tool.isMisc else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(tool: tool, kind: kind)
        }
        do {
            try KeychainStore.writeString(
                service: keychainService,
                account: keychainAccount(tool: tool, kind: kind),
                value: trimmed,
                useDataProtectionKeychain: true
            )
            return true
        } catch {
            SafeLog.error("Misc keychain write failed for \(tool.rawValue).\(kind.rawValue): \(error)")
            return false
        }
    }

    @discardableResult
    public static func delete(tool: ToolType, kind: Kind) -> Bool {
        guard tool.isMisc else { return false }
        do {
            try KeychainStore.deleteItem(
                service: keychainService,
                account: keychainAccount(tool: tool, kind: kind),
                useDataProtectionKeychain: true
            )
            deleteLegacyMigratedValue(tool: tool, kind: kind)
            return true
        } catch KeychainStore.KeychainError.itemNotFound {
            deleteLegacyMigratedValue(tool: tool, kind: kind)
            return false
        } catch {
            SafeLog.warn("Misc keychain delete failed for \(tool.rawValue).\(kind.rawValue): \(error)")
            return false
        }
    }

    public static func hasValue(tool: ToolType, kind: Kind) -> Bool {
        readString(tool: tool, kind: kind) != nil
    }

    /// Wipe every Keychain entry vibe-bar holds for one misc tool.
    /// Used by Settings → "Clear stored credentials".
    public static func clearAll(for tool: ToolType) {
        guard tool.isMisc else { return }
        for kind in Kind.allCases {
            delete(tool: tool, kind: kind)
        }
    }

    private static func readLegacyString(tool: ToolType, kind: Kind, account: String) -> String? {
        for backend in LegacyKeychainMigrationPolicy.backendsForAutomaticMigration {
            switch backend {
            case .dataProtection:
                guard let legacy = try? KeychainStore.readStringFromDataProtectionKeychainOnly(
                    service: legacyKeychainService,
                    account: account
                ) else {
                    continue
                }

                _ = writeString(legacy, tool: tool, kind: kind)
                try? KeychainStore.deleteItemFromDataProtectionKeychainOnly(
                    service: legacyKeychainService,
                    account: account
                )
                return legacy
            }
        }
        return nil
    }

    private static func deleteLegacyMigratedValue(tool: ToolType, kind: Kind) {
        try? KeychainStore.deleteItemFromDataProtectionKeychainOnly(
            service: legacyKeychainService,
            account: keychainAccount(tool: tool, kind: kind)
        )
    }
}
