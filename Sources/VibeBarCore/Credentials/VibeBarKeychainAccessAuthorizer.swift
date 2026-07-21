import Darwin
import Foundation
import Security

/// Password-assisted migration and repair for Vibe Bar's single credential
/// vault. The password stays in memory and is used only to unlock the login
/// keychain through Security.framework; it is never persisted or passed to a
/// child process.
public enum VibeBarKeychainAccessAuthorizer {
    public struct Target: Hashable, Sendable, Equatable {
        public let service: String
        public let account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    public struct Failure: Sendable, Equatable {
        public let target: Target
        public let status: Int

        public init(target: Target, status: Int) {
            self.target = target
            self.status = status
        }
    }

    public struct Report: Sendable, Equatable {
        public let targetCount: Int
        public let authorized: [Target]
        public let missing: [Target]
        public let failures: [Failure]
        public let vaultEntryCount: Int
        public let migratedItemCount: Int

        public var authorizedCount: Int { authorized.count }
        public var missingCount: Int { missing.count }
        public var failureCount: Int { failures.count }

        public init(
            targetCount: Int,
            authorized: [Target],
            missing: [Target],
            failures: [Failure],
            vaultEntryCount: Int = 0,
            migratedItemCount: Int = 0
        ) {
            self.targetCount = targetCount
            self.authorized = authorized
            self.missing = missing
            self.failures = failures
            self.vaultEntryCount = vaultEntryCount
            self.migratedItemCount = migratedItemCount
        }
    }

    public enum AuthorizationError: Error, Equatable {
        case emptyPassword
        case unlockFailed(Int)
        case trustedApplicationFailed(Int)
        case accessCreateFailed(Int)
        case invalidVault
        case vaultWriteFailed
    }

    private static let legacyMiscService = "com.astroqore.VibeBar.misc"
    private static let legacyClaudeWebService = "Vibe Bar Claude Web Cookies"

    /// The only current Keychain item owned by Vibe Bar.
    public static var currentOwnedTargets: [Target] {
        [vaultTarget]
    }

    /// Historical stores that are scanned only during explicit migration.
    /// They are never pre-created and no longer contribute placeholder rows.
    public static var legacyOwnedTargets: [Target] {
        knownMigrationTargets
    }

    public static var ownedTargets: [Target] {
        [vaultTarget]
    }

    public static func authorizeExistingOwnedItems(
        loginKeychainPassword password: String
    ) throws -> Report {
        var passwordBytes = Array(password.utf8)
        guard !passwordBytes.isEmpty else {
            throw AuthorizationError.emptyPassword
        }
        defer {
            passwordBytes.withUnsafeMutableBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    memset(base, 0, buffer.count)
                }
            }
        }

        let unlockStatus = passwordBytes.withUnsafeBufferPointer { buffer in
            SecKeychainUnlock(nil, UInt32(buffer.count), buffer.baseAddress, true)
        }
        guard unlockStatus == errSecSuccess else {
            throw AuthorizationError.unlockFailed(Int(unlockStatus))
        }
        let access = try currentApplicationAccess()

        let discovered = discoverExistingTargets()
        let existingVault = discovered.contains(vaultTarget)
        let existingStagingVaults = discovered.filter(isStagingVault)
        let migrationTargets = discovered.filter { $0 != vaultTarget && !isStagingVault($0) }
        var payload = VibeBarCredentialVault.Payload()
        var migrated: [Target] = []
        var failures: [Failure] = []

