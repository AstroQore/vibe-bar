import CryptoKit
import Darwin
import Foundation

struct AgentLibraryFileSnapshot {
    let logical: URL
    let resolved: URL
    let data: Data?
    let revision: String
    let isSymlink: Bool
}

struct AgentLibraryBackupRecord: Codable {
    let id: String
    let relativePath: String
    let kind: String
    let data: Data?
    let link: String?
    let createdAt: Date
}

/// Only catalog files may be followed through symlinks. Directory links,
/// loops and destinations outside the injected home fail closed.
struct AgentLibraryFiles: Sendable {
    let home: URL
    /// Other spellings of the same home directory. `resolvingSymlinksInPath`
    /// keeps `/var/…` and `/tmp/…` while `realpath` and links written by
    /// other tools say `/private/var/…`; an absolute link through either
    /// spelling names the same in-home file and must not read as escaping it.
    let homeAliases: [String]
    static let canonical = ".agents/AGENTS.md"
    static let codexOverride = ".codex/AGENTS.override.md"
    static let maximumBytes = 4 * 1024 * 1024

    init(homeDirectory: URL) throws {
        guard homeDirectory.isFileURL, homeDirectory.path.hasPrefix("/"), homeDirectory.path != "/" else {
            throw AgentLibraryError.invalidHome
        }
        home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let home = home
        homeAliases = Set([homeDirectory.standardizedFileURL.path, Self.realPath(home.path)].compactMap { $0 })
            .filter { $0 != home.path && $0 != "/" }.sorted { $0.count > $1.count }
    }
    /// Rewrites a path spelled through a home alias to the canonical `home`
    /// spelling. Paths outside every spelling of the home are returned as-is
    /// and still fail the containment checks below.
    func normalized(_ url: URL) -> URL {
        let path = url.path
        for alias in homeAliases where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: home.path + path.dropFirst(alias.count))
        }
        return url
    }
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    var allowed: Set<String> {
        Set([Self.canonical, Self.codexOverride] + AgentLibraryTarget.allCases.map(\.mcpRelativePath)
            + AgentLibraryTarget.allCases.compactMap(\.instructionRelativePath))
    }
    var instructionPaths: Set<String> {
        Set([Self.canonical, Self.codexOverride] + AgentLibraryTarget.allCases.compactMap(\.instructionRelativePath))
    }
    func url(_ relative: String) throws -> URL {
        guard allowed.contains(relative) else { throw AgentLibraryError.unsafePath }
        return home.appendingPathComponent(relative)
    }
    func relative(_ url: URL) throws -> String {
        let url = normalized(url)
        guard url.path.hasPrefix(home.path + "/") else { throw AgentLibraryError.unsafePath }
        let relative = String(url.path.dropFirst(home.path.count + 1))
        guard allowed.contains(relative) else { throw AgentLibraryError.unsafePath }
        return relative
    }
    func snapshot(_ relative: String) throws -> AgentLibraryFileSnapshot {
        let logical = try url(relative)
        let allowedDestinations = instructionPaths.contains(relative) ? instructionPaths
            : Set(AgentLibraryTarget.allCases.map(\.mcpRelativePath))
        var current = logical
        var visited: Set<String> = []
        var links: [String] = []
        for _ in 0..<32 {
            guard visited.insert(current.path).inserted else { throw AgentLibraryError.symlinkLoop }
            guard allowedDestinations.contains(try self.relative(current)) else { throw AgentLibraryError.unsafePath }
            try ancestors(current.deletingLastPathComponent(), create: false)
            var info = stat()
            let result = lstat(current.path, &info)
            if result != 0 {
                guard errno == ENOENT else { throw AgentLibraryError.ioFailure }
                let revision = links.isEmpty ? "missing" : Self.digest(Data((links.joined(separator: "\n") + "\nmissing").utf8))
                return .init(logical: logical, resolved: current, data: nil, revision: revision, isSymlink: !links.isEmpty)
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                    throw AgentLibraryError.ioFailure
                }
                links.append(current.path + "=" + destination)
                current = normalized((destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                    : current.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL)
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw AgentLibraryError.unsafePath }
            guard info.st_size <= Self.maximumBytes else { throw AgentLibraryError.oversizedFile }
            guard let data = try? Data(contentsOf: current), data.count <= Self.maximumBytes else {
                throw AgentLibraryError.ioFailure
            }
            var identity = Data(links.joined(separator: "\n").utf8)
            identity.append(0); identity.append(data)
            return .init(logical: logical, resolved: current, data: data,
                         revision: Self.digest(identity), isSymlink: !links.isEmpty)
        }
        throw AgentLibraryError.symlinkLoop
    }
    /// Display and comparison only: the leaf's own link text and where its
    /// link chain ends, followed by path without reading or opening any file
    /// and without the allowlist. A link to a source Vibe Bar does not manage
    /// is still reported — as a path — so the user can see what is linked,
    /// while `snapshot` keeps refusing to read or write through it.
    func linkInfo(_ relative: String) -> (destination: String?, resolved: String?) {
        guard let logical = try? url(relative) else { return (nil, nil) }
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: logical.path)
        var current = logical
        var visited: Set<String> = []
        for _ in 0..<32 {
            guard visited.insert(current.path).inserted else { return (destination, nil) }
            guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else {
                return (destination, current.path)
            }
            current = normalized((next.hasPrefix("/") ? URL(fileURLWithPath: next)
                : current.deletingLastPathComponent().appendingPathComponent(next)).standardizedFileURL)
        }
        return (destination, nil)
    }
    func guarded(_ relative: String, revision: String) throws -> AgentLibraryFileSnapshot {
        let result = try snapshot(relative)
        guard result.revision == revision else { throw AgentLibraryError.staleRevision }
        return result
    }
    func prepareWrite(_ relative: String, data: Data, expectedRevision: String,
                      allowInstructionLink: Bool = false) throws -> AgentLibraryFileSnapshot {
        guard data.count <= Self.maximumBytes else { throw AgentLibraryError.oversizedFile }
        let before = try guarded(relative, revision: expectedRevision)
        if before.isSymlink && !allowInstructionLink { throw AgentLibraryError.unsafePath }
        _ = try self.relative(before.resolved)
        return before
    }
    func write(_ relative: String, data: Data, expectedRevision: String, allowInstructionLink: Bool = false) throws -> AgentLibraryBackup {
        let before = try prepareWrite(relative, data: data, expectedRevision: expectedRevision,
                                      allowInstructionLink: allowInstructionLink)
        let destination = try self.relative(before.resolved)
        let backup = try backupFile(destination)
        _ = try guarded(relative, revision: expectedRevision)
        try atomic(data, to: before.resolved)
        return backup
    }
    func backupFile(_ relative: String) throws -> AgentLibraryBackup {
        let target = try url(relative)
        try ancestors(target.deletingLastPathComponent(), create: false)
        var info = stat()
        let exists = lstat(target.path, &info) == 0
        let kind: String
        let data: Data?
        let link: String?
        if !exists {
            guard errno == ENOENT else { throw AgentLibraryError.ioFailure }
            kind = "missing"; data = nil; link = nil
        } else if (info.st_mode & S_IFMT) == S_IFLNK {
            kind = "symlink"; data = nil
            link = try FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        } else if (info.st_mode & S_IFMT) == S_IFREG {
            guard info.st_size <= Self.maximumBytes else { throw AgentLibraryError.oversizedFile }
            kind = "file"; data = try Data(contentsOf: target); link = nil
        } else { throw AgentLibraryError.unsafePath }
        let id = UUID().uuidString
        let record = AgentLibraryBackupRecord(id: id, relativePath: relative, kind: kind, data: data,
                                              link: link, createdAt: Date())
        try atomic(JSONEncoder().encode(record), to: storageURL("backups/" + id + ".json"))
        return .init(id: id, relativePath: relative, createdAt: record.createdAt)
    }
    func backup(_ id: String) throws -> AgentLibraryBackupRecord {
        guard UUID(uuidString: id) != nil else { throw AgentLibraryError.invalidBackup }
        guard let data = try readStorage("backups/" + id + ".json") else { throw AgentLibraryError.backupMissing }
        guard let record = try? JSONDecoder().decode(AgentLibraryBackupRecord.self, from: data),
              record.id == id, allowed.contains(record.relativePath), ["file", "missing", "symlink"].contains(record.kind)
        else { throw AgentLibraryError.invalidBackup }
        if let link = record.link {
            let original = try url(record.relativePath)
            let destination = (link.hasPrefix("/") ? URL(fileURLWithPath: link)
                : original.deletingLastPathComponent().appendingPathComponent(link)).standardizedFileURL
            _ = try relative(destination)
        }
        return record
    }
    func prepareRestore(_ record: AgentLibraryBackupRecord, expectedRevision: String) throws -> AgentLibraryFileSnapshot {
        let before = try guarded(record.relativePath, revision: expectedRevision)
        switch record.kind {
        case "file":
            guard let data = record.data else { throw AgentLibraryError.invalidBackup }
            guard data.count <= Self.maximumBytes else { throw AgentLibraryError.oversizedFile }
        case "symlink":
            guard record.link != nil else { throw AgentLibraryError.invalidBackup }
        case "missing": break
        default: throw AgentLibraryError.invalidBackup
        }
        return before
    }
    func restore(_ record: AgentLibraryBackupRecord, expectedRevision: String) throws -> AgentLibraryBackup {
        let before = try prepareRestore(record, expectedRevision: expectedRevision)
        let safetyCopy = try backupFile(record.relativePath)
        _ = try guarded(record.relativePath, revision: expectedRevision)
        let target = try url(record.relativePath)
        switch record.kind {
        case "file":
            guard let data = record.data else { throw AgentLibraryError.invalidBackup }
            try atomic(data, to: target)
        case "symlink":
            guard let link = record.link else { throw AgentLibraryError.invalidBackup }
            try atomicSymlink(link, to: target)
        case "missing":
            if before.data != nil || before.isSymlink {
                try ancestors(target.deletingLastPathComponent(), create: false)
                guard unlink(target.path) == 0 else { throw AgentLibraryError.ioFailure }
            }
        default: throw AgentLibraryError.invalidBackup
        }
        return safetyCopy
    }
    func storageURL(_ relative: String) -> URL {
        VibeBarLocalStore.baseDirectory(homeDirectory: home.path)
            .appendingPathComponent("agent_library").appendingPathComponent(relative)
    }
    func readStorage(_ relative: String) throws -> Data? {
        let target = storageURL(relative)
        try ancestors(target.deletingLastPathComponent(), create: false)
        var info = stat()
        guard lstat(target.path, &info) == 0 else {
            if errno == ENOENT { return nil }; throw AgentLibraryError.ioFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw AgentLibraryError.unsafePath }
        let limit = relative.hasPrefix("backups/") ? Self.maximumBytes * 2 : Self.maximumBytes
        guard info.st_size <= limit else { throw AgentLibraryError.oversizedFile }
        return try Data(contentsOf: target)
    }
    func atomic(_ data: Data, to target: URL) throws {
        try ancestors(target.deletingLastPathComponent(), create: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".agent-library-" + UUID().uuidString)
        defer { unlink(temporary.path) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AgentLibraryError.ioFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { throw AgentLibraryError.ioFailure }
        try ancestors(target.deletingLastPathComponent(), create: false)
        guard rename(temporary.path, target.path) == 0 else { throw AgentLibraryError.ioFailure }
    }
    func atomicSymlink(_ destination: String, to target: URL) throws {
        try ancestors(target.deletingLastPathComponent(), create: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".agent-library-" + UUID().uuidString)
        defer { unlink(temporary.path) }
        guard symlink(destination, temporary.path) == 0 else { throw AgentLibraryError.ioFailure }
        try ancestors(target.deletingLastPathComponent(), create: false)
        guard rename(temporary.path, target.path) == 0 else { throw AgentLibraryError.ioFailure }
    }
    func ancestors(_ directory: URL, create: Bool) throws {
        guard directory.path == home.path || directory.path.hasPrefix(home.path + "/") else {
            throw AgentLibraryError.unsafePath
        }
        let relative = directory.path == home.path ? "" : String(directory.path.dropFirst(home.path.count + 1))
        var current = home
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else { throw AgentLibraryError.ioFailure }
                if !create { return }
                guard mkdir(current.path, mode_t(0o700)) == 0 || errno == EEXIST else { throw AgentLibraryError.ioFailure }
                guard lstat(current.path, &info) == 0 else { throw AgentLibraryError.ioFailure }
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw AgentLibraryError.unsafePath }
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
