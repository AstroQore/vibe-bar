import Foundation
import SweetCookieKit
import XCTest
@testable import VibeBarCore

final class ChromiumLocalStorageCredentialImporterTests: XCTestCase {
    private let credential = ChromiumLocalStorageCredential(
        origin: "https://example.com",
        key: "access_token",
        syntheticCookieName: "session-token",
        valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
    )

    func testReadsExactOriginAndLatin1PrefixedKeyFromAChromiumProfile() throws {
        let root = try makeTemporaryDirectory()
        let defaultProfile = root.appendingPathComponent("Default", isDirectory: true)
        let ignoredProfile = root.appendingPathComponent("System Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredProfile, withIntermediateDirectories: true)
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: token,
            profile: defaultProfile
        )
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: "ignored-header.ignored_payload.ignored-signature",
            profile: ignoredProfile
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertEqual(sessions, [
            .init(header: "session-token=\(token)", sourceLabel: "Chrome Default")
        ])
    }

    func testReadsExactPartitionedOriginWithoutStorageKeyUnderscore() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        try writeLocalStorageLog(
            origin: "https://example.com/^0https://top.example",
            key: credential.key,
            value: token,
            profile: profile,
            includePrefix: false
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertEqual(sessions.map(\.header), ["session-token=\(token)"])
    }

