import XCTest
@testable import VibeBarCore

/// The vault answers a burst of reads — one account reload reads it for every
/// misc cookie slot and every web cookie store — from one Keychain read and
/// one decode. These run against an in-memory stand-in for the Keychain, so
/// no test touches the login keychain.
final class VibeBarCredentialVaultCacheTests: XCTestCase {
    /// An in-memory vault item plus counters for every Keychain call the vault
    /// makes. `uptime` is set by the test, so the cache lifetime is exact.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var vault: Data?
        private var legacy: [String: Data] = [:]
        private var now: TimeInterval = 1_000
        private(set) var vaultReads = 0
        private(set) var vaultWrites = 0
        private(set) var legacyReads = 0

        init(entries: [VibeBarCredentialVault.Entry]) throws {
            vault = try VibeBarCredentialVault.encodePayload(.init(entries: entries))
        }

        func setLegacy(_ data: Data, service: String, account: String) {
            lock.lock()
            defer { lock.unlock() }
            legacy[service + "/" + account] = data
        }

        /// Another process rewrote the vault item behind this one's back.
        func replaceVaultExternally(_ entries: [VibeBarCredentialVault.Entry]) throws {
            let data = try VibeBarCredentialVault.encodePayload(.init(entries: entries))
            lock.lock()
            defer { lock.unlock() }
            vault = data
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            now += seconds
        }

