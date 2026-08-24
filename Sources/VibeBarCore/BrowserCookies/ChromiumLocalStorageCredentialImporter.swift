import Foundation
import os.lock
import SweetCookieKit

struct ChromiumLocalStorageBrowserSession: Sendable, Equatable {
    let header: String
    let sourceLabel: String
}

/// Generic Chromium-profile credential reader used by the Browser Cookies
/// pipeline. Provider adapters only declare origin/key/header mapping in their
/// `MiscCookieResolver.Spec`; profile discovery and storage parsing live here.
enum ChromiumLocalStorageCredentialImporter {
    typealias DirectoryContents = @Sendable (URL) -> [URL]
    typealias EntryReader = @Sendable (String, URL) -> [ChromiumLocalStorageEntry]
    typealias TextEntryReader = @Sendable (URL) -> [ChromiumLevelDBTextEntry]

    final class Cache: @unchecked Sendable {
        private struct Key: Hashable {
            let credentials: [ChromiumLocalStorageCredential]
            let rootPaths: [String]
            let maxSessions: Int?
        }

        private let lock = OSAllocatedUnfairLock<[Key: [ChromiumLocalStorageBrowserSession]]>(
            initialState: [:]
        )

        func sessions(
            credentials: [ChromiumLocalStorageCredential],
            roots: [ChromiumProfileRoot],
            maxSessions: Int?,
            load: () -> [ChromiumLocalStorageBrowserSession]
        ) -> [ChromiumLocalStorageBrowserSession] {
            let key = Key(
                credentials: credentials,
                rootPaths: roots.map { $0.url.standardizedFileURL.path },
                maxSessions: maxSessions
            )
            if let cached = lock.withLock({ $0[key] }) {
                return cached
            }
            let loaded = load()
            lock.withLock { $0[key] = loaded }
            return loaded
        }
    }

    static func sessions(
        credential: ChromiumLocalStorageCredential,
        roots: [ChromiumProfileRoot],
        cache: Cache,
        maxSessions: Int? = nil,
        directoryContents: @escaping DirectoryContents = Self.liveDirectoryContents,
        readEntries: @escaping EntryReader = Self.liveReadEntries,
        readTextEntries: @escaping TextEntryReader = Self.liveReadTextEntries
    ) -> [ChromiumLocalStorageBrowserSession] {
        sessions(
            credentials: [credential],
            roots: roots,
            cache: cache,
            maxSessions: maxSessions,
            directoryContents: directoryContents,
            readEntries: readEntries,
            readTextEntries: readTextEntries
        )
    }

    static func sessions(
        credentials: [ChromiumLocalStorageCredential],
        roots: [ChromiumProfileRoot],
        cache: Cache,
        maxSessions: Int? = nil,
        directoryContents: @escaping DirectoryContents = Self.liveDirectoryContents,
        readEntries: @escaping EntryReader = Self.liveReadEntries,
        readTextEntries: @escaping TextEntryReader = Self.liveReadTextEntries
    ) -> [ChromiumLocalStorageBrowserSession] {
        guard !credentials.isEmpty,
              Set(credentials.map(\.syntheticCookieName)).count == credentials.count else {
            return []
        }
        return cache.sessions(credentials: credentials, roots: roots, maxSessions: maxSessions) {
            loadSessions(
                credentials: credentials,
                roots: roots,
                maxSessions: maxSessions,
                directoryContents: directoryContents,
                readEntries: readEntries,
                readTextEntries: readTextEntries
            )
        }
    }

