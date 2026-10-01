import Foundation

/// One version of an installed skill that the copies detail can show and
/// compare: the shared copy, a harness projection (link or managed copy), an
/// independent copy in a harness folder, a harness built-in, or a backup
/// snapshot Vibe Bar took before replacing the shared copy.
public struct SkillVersion: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// `~/.agents/skills/<dir>` — the managed source.
        case shared
        /// A copy Vibe Bar wrote into a harness folder (`.copy` projection).
        case managedCopy(SkillAppTarget)
        /// A symlink in a harness folder.
        case symlink(SkillAppTarget)
        /// A real directory in a harness folder that Vibe Bar did not write.
        case independentCopy(SkillAppTarget)
        /// A skill the harness ships in its own read-only folder.
        case builtIn(SkillAppTarget)
        /// A snapshot under `~/.vibebar/skill_backups/`.
        case backup(createdAt: Date)

        public var app: SkillAppTarget? {
            switch self {
            case let .managedCopy(app), let .symlink(app), let .independentCopy(app), let .builtIn(app): app
            case .shared, .backup: nil
            }
        }
    }

    /// Where a symlink version leads.
    public enum LinkState: Sendable, Hashable {
        /// Resolves to this skill's shared copy.
        case shared
        /// Resolves to another skill directory inside `SkillReadScope`.
        case inside
        /// Resolves to a directory outside every skill folder; never read.
        case outside
        /// The target does not exist.
        case broken
    }

    public enum Comparison: Sendable, Hashable {
        /// This *is* the shared copy (or a link to it).
        case source
        case identical
        case differs
        /// No hash on one side: unreadable, or no shared copy to compare to.
        case unknown
    }

    /// Logical path — what the user would find in Finder.
    public let url: URL
    public let kind: Kind
    /// The directory a comparison reads, resolved and checked against
    /// `SkillReadScope`; `nil` when this version cannot be read.
    public let readableURL: URL?
    /// Raw `readlink` string for a symlink version.
    public let linkTarget: String?
    public let linkState: LinkState?
    public let contentHash: String?
    public let modifiedAt: Date?
    public let comparison: Comparison
    /// The backup whose content hashes to the baseline Vibe Bar recorded —
    /// the "before" of a local modification.
    public let isRecordedBaseline: Bool
    /// The scanned copy behind this version, when it is one of
    /// `Skill.otherCopies`; the replace action takes it.
    public let copy: SkillCopy?

    public var id: String { url.standardizedFileURL.path }
    public var isReadable: Bool { readableURL != nil }
}

/// Every version of one installed skill, with the shared copy first.
public struct SkillVersionInventory: Sendable, Hashable {
    public enum BaselineState: Sendable, Hashable {
        /// The shared copy matches what Vibe Bar recorded; there is no
        /// "before" to show.
        case notModified
        /// A backup with the recorded content was found (`isRecordedBaseline`).
        case recovered
        /// The shared copy was edited, but only the recorded *hash* survives —
        /// no snapshot holds the content it describes.
        case unavailable
    }

    public let versions: [SkillVersion]
    public let baseline: BaselineState

    public var shared: SkillVersion? { versions.first { $0.kind == .shared } }
    public var recordedBaseline: SkillVersion? { versions.first(where: \.isRecordedBaseline) }
}

/// Builds a `SkillVersionInventory` from disk. Read-only and synchronous:
/// callers run it off the main thread (the Skills page uses a detached task).
///
/// Hashes the service already computed (`Skill.localContentHash`,
/// `SkillCopy.contentHash`) are reused; only versions it has no hash for —
/// managed copies, links into another folder, backups — are hashed here.
public enum SkillVersionScanner {
    /// Backups of one skill examined, newest first. Each costs one full hash.
    public static let maxBackups = 5