        var backend: VibeBarCredentialVault.Backend {
            VibeBarCredentialVault.Backend(
                readVault: { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    vaultReads += 1
                    guard let vault else { throw KeychainStore.KeychainError.itemNotFound }
                    return vault
                },
                writeVault: { [self] data in
                    lock.lock()
                    defer { lock.unlock() }
                    vaultWrites += 1
                    vault = data
                },
                readLegacy: { [self] service, account in
                    lock.lock()
                    defer { lock.unlock() }
                    legacyReads += 1
                    guard let data = legacy[service + "/" + account] else {
                        throw KeychainStore.KeychainError.itemNotFound
                    }
                    return data
                },
                deleteLegacy: { [self] service, account in
                    lock.lock()
                    defer { lock.unlock() }
                    legacy.removeValue(forKey: service + "/" + account)
                },
                uptime: { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    return now
                }
            )
        }
    }

    private let service = "com.example.vibebar-tests"

    private func entry(_ account: String, _ value: String) -> VibeBarCredentialVault.Entry {
        .init(service: service, account: account, data: Data(value.utf8))
    }

    override func setUp() {
        super.setUp()
        KeychainAccessGate.isDisabled = false
    }

    override func tearDown() {
        KeychainAccessGate.isDisabled = false
        super.tearDown()
    }

    func testReadsAfterInvalidationDecodeTheVaultOnce() throws {
        let keychain = try FakeKeychain(entries: [entry("museAgent", "m"), entry("devin", "d"), entry("cursor", "c")])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            VibeBarCredentialVault.invalidateCache()
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "museAgent"), "m")
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "devin"), "d")
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "cursor"), "c")
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "museAgent"), "m")

            XCTAssertEqual(keychain.vaultReads, 1)
            XCTAssertEqual(VibeBarCredentialVault.payloadDecodeCountForTesting, 1)
        }
    }

    /// The real reload path: the misc cookie-slot lookups an account probe
    /// makes for Muse, Devin, Mistral Vibe and Cursor share one decode.
    func testCookieSlotLookupsOfOneReloadShareOneDecode() throws {
        let slots = try JSONEncoder.iso8601.encode([
            MiscCookieSlot(cookieHeader: "session=synthetic", sourceLabel: "Test", origin: .manual)
        ])
        let empty = try JSONEncoder.iso8601.encode([MiscCookieSlot]())
        let slotService = MiscCookieSlotStore.keychainService
        let keychain = try FakeKeychain(entries: [
            .init(service: slotService, account: MiscCookieSlotStore.keychainAccount(for: .museAgent), data: slots),
            .init(service: slotService, account: MiscCookieSlotStore.keychainAccount(for: .devin), data: empty),
            .init(service: slotService, account: MiscCookieSlotStore.keychainAccount(for: .mistralVibe), data: empty),
            .init(service: slotService, account: MiscCookieSlotStore.keychainAccount(for: .cursor), data: slots),
        ])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            VibeBarCredentialVault.invalidateCache()
            XCTAssertTrue(MiscCookieSlotStore.hasAnySlot(for: .museAgent))
            XCTAssertFalse(MiscCookieSlotStore.hasAnySlot(for: .devin))
            XCTAssertFalse(MiscCookieSlotStore.hasAnySlot(for: .mistralVibe))
            XCTAssertTrue(MiscCookieSlotStore.hasAnySlot(for: .cursor))

            XCTAssertEqual(keychain.vaultReads, 1)
            XCTAssertEqual(VibeBarCredentialVault.payloadDecodeCountForTesting, 1)
            XCTAssertEqual(keychain.legacyReads, 0)
        }
    }

    func testInvalidationMakesTheNextReadSeeAnotherProcessesChange() throws {
        let keychain = try FakeKeychain(entries: [entry("token", "old")])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "token"), "old")
            try keychain.replaceVaultExternally([entry("token", "new")])

            // Still inside the lifetime: served from the cache.
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "token"), "old")
            XCTAssertEqual(keychain.vaultReads, 1)

            // An account reload starts here.
            VibeBarCredentialVault.invalidateCache()
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "token"), "new")
            XCTAssertEqual(keychain.vaultReads, 2)
            XCTAssertEqual(VibeBarCredentialVault.payloadDecodeCountForTesting, 2)
        }
    }

    func testCacheExpiresAfterItsLifetime() throws {
        let keychain = try FakeKeychain(entries: [entry("token", "value")])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            _ = try VibeBarCredentialVault.readData(service: service, account: "token")
            keychain.advance(by: VibeBarCredentialVault.cacheLifetime - 0.1)
            _ = try VibeBarCredentialVault.readData(service: service, account: "token")
            XCTAssertEqual(keychain.vaultReads, 1)

            keychain.advance(by: 0.2)
            _ = try VibeBarCredentialVault.readData(service: service, account: "token")
            XCTAssertEqual(keychain.vaultReads, 2)
        }
    }

    /// A write reads the vault fresh — so it merges another process's change
    /// instead of overwriting it — and the result is what later reads see.
    func testWriteMergesFreshAndUpdatesTheCache() throws {
        let keychain = try FakeKeychain(entries: [entry("a", "1")])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "a"), "1")
            try keychain.replaceVaultExternally([entry("a", "1"), entry("b", "2")])

            try VibeBarCredentialVault.writeString(service: service, account: "c", value: "3")
            XCTAssertEqual(keychain.vaultReads, 2, "the write re-read the vault")
            XCTAssertEqual(keychain.vaultWrites, 1)

            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "b"), "2")
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "c"), "3")
            XCTAssertEqual(keychain.vaultReads, 2, "reads after the write are served from it")

            try VibeBarCredentialVault.delete(service: service, account: "c")
            XCTAssertThrowsError(try VibeBarCredentialVault.readData(service: service, account: "c"))
        }
    }

    /// A secret the user never stored is looked for in its historical
    /// per-secret item once, not on every read.
    func testMissingLegacyItemIsLookedUpOnce() throws {
        let keychain = try FakeKeychain(entries: [])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            for _ in 0..<3 {
                VibeBarCredentialVault.invalidateCache()
                XCTAssertThrowsError(try VibeBarCredentialVault.readData(service: service, account: "never-stored")) { error in
                    XCTAssertEqual(error as? KeychainStore.KeychainError, .itemNotFound)
                }
            }
            XCTAssertEqual(keychain.legacyReads, 1)
        }
    }

    func testLegacyItemIsMigratedIntoTheVault() throws {
        let keychain = try FakeKeychain(entries: [])
        keychain.setLegacy(Data("legacy".utf8), service: service, account: "old")
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "old"), "legacy")
            VibeBarCredentialVault.invalidateCache()
            XCTAssertEqual(try VibeBarCredentialVault.readString(service: service, account: "old"), "legacy")
            XCTAssertEqual(keychain.legacyReads, 1)
            XCTAssertEqual(keychain.vaultWrites, 1)
        }
    }

    /// With the Keychain kill switch on, nothing is served from memory and no
    /// miss is remembered: switching it back on must reach the Keychain.
    func testDisabledKeychainBypassesTheCache() throws {
        let keychain = try FakeKeychain(entries: [entry("token", "value")])
        try VibeBarCredentialVault.withBackendForTesting(keychain.backend) {
            KeychainAccessGate.isDisabled = true
            _ = try VibeBarCredentialVault.readData(service: service, account: "token")
            _ = try VibeBarCredentialVault.readData(service: service, account: "token")
            XCTAssertEqual(keychain.vaultReads, 2)
            XCTAssertThrowsError(try VibeBarCredentialVault.readData(service: service, account: "missing"))
            KeychainAccessGate.isDisabled = false
            XCTAssertThrowsError(try VibeBarCredentialVault.readData(service: service, account: "missing"))
            XCTAssertEqual(keychain.legacyReads, 2)
        }
    }
}

private extension JSONEncoder {
    /// `MiscCookieSlotStore` stores its slot lists with ISO 8601 dates.
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