    private static func loadSessions(
        credentials: [ChromiumLocalStorageCredential],
        roots: [ChromiumProfileRoot],
        maxSessions: Int?,
        directoryContents: DirectoryContents,
        readEntries: EntryReader,
        readTextEntries: TextEntryReader
    ) -> [ChromiumLocalStorageBrowserSession] {
        var sessions: [ChromiumLocalStorageBrowserSession] = []
        for root in roots {
            let rootURL = root.url.standardizedFileURL
            guard isRealDirectory(rootURL) else { continue }

            let profiles = directoryContents(rootURL)
                .map(\.standardizedFileURL)
                .filter { isChromiumProfileDirectory($0, under: rootURL) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for profile in profiles {
                guard let levelDB = validatedLevelDBDirectory(profile: profile, root: rootURL),
                      hasOnlyRealLevelDBFiles(levelDB) else {
                    continue
                }

                let textEntries = readTextEntries(levelDB)
                guard hasOnlyRealLevelDBFiles(levelDB) else { continue }

                var candidatesByOrigin: [String: [ChromiumLocalStorageEntry]] = [:]
                var headerPairs: [String] = []
                var complete = true
                for credential in credentials {
                    let candidates: [ChromiumLocalStorageEntry]
                    if let cached = candidatesByOrigin[credential.origin] {
                        candidates = cached
                    } else {
                        let loaded = readEntries(credential.origin, levelDB)
                        guard hasOnlyRealLevelDBFiles(levelDB) else {
                            complete = false
                            break
                        }
                        candidatesByOrigin[credential.origin] = loaded
                        candidates = loaded
                    }
                    guard let entry = candidates.first(where: {
                        $0.key == credential.key
                            && hasExactProvenance(
                                candidate: $0,
                                credential: credential,
                                textEntries: textEntries
                            )
                    }),
                    let pair = credential.cookieHeader(from: entry.value) else {
                        complete = false
                        break
                    }
                    headerPairs.append(pair)
                }
                guard complete, headerPairs.count == credentials.count else {
                    continue
                }
                sessions.append(ChromiumLocalStorageBrowserSession(
                    header: headerPairs.joined(separator: "; "),
                    sourceLabel: "\(root.labelPrefix) \(profile.lastPathComponent)"
                ))
                if let maxSessions, sessions.count >= maxSessions {
                    return sessions
                }
            }
        }
        return sessions
    }

    private static func isChromiumProfileDirectory(_ url: URL, under root: URL) -> Bool {
        guard isImmediateChild(url, of: root), isRealDirectory(url) else { return false }
        let name = url.lastPathComponent
        return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
    }

    private static func validatedLevelDBDirectory(profile: URL, root: URL) -> URL? {
        guard isImmediateChild(profile, of: root), isRealDirectory(profile) else { return nil }

        let localStorage = profile
            .appendingPathComponent("Local Storage", isDirectory: true)
            .standardizedFileURL
        guard isImmediateChild(localStorage, of: profile), isRealDirectory(localStorage) else {
            return nil
        }

        let levelDB = localStorage
            .appendingPathComponent("leveldb", isDirectory: true)
            .standardizedFileURL
        guard isImmediateChild(levelDB, of: localStorage), isRealDirectory(levelDB) else {
            return nil
        }
        return levelDB
    }

    private static func isImmediateChild(_ child: URL, of parent: URL) -> Bool {
        let standardizedChild = child.standardizedFileURL
        let standardizedParent = parent.standardizedFileURL
        guard standardizedChild
            .deletingLastPathComponent()
            .standardizedFileURL.path == standardizedParent.path else {
            return false
        }

        let resolvedChild = standardizedChild.resolvingSymlinksInPath()
        let resolvedParent = standardizedParent.resolvingSymlinksInPath()
        return resolvedChild
            .deletingLastPathComponent()
            .standardizedFileURL.path == resolvedParent.standardizedFileURL.path
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink == false
    }

    /// SweetCookieKit follows `.log` / `.ldb` URLs while parsing. Reject any
    /// store whose data files cannot be proven to be regular, direct children
    /// so browser-controlled symlinks cannot redirect the credential scan.
    private static func hasOnlyRealLevelDBFiles(_ levelDB: URL) -> Bool {
        guard isRealDirectory(levelDB),
              let children = try? FileManager.default.contentsOfDirectory(
                  at: levelDB,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        for child in children {
            let file = child.standardizedFileURL
            let fileExtension = file.pathExtension.lowercased()
            guard fileExtension == "log" || fileExtension == "ldb" else { continue }
            guard isImmediateChild(file, of: levelDB),
                  let values = try? file.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink == false else {
                return false
            }
        }
        return true
    }

    /// `ChromiumLocalStorageReader.readEntries(for:)` intentionally accepts
    /// host-equivalent origins and reports the requested origin on its result.
    /// That is useful for discovery but too broad for credentials. Require a
    /// second, raw-key view of the same exact origin/key/value before use.
    private static func hasExactProvenance(
        candidate: ChromiumLocalStorageEntry,
        credential: ChromiumLocalStorageCredential,
        textEntries: [ChromiumLevelDBTextEntry]
    ) -> Bool {
        guard let expectedOrigin = exactOrigin(from: credential.origin) else { return false }
        return textEntries.contains { entry in
            guard entry.value == candidate.value,
                  let parsed = parseLocalStorageKey(entry.key),
                  parsed.key == credential.key,
                  let actualOrigin = exactOrigin(from: parsed.serializedOrigin)
            else { return false }
            return actualOrigin == expectedOrigin
        }
    }

    private static func parseLocalStorageKey(
        _ rawKey: String
    ) -> (serializedOrigin: String, key: String)? {
        guard let separator = rawKey.firstIndex(of: "\0") else { return nil }
        var serializedOrigin = String(rawKey[..<separator])
        let keyStart = rawKey.index(after: separator)
        guard let key = decodeLocalStorageKeyName(rawKey[keyStart...]) else { return nil }
        guard !serializedOrigin.isEmpty, !key.isEmpty, !key.contains("\0") else { return nil }

        if serializedOrigin.first == "_" {
            serializedOrigin.removeFirst()
        }
        guard !serializedOrigin.isEmpty else { return nil }

        // StorageKey::SerializeForLocalStorage may append a caret partition
        // suffix. The origin before the first caret remains authoritative.
        if let caret = serializedOrigin.firstIndex(of: "^") {
            serializedOrigin = String(serializedOrigin[..<caret])
        }
        guard !serializedOrigin.isEmpty else { return nil }
        return (serializedOrigin, key)
    }

    /// Chromium stores the key name as its own prefixed string after the
    /// origin/key NUL separator: `0x01` for Latin-1 or `0x00` for UTF-16LE.
    /// `readTextEntries` preserves that control marker in the raw-key string,
    /// so mirror SweetCookieKit's key decoder before exact-key comparison.
    private static func decodeLocalStorageKeyName(_ rawName: Substring) -> String? {
        let bytes = Data(rawName.utf8)
        guard let prefix = bytes.first else { return nil }
        switch prefix {
        case 0:
            return String(data: bytes.dropFirst(), encoding: .utf16LittleEndian)
        case 1:
            return String(data: bytes.dropFirst(), encoding: .isoLatin1)
        default:
            // Older fixtures and best-effort stores can expose an unprefixed
            // UTF-8 key. Preserve that compatibility without weakening the
            // exact origin/key/value provenance gate.
            return String(rawName)
        }
    }

    private struct ExactOrigin: Equatable {
        let scheme: String
        let host: String
        let port: Int?
    }

    /// Canonicalize only URL-origin trivia: scheme/host case and one optional
    /// trailing slash. Scheme and explicit port remain part of the identity.
    private static func exactOrigin(from serializedOrigin: String) -> ExactOrigin? {
        let trimmed = serializedOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        return ExactOrigin(scheme: scheme, host: host, port: components.port)
    }

    private static let liveDirectoryContents: DirectoryContents = { root in
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static let liveReadEntries: EntryReader = { origin, levelDB in
        ChromiumLocalStorageReader.readEntries(for: origin, in: levelDB, logger: nil)
    }

    private static let liveReadTextEntries: TextEntryReader = { levelDB in
        ChromiumLevelDBReader.readTextEntries(in: levelDB, logger: nil)
    }
}
