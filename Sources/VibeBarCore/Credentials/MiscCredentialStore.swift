import Foundation

/// Keychain-backed store for misc-provider secrets.
///
/// All sensitive values for misc providers live under one
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
        // Volcengine signs its OpenAPI with an AK/SK pair (Signature V4),
        // not a single bearer token — so it needs two slots. See
        // `VolcengineSignerV4` and the Volcengine adapters.
        case accessKeyID
        case secretAccessKey
    }

    public static func keychainAccount(tool: ToolType, kind: Kind) -> String {
        keychainAccount(tool: tool, kind: kind, instanceID: tool.rawValue)
    }

    public static func keychainAccount(tool: ToolType, kind: Kind, instanceID: String) -> String {
        precondition(tool.isMisc, "MiscCredentialStore is misc-only; got \(tool)")
        if instanceID == tool.rawValue {
            return "\(tool.rawValue).\(kind.rawValue)"
        }
        return "\(instanceID).\(kind.rawValue)"
    }

    public static func readString(tool: ToolType, kind: Kind) -> String? {
        readString(tool: tool, kind: kind, instanceID: tool.rawValue)
    }

    public static func readString(tool: ToolType, kind: Kind, instanceID: String) -> String? {
        guard tool.isMisc else { return nil }
        let account = keychainAccount(tool: tool, kind: kind, instanceID: instanceID)
        if let value = try? VibeBarCredentialVault.readString(
            service: keychainService,
            account: account
        ) {
            return value
        }

        guard instanceID == tool.rawValue else { return nil }
        return readLegacyString(tool: tool, kind: kind, account: account)
    }

    @discardableResult
    public static func writeString(_ value: String, tool: ToolType, kind: Kind) -> Bool {
        writeString(value, tool: tool, kind: kind, instanceID: tool.rawValue)
    }

    @discardableResult
    public static func writeString(_ value: String, tool: ToolType, kind: Kind, instanceID: String) -> Bool {
        guard tool.isMisc else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(tool: tool, kind: kind, instanceID: instanceID)
        }
        do {
            try VibeBarCredentialVault.writeString(
                service: keychainService,
                account: keychainAccount(tool: tool, kind: kind, instanceID: instanceID),
                value: trimmed
            )
            return true
        } catch {
            SafeLog.error("Misc keychain write failed for \(tool.rawValue).\(kind.rawValue): \(error)")
            return false
        }
    }

    @discardableResult
    public static func delete(tool: ToolType, kind: Kind) -> Bool {
        delete(tool: tool, kind: kind, instanceID: tool.rawValue)
    }

    @discardableResult
    public static func delete(tool: ToolType, kind: Kind, instanceID: String) -> Bool {
        guard tool.isMisc else { return false }
        do {
            try VibeBarCredentialVault.delete(
                service: keychainService,
                account: keychainAccount(tool: tool, kind: kind, instanceID: instanceID)
            )
            if instanceID == tool.rawValue {
                deleteLegacyMigratedValue(tool: tool, kind: kind)
            }
            return true
        } catch KeychainStore.KeychainError.itemNotFound {
            if instanceID == tool.rawValue {
                deleteLegacyMigratedValue(tool: tool, kind: kind)
            }
            return false
        } catch {
            SafeLog.warn("Misc keychain delete failed for \(tool.rawValue).\(kind.rawValue): \(error)")
            return false
        }
    }

    public static func hasValue(tool: ToolType, kind: Kind) -> Bool {
        readString(tool: tool, kind: kind) != nil
    }

    public static func hasValue(tool: ToolType, kind: Kind, instanceID: String) -> Bool {
        readString(tool: tool, kind: kind, instanceID: instanceID) != nil
    }

    /// Wipe every Keychain entry vibe-bar holds for one misc tool.
    /// Used by Settings → "Clear stored credentials".
    public static func clearAll(for tool: ToolType) {
        clearAll(for: tool, instanceID: tool.rawValue)
    }

    public static func clearAll(for tool: ToolType, instanceID: String) {
        guard tool.isMisc else { return }
        for kind in Kind.allCases {
            delete(tool: tool, kind: kind, instanceID: instanceID)
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