        for stagingTarget in existingStagingVaults {
            do {
                let data = try extractSecret(for: stagingTarget, access: access)
                let staged = try VibeBarCredentialVault.decodePayload(data)
                for entry in staged.entries {
                    payload.set(entry.data, service: entry.service, account: entry.account)
                }
                migrated.append(stagingTarget)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: stagingTarget, status: Int(error.status)))
            } catch {
                throw AuthorizationError.invalidVault
            }
        }

        if existingVault {
            do {
                let data = try extractSecret(for: vaultTarget, access: access)
                let existing = try VibeBarCredentialVault.decodePayload(data)
                for entry in existing.entries {
                    payload.set(entry.data, service: entry.service, account: entry.account)
                }
                migrated.append(vaultTarget)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: vaultTarget, status: Int(error.status)))
            } catch {
                throw AuthorizationError.invalidVault
            }
        }

        for target in migrationTargets {
            do {
                let data = try extractSecret(for: target, access: access)
                payload.set(data, service: target.service, account: target.account)
                migrated.append(target)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: target, status: Int(error.status)))
            }
        }

        // Never replace an unreadable vault: that would discard secrets which
        // the current build could not decrypt.
        if existingVault,
           !migrated.contains(vaultTarget),
           !existingStagingVaults.contains(where: { migrated.contains($0) }) {
            return Report(
                targetCount: discovered.count,
                authorized: migrated,
                missing: [],
                failures: failures,
                vaultEntryCount: 0,
                migratedItemCount: max(0, migrated.count)
            )
        }

        // Write a recovery copy with the current app identity before touching
        // the old vault. If the final add fails, the next repair can recover
        // every entry from this staging item.
        let recoveryTarget = Target(
            service: VibeBarCredentialVault.keychainService,
            account: VibeBarCredentialVault.stagingKeychainAccountPrefix + "." + UUID().uuidString
        )
        do {
            try KeychainStore.writeData(
                service: recoveryTarget.service,
                account: recoveryTarget.account,
                data: try VibeBarCredentialVault.encodePayload(payload)
            )
        } catch {
            throw AuthorizationError.vaultWriteFailed
        }

        if existingVault {
            do {
                try deleteKeychainItem(vaultTarget)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: vaultTarget, status: Int(error.status)))
                throw AuthorizationError.vaultWriteFailed
            }
        }

        do {
            try VibeBarCredentialVault.replacePayload(payload)
        } catch {
            throw AuthorizationError.vaultWriteFailed
        }

        try? KeychainStore.deleteItem(
            service: recoveryTarget.service,
            account: recoveryTarget.account
        )

        for stagingTarget in existingStagingVaults where migrated.contains(stagingTarget) {
            do {
                try deleteKeychainItem(stagingTarget)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: stagingTarget, status: Int(error.status)))
            }
        }

        // Transaction boundary: old entries are removed only after the new
        // single-item vault is safely written.
        for target in migrationTargets where migrated.contains(target) {
            do {
                try deleteKeychainItem(target)
            } catch let error as KeychainOperationError {
                failures.append(Failure(target: target, status: Int(error.status)))
            }
        }

        return Report(
            targetCount: discovered.count,
            authorized: migrated,
            missing: [],
            failures: failures,
            vaultEntryCount: payload.entries.count,
            migratedItemCount: migrationTargets.filter { migrated.contains($0) }.count
        )
    }

    private struct KeychainOperationError: Error {
        let status: OSStatus
    }

    private static var vaultTarget: Target {
        Target(
            service: VibeBarCredentialVault.keychainService,
            account: VibeBarCredentialVault.keychainAccount
        )
    }

    private static var ownedServiceNames: [String] {
        [
            VibeBarCredentialVault.keychainService,
            SecureCookieHeaderStore.keychainService,
            MiscCredentialStore.keychainService,
            WebFormCredentialStore.keychainService,
            legacyMiscService,
            legacyClaudeWebService
        ]
    }

    private static func discoverExistingTargets() -> [Target] {
        var targets = Set<Target>()
        for service in ownedServiceNames {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            KeychainNoUIQuery.apply(to: &query, uiPolicy: .skip)
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
                continue
            }
            let dictionaries: [[String: Any]]
            if let list = result as? [[String: Any]] {
                dictionaries = list
            } else if let one = result as? [String: Any] {
                dictionaries = [one]
            } else {
                dictionaries = []
            }
            for attributes in dictionaries {
                if let account = attributes[kSecAttrAccount as String] as? String {
                    targets.insert(Target(service: service, account: account))
                }
            }
        }

        // Attribute enumeration varies between older macOS Keychain formats;
        // direct lookups make the known historical accounts deterministic.
        for target in [vaultTarget] + knownMigrationTargets {
            if findGenericPasswordItem(target).status == errSecSuccess {
                targets.insert(target)
            }
        }
        return targets.sorted(by: targetSort)
    }

    private static func extractSecret(for target: Target, access: SecAccess) throws -> Data {
        let lookup = findGenericPasswordItem(target)
        guard lookup.status == errSecSuccess, let item = lookup.item else {
            throw KeychainOperationError(status: lookup.status)
        }

        // Reset the ACL only after the user explicitly unlocks the login
        // keychain in Settings. The read below is then non-interactive, so a
        // rebuild never fans out into one system prompt per old secret.
        let accessStatus = SecKeychainItemSetAccess(item, access)
        guard accessStatus == errSecSuccess else {
            throw KeychainOperationError(status: accessStatus)
        }

        do {
            return try KeychainStore.readData(service: target.service, account: target.account)
        } catch let KeychainStore.KeychainError.unhandledStatus(status) {
            throw KeychainOperationError(status: status)
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            throw KeychainOperationError(status: errSecInteractionNotAllowed)
        } catch {
            throw KeychainOperationError(status: errSecItemNotFound)
        }
    }

    private static func deleteKeychainItem(_ target: Target) throws {
        let lookup = findGenericPasswordItem(target)
        guard lookup.status == errSecSuccess, let item = lookup.item else {
            throw KeychainOperationError(status: lookup.status)
        }
        let status = SecKeychainItemDelete(item)
        guard status == errSecSuccess else {
            throw KeychainOperationError(status: status)
        }
    }

    private static func currentApplicationAccess() throws -> SecAccess {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw AuthorizationError.trustedApplicationFailed(Int(trustedStatus))
        }

        let trustedList = [trustedApplication] as CFArray
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Vibe Bar Credential Vault" as CFString,
            trustedList,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw AuthorizationError.accessCreateFailed(Int(accessStatus))
        }
        return access
    }

    private static func findGenericPasswordItem(_ target: Target) -> (item: SecKeychainItem?, status: OSStatus) {
        var item: SecKeychainItem?
        let status = target.service.withCString { servicePtr in
            target.account.withCString { accountPtr in
                SecKeychainFindGenericPassword(
                    nil,
                    UInt32(strlen(servicePtr)),
                    servicePtr,
                    UInt32(strlen(accountPtr)),
                    accountPtr,
                    nil,
                    nil,
                    &item
                )
            }
        }
        return (item, status)
    }

    private static func targetSort(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.service == rhs.service ? lhs.account < rhs.account : lhs.service < rhs.service
    }

    private static func isStagingVault(_ target: Target) -> Bool {
        target.service == VibeBarCredentialVault.keychainService &&
            target.account.hasPrefix(VibeBarCredentialVault.stagingKeychainAccountPrefix + ".")
    }

    private static var knownMigrationTargets: [Target] {
        var targets: [Target] = [
            Target(service: legacyClaudeWebService, account: "claude.ai"),
            Target(service: legacyClaudeWebService, account: "claude.ai.organization"),
            Target(service: SecureCookieHeaderStore.keychainService, account: "claude.organization-id")
        ]
        for provider in [
            SecureCookieHeaderStore.Provider.openAI,
            .claude,
            .gemini,
            .grok
        ] {
            for source in SecureCookieHeaderStore.Source.allCases {
                targets.append(Target(
                    service: SecureCookieHeaderStore.keychainService,
                    account: SecureCookieHeaderStore.account(provider: provider, source: source)
                ))
            }
        }
        for tool in ToolType.miscProviders {
            targets.append(Target(
                service: MiscCookieSlotStore.keychainService,
                account: MiscCookieSlotStore.keychainAccount(for: tool)
            ))
            targets.append(Target(service: legacyMiscService, account: "cookie.\(tool.rawValue)"))
            for kind in MiscCredentialStore.Kind.allCases {
                targets.append(Target(
                    service: MiscCredentialStore.keychainService,
                    account: MiscCredentialStore.keychainAccount(tool: tool, kind: kind)
                ))
                targets.append(Target(
                    service: legacyMiscService,
                    account: MiscCredentialStore.keychainAccount(tool: tool, kind: kind)
                ))
            }
            targets.append(Target(
                service: WebFormCredentialStore.keychainService,
                account: WebFormCredentialStore.keychainAccount(tool: tool)
            ))
        }
        return Array(Set(targets)).sorted(by: targetSort)
    }
}
