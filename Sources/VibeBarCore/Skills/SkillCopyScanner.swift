import Foundation

/// One directory on this Mac that holds a skill: the shared copy in
/// `~/.agents/skills`, a real directory in a harness's own skills folder, or
/// a skill the harness ships in its built-in folder.
///
/// The Skills page is organized around the shared library, but the same
/// skill name routinely exists in several of these places with different
/// content — a hand-edited folder in `~/.claude/skills` that shadows the
/// shared one, Codex's bundled `skill-creator` next to a shared
/// `skill-creator`. A `SkillCopy` is the unit that lets those be shown side
/// by side instead of reported only as import "conflicts".
public struct SkillCopy: Sendable, Hashable, Identifiable {
    public enum Location: Sendable, Hashable {
        case shared
        /// A real directory (never a symlink) in the harness's skills folder.
        case appFolder(SkillAppTarget)
        /// A skill in the harness's own bundled folder
        /// (`SkillAppCatalog.builtInSkillRoots`).
        case builtIn(SkillAppTarget)

        public var app: SkillAppTarget? {
            switch self {
            case .shared: nil
            case let .appFolder(app), let .builtIn(app): app
            }
        }

        public var isBuiltIn: Bool {
            if case .builtIn = self { return true }
            return false
        }
    }

    /// Folder name.
    public let directoryName: String
    /// Frontmatter `name:`, falling back to `directoryName`.
    public let name: String
    public let description: String?
    public let location: Location
    public let url: URL
    /// `SkillDirectoryHasher.hash`, filled only for copies that are compared
    /// against something (`SkillCopyScanner.withContentHash`) — hashing every
    /// copy on every poll would read every payload byte of every harness
    /// folder every two seconds.
    public internal(set) var contentHash: String?
    /// Newest mtime in the tree, filled together with `contentHash` from the
    /// same metadata walk.
    public internal(set) var modifiedAt: Date?
    /// Set when the copy is attached to an installed skill: its content hash
    /// equals the shared copy's.
    public internal(set) var sameAsShared: Bool = false
    /// Set when the copy is attached to an installed skill and sits in a
    /// harness folder under the shared directory's own name, so that harness
    /// loads it in place of the shared copy.
    public internal(set) var shadowsShared: Bool = false

    public var id: String { url.path }

    public init(
        directoryName: String,
        name: String,
        description: String?,
        location: Location,
        url: URL,
        contentHash: String? = nil,
        modifiedAt: Date? = nil
    ) {
        self.directoryName = directoryName
        self.name = name
        self.description = description
        self.location = location
        self.url = url
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
    }

    /// Lower-cased frontmatter name; the key copies are grouped under.
    public var groupKey: String { name.lowercased() }
}

/// Read-only inventory of every skill copy outside the shared library.
///
/// Walks each managed harness's skills folder (real directories only —
/// symlinks are Vibe Bar's or another installer's projections of the shared
/// copy, not copies of their own) and each built-in root. Every filesystem
/// call is a read; nothing here creates, moves, or deletes a byte.
///
/// The page polls every two seconds, so the work is split by cost:
/// - `scan()` is two stats per folder — the folder itself and its
///   `SKILL.md`. Frontmatter is re-read only when `SKILL.md`'s own
///   size/mtime/inode moved; nothing else in the tree is visited.
/// - `withContentHash` walks one tree's metadata
///   (`SkillDirectoryHasher.treeMetadata`, stat-level) and reuses the hash
///   cached for that path while the stamp is unchanged. The payload is read
///   only when the stamp moved.
/// Only copies that are compared against a shared copy ever reach the second
/// step, and entries not touched for a whole scan are dropped so a removed
/// folder does not pin memory.
///
/// Not thread-safe by design: `SkillsService` owns one inside its actor.
public final class SkillCopyScanner {
    public struct Root: Sendable, Hashable {
        public let location: SkillCopy.Location
        public let url: URL
    }

    private struct Entry {
        /// size/mtime/inode of `SKILL.md`, guarding `frontmatter`.
        let skillFileStamp: String
        let frontmatter: SkillFrontmatterParser.Frontmatter
        /// Set by `withContentHash`; guards `contentHash`.
        var tree: SkillDirectoryHasher.TreeMetadata?
        var contentHash: String?
    }

    public let homeDirectory: String
    private var cache: [String: Entry] = [:]
    /// Paths looked up since the last `scan()`; everything else is pruned at
    /// the start of the next one.
    private var touched: Set<String> = []
    /// Full-content hashes computed so far. Tests use it to prove an
    /// unchanged tree is not rehashed.
    private(set) var hashComputations = 0

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    /// Every folder the scanner reads: harness skills folders first, then
    /// built-in roots, each in `managedHarnesses` order.
    public static func roots(homeDirectory: String = RealHomeDirectory.path) -> [Root] {
        let apps = SkillAppTarget.managedHarnesses
        let appFolders = apps.map {
            Root(
                location: .appFolder($0),
                url: SkillAppCatalog.skillsDirectory(for: $0, homeDirectory: homeDirectory)
            )
        }
        let builtIns = apps.flatMap { app in
            SkillAppCatalog.builtInSkillRoots(for: app, homeDirectory: homeDirectory)
                .map { Root(location: .builtIn(app), url: $0) }
        }
        return appFolders + builtIns
    }