    public static func inventory(
        for skill: Skill,
        homeDirectory: String = RealHomeDirectory.path,
        scope: SkillReadScope? = nil
    ) -> SkillVersionInventory {
        let scope = scope ?? SkillReadScope.standard(homeDirectory: homeDirectory)
        guard SkillPathValidator.isValid(skill.directory) else {
            return SkillVersionInventory(versions: [], baseline: .notModified)
        }
        var versions: [SkillVersion] = []
        var seen: Set<String> = []

        // Shared copy. A link in the SSOT is not a shared copy (the page lists
        // such rows as discovered, read-only), so only a real directory counts.
        let sharedURL = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(skill.directory, isDirectory: true)
        let sharedReadable = SkillFileSystem.kind(of: sharedURL) == .directory
            ? scope.resolvedSkillDirectory(sharedURL) : nil
        let sharedHash = sharedReadable.flatMap { _ in
            skill.localContentHash ?? skill.sharedCopy?.contentHash ?? (try? SkillDirectoryHasher.hash(directory: sharedURL))
        }
        versions.append(SkillVersion(
            url: sharedURL,
            kind: .shared,
            readableURL: sharedReadable,
            linkTarget: nil,
            linkState: nil,
            contentHash: sharedHash,
            modifiedAt: skill.sharedCopy?.modifiedAt ?? sharedReadable.flatMap(newestModification),
            comparison: .source,
            isRecordedBaseline: false,
            copy: skill.sharedCopy
        ))
        seen.insert(sharedURL.standardizedFileURL.path)

        func compare(_ hash: String?) -> SkillVersion.Comparison {
            guard let hash, let sharedHash else { return .unknown }
            return hash == sharedHash ? .identical : .differs
        }

        // Harness projections under the shared directory's own name.
        let otherByPath = Dictionary(
            skill.otherCopies.map { ($0.url.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for app in SkillAppTarget.managedHarnesses {
            let entry = SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
                .appendingPathComponent(skill.directory, isDirectory: true)
            let key = entry.standardizedFileURL.path
            switch SkillFileSystem.kind(of: entry) {
            case .symlink:
                let raw = (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) ?? ""
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                let state: SkillVersion.LinkState
                let readable: URL?
                if SkillFileSystem.kind(of: resolved) != .directory {
                    state = .broken
                    readable = nil
                } else if let sharedReadable, resolved.path == sharedReadable.path {
                    state = .shared
                    readable = sharedReadable
                } else if let inside = scope.resolvedSkillDirectory(entry) {
                    state = .inside
                    readable = inside
                } else {
                    state = .outside
                    readable = nil
                }
                let hash: String? = switch state {
                case .shared: sharedHash
                case .inside: readable.flatMap { try? SkillDirectoryHasher.hash(directory: $0) }
                case .outside, .broken: nil
                }
                versions.append(SkillVersion(
                    url: entry,
                    kind: .symlink(app),
                    readableURL: readable,
                    linkTarget: raw,
                    linkState: state,
                    contentHash: hash,
                    modifiedAt: state == .inside ? readable.flatMap(newestModification) : nil,
                    comparison: state == .shared ? .source : compare(hash),
                    isRecordedBaseline: false,
                    copy: nil
                ))
                seen.insert(key)
            case .directory:
                if let copy = otherByPath[key] {
                    versions.append(version(for: copy, scope: scope, compare: compare))
                } else {
                    // Vibe Bar's own `.copy` projection, kept out of
                    // `otherCopies` because the toggle already shows it.
                    let readable = scope.resolvedSkillDirectory(entry)
                    let hash = readable.flatMap { try? SkillDirectoryHasher.hash(directory: $0) }
                    versions.append(SkillVersion(
                        url: entry,
                        kind: skill.apps[app]?.method == .copy ? .managedCopy(app) : .independentCopy(app),
                        readableURL: readable,
                        linkTarget: nil,
                        linkState: nil,
                        contentHash: hash,
                        modifiedAt: readable.flatMap(newestModification),
                        comparison: compare(hash),
                        isRecordedBaseline: false,
                        copy: nil
                    ))
                }
                seen.insert(key)
            case .missing, .regularFile, .other:
                continue
            }
        }

        // Every remaining scanned copy: differently named folders, built-ins.
        for copy in skill.otherCopies where !seen.contains(copy.url.standardizedFileURL.path) {
            versions.append(version(for: copy, scope: scope, compare: compare))
            seen.insert(copy.url.standardizedFileURL.path)
        }

        // Backups, newest first. The one whose payload hashes to the recorded
        // baseline is the "before" of a local edit.
        let backups = SkillBackupManager(homeDirectory: homeDirectory).listBackups()
            .filter { $0.skill?.directory == skill.directory }
            .prefix(maxBackups)
        var baselineFound = false
        for backup in backups {
            let payload = backup.url.appendingPathComponent("skill", isDirectory: true)
            guard SkillFileSystem.kind(of: payload) == .directory,
                  let readable = scope.resolvedSkillDirectory(payload) else { continue }
            let hash = try? SkillDirectoryHasher.hash(directory: readable)
            let isBaseline = skill.isLocallyModified && !baselineFound && hash != nil && hash == skill.contentHash
            if isBaseline { baselineFound = true }
            versions.append(SkillVersion(
                url: payload,
                kind: .backup(createdAt: backup.createdAt),
                readableURL: readable,
                linkTarget: nil,
                linkState: nil,
                contentHash: hash,
                modifiedAt: backup.createdAt,
                comparison: compare(hash),
                isRecordedBaseline: isBaseline,
                copy: nil
            ))
        }

        let baseline: SkillVersionInventory.BaselineState = !skill.isLocallyModified
            ? .notModified
            : baselineFound ? .recovered : .unavailable
        return SkillVersionInventory(versions: versions, baseline: baseline)
    }

    private static func version(
        for copy: SkillCopy,
        scope: SkillReadScope,
        compare: (String?) -> SkillVersion.Comparison
    ) -> SkillVersion {
        let readable = SkillFileSystem.kind(of: copy.url) == .directory ? scope.resolvedSkillDirectory(copy.url) : nil
        let hash = copy.contentHash ?? readable.flatMap { try? SkillDirectoryHasher.hash(directory: $0) }
        let kind: SkillVersion.Kind = switch copy.location {
        case let .builtIn(app): .builtIn(app)
        case let .appFolder(app): .independentCopy(app)
        case .shared: .shared
        }
        return SkillVersion(
            url: copy.url,
            kind: kind,
            readableURL: readable,
            linkTarget: nil,
            linkState: nil,
            contentHash: hash,
            modifiedAt: copy.modifiedAt ?? readable.flatMap(newestModification),
            comparison: compare(hash),
            isRecordedBaseline: false,
            copy: copy
        )
    }

    private static func newestModification(_ directory: URL) -> Date? {
        (try? SkillDirectoryHasher.treeMetadata(directory: directory))?.newestModification
    }
}
