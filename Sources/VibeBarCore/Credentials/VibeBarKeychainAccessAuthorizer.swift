import Darwin
import Foundation
import Security

/// User-initiated repair for Vibe Bar-owned login-keychain items.
///
/// Source builds are usually ad-hoc signed, so every rebuild can look like
/// a different app to macOS Keychain ACLs. Background refreshes stay
/// non-interactive; this helper is called only from Settings after the
/// user explicitly provides the login-keychain password for this one
/// operation.
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

        public var authorizedCount: Int { authorized.count }
        public var missingCount: Int { missing.count }
        public var failureCount: Int { failures.count }

        public init(
            targetCount: Int,
            authorized: [Target],
            missing: [Target],
            failures: [Failure]
        ) {
            self.targetCount = targetCount
            self.authorized = authorized
            self.missing = missing
            self.failures = failures
        }
    }

    public enum AuthorizationError: Error, Equatable {
        case emptyPassword
        case unlockFailed(Int)
        case trustedApplicationFailed(Int)
        case accessCreateFailed(Int)
    }

    private static let legacyMiscService = "com.astroqore.VibeBar.misc"
    private static let legacyClaudeWebService = "Vibe Bar Claude Web Cookies"
    private static let legacyClaudeCookieAccount = "claude.ai"
    private static let legacyClaudeOrganizationAccount = "claude.ai.organization"
    private static let claudeOrganizationAccount = "claude.organization-id"
    /// Misc providers that stack their cookie sessions through
    /// `MiscCookieSlotStore`. The list mirrors every cookie-only adapter
    /// plus Alibaba (cookie path is one of two auth modes).
    private static let currentCookieBackedMiscTools: [ToolType] = [
        .alibaba, .kimi, .cursor, .mimo, .iflytek,
        .tencentHunyuan, .volcengine, .openCodeGo, .ollama
    ]
    /// Misc tools with an in-app WKWebView login flow where
    /// `WebFormCredentialStore` may persist a username/password pair.
    /// Keeping the list explicit lets the preflight pre-authorize the
    /// Keychain accounts so users don't see a prompt on first save.
    private static let currentWebFormBackedMiscTools: [ToolType] = [
        .mimo, .volcengine, .tencentHunyuan, .alibaba
    ]
    private static let currentSecretKindsByTool: [ToolType: [MiscCredentialStore.Kind]] = [
        .alibaba: [.apiKey],
        .copilot: [.apiKey, .oauthAccessToken, .oauthRefreshToken, .oauthExpiry],
        .kilo: [.apiKey],
        .minimax: [.apiKey],
        .openRouter: [.apiKey],
        .warp: [.apiKey],
        .zai: [.apiKey]
    ]

    public static var ownedTargets: [Target] {
        uniqueSortedTargets(currentOwnedTargets + legacyOwnedTargets)
    }

    public static var currentOwnedTargets: [Target] {
        var targets: [Target] = []

        for provider in [SecureCookieHeaderStore.Provider.openAI, .claude] {
            for source in SecureCookieHeaderStore.Source.allCases {
                targets.append(
                    Target(
                        service: SecureCookieHeaderStore.keychainService,
                        account: SecureCookieHeaderStore.account(provider: provider, source: source)
                    )
                )
            }
        }
        targets.append(
            Target(
                service: SecureCookieHeaderStore.keychainService,
                account: claudeOrganizationAccount
            )
        )

        for tool in currentCookieBackedMiscTools {
            targets.append(
                Target(
                    service: MiscCookieSlotStore.keychainService,
                    account: MiscCookieSlotStore.keychainAccount(for: tool)
                )
            )
        }

        for (tool, kinds) in currentSecretKindsByTool {
            for kind in kinds {
                targets.append(
                    Target(
                        service: MiscCredentialStore.keychainService,
                        account: MiscCredentialStore.keychainAccount(tool: tool, kind: kind)
                    )
                )
            }
        }

        for tool in currentWebFormBackedMiscTools {
            targets.append(
                Target(
                    service: WebFormCredentialStore.keychainService,
                    account: WebFormCredentialStore.keychainAccount(tool: tool)
                )
            )
        }

        return uniqueSortedTargets(targets)
    }

    public static var legacyOwnedTargets: [Target] {
        var targets: [Target] = [
            Target(service: legacyClaudeWebService, account: legacyClaudeCookieAccount),
            Target(service: legacyClaudeWebService, account: legacyClaudeOrganizationAccount)
        ]

        for tool in ToolType.miscProviders {
            targets.append(
                Target(
                    service: legacyMiscService,
                    account: "cookie.\(tool.rawValue)"
                )
            )
            for kind in MiscCredentialStore.Kind.allCases {
                targets.append(
                    Target(
                        service: legacyMiscService,
                        account: MiscCredentialStore.keychainAccount(tool: tool, kind: kind)
                    )
                )
            }
        }

        return uniqueSortedTargets(targets)
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

        var authorized: [Target] = []
        var missing: [Target] = []
        var failures: [Failure] = []

        for target in ownedTargets {
            let lookup = findGenericPasswordItem(target)
            switch lookup.status {
            case errSecSuccess:
                guard let item = lookup.item else {
                    failures.append(Failure(target: target, status: Int(errSecInternalComponent)))
                    continue
                }

                let setStatus = SecKeychainItemSetAccess(item, access)
                if setStatus == errSecSuccess {
                    authorized.append(target)
                } else {
                    failures.append(Failure(target: target, status: Int(setStatus)))
                }
            case errSecItemNotFound:
                missing.append(target)
            default:
                failures.append(Failure(target: target, status: Int(lookup.status)))
            }
        }

        return Report(
            targetCount: ownedTargets.count,
            authorized: authorized,
            missing: missing,
            failures: failures
        )
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
            "Vibe Bar Keychain Access" as CFString,
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

    private static func uniqueSortedTargets(_ targets: [Target]) -> [Target] {
        Array(Set(targets)).sorted {
            if $0.service == $1.service {
                return $0.account < $1.account
            }
            return $0.service < $1.service
        }
    }
}