    func testReadsUnprefixedKeyNameForCompatibility() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: token,
            profile: profile,
            keyEncodingPrefix: nil
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertEqual(sessions.map(\.header), ["session-token=\(token)"])
    }

    func testRejectsHTTPValueForHTTPSOriginOnTheSameHost() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try writeLocalStorageLog(
            origin: "http://example.com",
            key: credential.key,
            value: "synthetic-header.synthetic_payload.synthetic-signature",
            profile: profile
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsValueFromADifferentExplicitPort() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try writeLocalStorageLog(
            origin: "https://example.com:8443",
            key: credential.key,
            value: "synthetic-header.synthetic_payload.synthetic-signature",
            profile: profile
        )
        let portCredential = ChromiumLocalStorageCredential(
            origin: "https://example.com:9443/",
            key: credential.key,
            syntheticCookieName: "session-token",
            valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: portCredential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsWrongKeyAndMalformedValue() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try writeLocalStorageLog(
            origin: credential.origin,
            key: "other_key",
            value: "synthetic-header.synthetic_payload.synthetic-signature",
            profile: profile
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsSymlinkedProfileDirectory() throws {
        let root = try makeTemporaryDirectory()
        let target = try makeTemporaryDirectory()
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: token,
            profile: target
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Default", isDirectory: true),
            withDestinationURL: target
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsSymlinkedRootDirectory() throws {
        let parent = try makeTemporaryDirectory()
        let targetRoot = try makeTemporaryDirectory()
        let targetProfile = targetRoot.appendingPathComponent("Default", isDirectory: true)
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: "synthetic-header.synthetic_payload.synthetic-signature",
            profile: targetProfile
        )
        let linkedRoot = parent.appendingPathComponent("Chrome", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: targetRoot)

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: linkedRoot)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsSymlinkedLevelDBDirectory() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        let localStorage = profile.appendingPathComponent("Local Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: localStorage, withIntermediateDirectories: true)

        let targetProfile = try makeTemporaryDirectory()
        try writeLocalStorageLog(
            origin: credential.origin,
            key: credential.key,
            value: "synthetic-header.synthetic_payload.synthetic-signature",
            profile: targetProfile
        )
        let targetLevelDB = targetProfile
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: localStorage.appendingPathComponent("leveldb", isDirectory: true),
            withDestinationURL: targetLevelDB
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testRejectsSymlinkedLevelDBDataFile() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        let levelDB = try makeEmptyLevelDB(profile: profile)
        let targetFile = try makeTemporaryDirectory().appendingPathComponent("source.log")
        try Data([0]).write(to: targetFile)
        try FileManager.default.createSymbolicLink(
            at: levelDB.appendingPathComponent("000003.log"),
            withDestinationURL: targetFile
        )

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init()
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    func testSharedBatchCacheReadsEachProfileOnlyOnce() throws {
        let root = try makeTemporaryDirectory()
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try makeEmptyLevelDB(profile: profile)
        let counter = LockedCounter()
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        let roots = [ChromiumProfileRoot(browser: .chrome, url: root)]
        let cache = ChromiumLocalStorageCredentialImporter.Cache()
        let textEntry = ChromiumLevelDBTextEntry(
            key: "_\(credential.origin)\0\u{1}\(credential.key)",
            value: token
        )
        let reader: ChromiumLocalStorageCredentialImporter.EntryReader = { origin, _ in
            counter.increment()
            return [ChromiumLocalStorageEntry(
                origin: origin,
                key: "access_token",
                value: token,
                rawValueLength: token.utf8.count + 1
            )]
        }

        let first = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: roots,
            cache: cache,
            readEntries: reader,
            readTextEntries: { _ in [textEntry] }
        )
        let second = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: roots,
            cache: cache,
            readEntries: reader,
            readTextEntries: { _ in [textEntry] }
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(counter.value, 1)
    }

    func testSingleImportStopsAfterTheFirstUsableProfile() throws {
        let root = try makeTemporaryDirectory()
        for name in ["Default", "Profile 1"] {
            try makeEmptyLevelDB(
                profile: root.appendingPathComponent(name, isDirectory: true)
            )
        }
        let counter = LockedCounter()
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        let textEntry = ChromiumLevelDBTextEntry(
            key: "_\(credential.origin)\0\u{1}\(credential.key)",
            value: token
        )
        let reader: ChromiumLocalStorageCredentialImporter.EntryReader = { origin, _ in
            counter.increment()
            return [ChromiumLocalStorageEntry(
                origin: origin,
                key: "access_token",
                value: token,
                rawValueLength: token.utf8.count + 1
            )]
        }

        let sessions = ChromiumLocalStorageCredentialImporter.sessions(
            credential: credential,
            roots: [.init(browser: .chrome, url: root)],
            cache: .init(),
            maxSessions: 1,
            readEntries: reader,
            readTextEntries: { _ in [textEntry] }
        )

        XCTAssertEqual(sessions.map(\.sourceLabel), ["Chrome Default"])
        XCTAssertEqual(counter.value, 1)
    }

    func testMiscBrowserSessionsUsesTheDeclaredLocalStorageSource() throws {
        let home = try makeTemporaryDirectory()
        let profile = home
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        let refreshToken = "refresh-header.refresh_payload.refresh-signature"
        try writeLocalStorageLog(
            origin: "https://www.kimi.com",
            key: "access_token",
            value: token,
            profile: profile
        )
        try writeLocalStorageLog(
            origin: "https://www.kimi.com",
            key: "refresh_token",
            value: refreshToken,
            profile: profile
        )
        let context = MiscCookieResolver.BrowserImportContext(
            detection: BrowserDetection(homeDirectory: home.path),
            homeDirectory: home
        )
        let settings = MiscProviderSettings(preferredBrowser: .chrome)

        let sessions = MiscCookieResolver.browserSessions(
            spec: KimiQuotaAdapter.cookieSpec,
            settings: settings,
            allowKeychainPrompt: false,
            context: context,
            maxSessions: 1
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sourceLabel, "Chrome Default")
        XCTAssertEqual(
            sessions[0].header,
            "kimi-auth=\(token); kimi-refresh=\(refreshToken)"
        )
    }

    func testMiscBrowserSessionsRejectsHeaderThatDoesNotMatchTheSpec() throws {
        let home = try makeTemporaryDirectory()
        let profile = home
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
            .appendingPathComponent("Default", isDirectory: true)
        let token = "synthetic-header.synthetic_payload.synthetic-signature"
        try writeLocalStorageLog(
            origin: "https://example.com",
            key: "access_token",
            value: token,
            profile: profile
        )
        let mismatched = MiscCookieResolver.Spec(
            tool: .kimi,
            domains: ["example.com"],
            requiredNames: ["expected-cookie"],
            browserCredentialSource: .chromiumLocalStorage(.init(
                origin: "https://example.com",
                key: "access_token",
                syntheticCookieName: "different-cookie",
                valueFormat: .jwt(segments: 3, minLength: 16, maxLength: 4_096)
            ))
        )

        let sessions = MiscCookieResolver.browserSessions(
            spec: mismatched,
            settings: MiscProviderSettings(preferredBrowser: .chrome),
            allowKeychainPrompt: false,
            context: .init(
                detection: BrowserDetection(homeDirectory: home.path),
                homeDirectory: home
            ),
            maxSessions: 1
        )

        XCTAssertTrue(sessions.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-chromium-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeLocalStorageLog(
        origin: String,
        key: String,
        value: String,
        profile: URL,
        includePrefix: Bool = true,
        keyEncodingPrefix: UInt8? = 1
    ) throws {
        let levelDB = try makeEmptyLevelDB(profile: profile)

        var localStorageKey = Data()
        if includePrefix {
            localStorageKey.append(0x5F)
        }
        localStorageKey.append(contentsOf: origin.utf8)
        localStorageKey.append(0x00)
        if let keyEncodingPrefix {
            localStorageKey.append(keyEncodingPrefix)
        }
        if keyEncodingPrefix == 0 {
            localStorageKey.append(key.data(using: .utf16LittleEndian)!)
        } else {
            localStorageKey.append(contentsOf: key.utf8)
        }
        var localStorageValue = Data([0x01])
        localStorageValue.append(contentsOf: value.utf8)

        var batch = Data(Array(repeating: UInt8(0), count: 8))
        batch.append(contentsOf: littleEndianBytes(UInt32(1)))
        batch.append(0x01)
        batch.append(varint32(localStorageKey.count))
        batch.append(localStorageKey)
        batch.append(varint32(localStorageValue.count))
        batch.append(localStorageValue)

        var record = Data(Array(repeating: UInt8(0), count: 4))
        record.append(contentsOf: littleEndianBytes(UInt16(batch.count)))
        record.append(0x01)
        record.append(batch)
        let log = levelDB.appendingPathComponent("000003.log")
        var existing = (try? Data(contentsOf: log)) ?? Data()
        existing.append(record)
        try existing.write(to: log)
    }

    @discardableResult
    private func makeEmptyLevelDB(profile: URL) throws -> URL {
        let levelDB = profile
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        try FileManager.default.createDirectory(at: levelDB, withIntermediateDirectories: true)
        return levelDB
    }

    private func varint32(_ value: Int) -> Data {
        var remaining = UInt32(value)
        var data = Data()
        while true {
            if remaining & ~0x7F == 0 {
                data.append(UInt8(remaining))
                return data
            }
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
    }

    private func littleEndianBytes(_ value: some FixedWidthInteger) -> [UInt8] {
        var copy = value.littleEndian
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
