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
    static let canonical = ".agents/AGENTS.md"
    static let codexOverride = ".codex/AGENTS.override.md"
    static let maximumBytes = 4 * 1024 * 1024

    init(homeDirectory: URL) throws {
        guard homeDirectory.isFileURL, homeDirectory.path.hasPrefix("/"), homeDirectory.path != "/" else {
            throw AgentLibraryError.invalidHome
        }
        home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
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
                current = (destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                    : current.deletingLastPathComponent().appendingPathComponent(destination)).standardizedFileURL
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
    func guarded(_ relative: String, revision: String) throws -> AgentLibraryFileSnapshot {
        let result = try snapshot(relative)
        guard result.revision == revision else { throw AgentLibraryError.staleRevision }
        return result
    }
    func write(_ relative: String, data: Data, expectedRevision: String, allowInstructionLink: Bool = false) throws -> AgentLibraryBackup {
        guard data.count <= Self.maximumBytes else { throw AgentLibraryError.oversizedFile }
        let before = try guarded(relative, revision: expectedRevision)
        if before.isSymlink && !allowInstructionLink { throw AgentLibraryError.unsafePath }
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
    func restore(_ record: AgentLibraryBackupRecord, expectedRevision: String) throws -> AgentLibraryBackup {
        let before = try guarded(record.relativePath, revision: expectedRevision)
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
