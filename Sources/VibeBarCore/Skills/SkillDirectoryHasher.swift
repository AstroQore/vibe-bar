import CryptoKit
import Foundation

/// Content fingerprint for a skill directory.
///
/// One SHA-256 over every non-hidden regular file, walked recursively and
/// ordered by relative POSIX path (compared as UTF-8 bytes, so the digest does
/// not depend on locale collation). Each file contributes
/// `<relative path>\0<payload>\0` — the separators are what stop
/// `{"ab": "c"}` and `{"a": "bc"}` from hashing identically.
///
/// Symlinks *inside* a skill hash as their target path string, not the bytes
/// they point at: it is cheap, it keeps the walk from following a link out of
/// the tree (or into a cycle), and a re-pointed link is itself a content
/// change worth noticing.
///
/// Hidden entries are skipped at every level, so `.git/` and `.DS_Store`
/// churn does not invalidate a copy that is otherwise untouched. Empty
/// directories contribute nothing and are therefore invisible to the digest.
public enum SkillDirectoryHasher {
    public static func hash(directory: URL) throws -> String {
        var entries: [(path: String, url: URL, isSymlink: Bool)] = []
        try collect(directory: directory, relativePath: "", into: &entries)
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }

        var hasher = SHA256()
        let separator = Data([0])
        for entry in entries {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: separator)
            if entry.isSymlink {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)) ?? ""
                hasher.update(data: Data(target.utf8))
            } else {
                hasher.update(data: try Data(contentsOf: entry.url, options: [.mappedIfSafe]))
            }
            hasher.update(data: separator)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Cheap tree-change stamp for polling. It walks names and metadata but
    /// never reads file payloads; callers can reuse a previously verified
    /// content hash while this stamp is unchanged.
    public static func metadataStamp(directory: URL) throws -> String {
        try treeMetadata(directory: directory).stamp
    }

    /// The metadata stamp plus the newest modification time seen during the
    /// same walk. The copies view shows "changed <date>" per copy, and a
    /// second walk just for that date would double the polling cost.
    public struct TreeMetadata: Hashable, Sendable {
        public let stamp: String
        /// `nil` for a tree with no hashed entries.
        public let newestModification: Date?
    }

    public static func treeMetadata(directory: URL) throws -> TreeMetadata {
        var entries: [(path: String, url: URL, isSymlink: Bool)] = []
        try collect(directory: directory, relativePath: "", into: &entries)
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }

        var hasher = SHA256()
        let separator = Data([0])
        var newest: Date?
        for entry in entries {
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modifiedDate = attributes[.modificationDate] as? Date
            if let modifiedDate, newest.map({ modifiedDate > $0 }) ?? true { newest = modifiedDate }
            let modified = modifiedDate?.timeIntervalSince1970 ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let target = entry.isSymlink
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path)) ?? ""
                : ""
            let record = "\(entry.path)\0\(size)\0\(modified.bitPattern)\0\(inode)\0\(target)"
            hasher.update(data: Data(record.utf8))
            hasher.update(data: separator)
        }
        return TreeMetadata(
            stamp: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            newestModification: newest
        )
    }

    private static func collect(
        directory: URL,
        relativePath: String,
        into entries: inout [(path: String, url: URL, isSymlink: Bool)]
    ) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        for name in names {
            if name.hasPrefix(".") { continue }
            let child = directory.appendingPathComponent(name)
            let childRelativePath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            guard let attributes = try? fm.attributesOfItem(atPath: child.path) else { continue }
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                try collect(directory: child, relativePath: childRelativePath, into: &entries)
            case .typeSymbolicLink:
                entries.append((childRelativePath, child, true))
            case .typeRegular:
                entries.append((childRelativePath, child, false))
            default:
                continue
            }
        }
    }
}