    public func scan() -> [SkillCopy] {
        cache = cache.filter { touched.contains($0.key) }
        touched = []
        var copies: [SkillCopy] = []
        for root in Self.roots(homeDirectory: homeDirectory) {
            // Hidden names are skipped: `.system` is Codex's built-in root
            // (scanned as its own location), and `.DS_Store` / staging
            // siblings are never skills.
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.url.path)) ?? []
            for name in names.sorted() where !name.hasPrefix(".") {
                let directory = root.url.appendingPathComponent(name, isDirectory: true)
                guard
                    SkillFileSystem.kind(of: directory) == .directory,
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path),
                    let copy = copy(at: directory, directoryName: name, location: root.location)
                else { continue }
                copies.append(copy)
            }
        }
        return copies
    }

    /// The shared copy of `directoryName`, or `nil` when it is not a real
    /// directory in the SSOT.
    ///
    /// `allowingLink` admits an adopted linked skill whose receipt the caller
    /// has just verified. Its folder is never read the way a copy is: the
    /// link is followed only through `SharedSkillDiscoveryScanner.resolve`
    /// (link targets and one `SKILL.md`'s metadata, which must be a regular
    /// file within the 256 KB preview limit) and the frontmatter comes from
    /// its bounded 16 KB read. Anything else — too large, missing,
    /// unreadable — has no shared copy to show. The result carries no hash
    /// and must never be passed to `withContentHash`; `SkillDirectoryHasher`
    /// refuses a symlink root anyway.
    public func sharedCopy(directoryName: String, allowingLink: Bool = false) -> SkillCopy? {
        guard SkillPathValidator.isValid(directoryName) else { return nil }
        let directory = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
        switch SkillFileSystem.kind(of: directory) {
        case .directory:
            return copy(at: directory, directoryName: directoryName, location: .shared)
        case .symlink where allowingLink:
            return linkedSharedCopy(at: directory, directoryName: directoryName)
        default:
            return nil
        }
    }

    private func linkedSharedCopy(at link: URL, directoryName: String) -> SkillCopy? {
        let key = link.standardizedFileURL.path
        touched.insert(key)
        let resolution = SharedSkillDiscoveryScanner.resolve(link)
        guard resolution.state == .ready,
              let skillFile = resolution.skillFile,
              let stamp = resolution.skillFileStamp
        else {
            cache[key] = nil
            return nil
        }
        let frontmatter: SkillFrontmatterParser.Frontmatter
        if let cached = cache[key], cached.skillFileStamp == stamp {
            frontmatter = cached.frontmatter
        } else {
            guard let parsed = SharedSkillDiscoveryScanner.frontmatter(of: skillFile) else {
                cache[key] = nil
                return nil
            }
            frontmatter = parsed
            cache[key] = Entry(skillFileStamp: stamp, frontmatter: parsed, tree: nil, contentHash: nil)
        }
        return SkillCopy(
            directoryName: directoryName,
            name: frontmatter.name ?? directoryName,
            description: frontmatter.description,
            location: .shared,
            url: link
        )
    }

    /// `copy` with `contentHash` and `modifiedAt` filled in. The tree's
    /// metadata is walked every time (stat-level); the payload is hashed
    /// only when that stamp differs from the one the cached hash was taken
    /// under.
    public func withContentHash(_ copy: SkillCopy) -> SkillCopy {
        let key = copy.url.standardizedFileURL.path
        touched.insert(key)
        guard let tree = try? SkillDirectoryHasher.treeMetadata(directory: copy.url) else { return copy }
        var detailed = copy
        detailed.modifiedAt = tree.newestModification
        if let cached = cache[key], cached.tree?.stamp == tree.stamp, let hash = cached.contentHash {
            detailed.contentHash = hash
            return detailed
        }
        hashComputations += 1
        let hash = try? SkillDirectoryHasher.hash(directory: copy.url)
        cache[key]?.tree = tree
        cache[key]?.contentHash = hash
        detailed.contentHash = hash
        return detailed
    }

    private func copy(at directory: URL, directoryName: String, location: SkillCopy.Location) -> SkillCopy? {
        let key = directory.standardizedFileURL.path
        touched.insert(key)
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: skillFile.path) else {
            cache[key] = nil
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let skillFileStamp = "\(size):\(modified.bitPattern):\(inode)"
        let entry: Entry
        if let cached = cache[key], cached.skillFileStamp == skillFileStamp {
            entry = cached
        } else {
            // A new SKILL.md does not by itself say the rest of the tree
            // changed, but the cached hash is guarded by the tree stamp,
            // which covers SKILL.md too — dropping it here is only tidier.
            entry = Entry(
                skillFileStamp: skillFileStamp,
                frontmatter: SkillFrontmatterParser.parse(contentsOf: skillFile),
                tree: nil,
                contentHash: nil
            )
            cache[key] = entry
        }
        return SkillCopy(
            directoryName: directoryName,
            name: entry.frontmatter.name ?? directoryName,
            description: entry.frontmatter.description,
            location: location,
            url: directory
        )
    }
}
