import Foundation

/// A skill directory found in an agent CLI's skills dir that has no SSOT
/// counterpart — installed by hand, or by a tool that never used
/// `~/.agents/skills`. Importing one copies it into the SSOT first.
public struct UnmanagedSkillDirectory: Sendable, Hashable {
    public let directoryName: String
    public let foundIn: [SkillAppTarget]
    public let name: String?
    public let description: String?

    public init(
        directoryName: String,
        foundIn: [SkillAppTarget],
        name: String? = nil,
        description: String? = nil
    ) {
        self.directoryName = directoryName
        self.foundIn = foundIn
        self.name = name
        self.description = description
    }
}

/// A real directory in an app's skills dir that shadows a same-named SSOT
/// skill. Materializing over it would destroy whatever it holds, so import
/// surfaces it and lets the user decide.
public struct SkillImportConflict: Sendable, Hashable {
    public let directoryName: String
    public let app: SkillAppTarget

    public init(directoryName: String, app: SkillAppTarget) {
        self.directoryName = directoryName
        self.app = app
    }
}

public struct SkillImportReport: Sendable, Hashable {
    /// SSOT skills, fully formed, with `apps` populated from the symlinks
    /// already on disk.
    public let adopted: [Skill]
    public let unmanagedDirectories: [UnmanagedSkillDirectory]
    /// SSOT directories with no SKILL.md — not skills, left alone.
    public let unrecognized: [String]
    public let conflicts: [SkillImportConflict]

    public init(
        adopted: [Skill],
        unmanagedDirectories: [UnmanagedSkillDirectory],
        unrecognized: [String],
        conflicts: [SkillImportConflict]
    ) {
        self.adopted = adopted
        self.unmanagedDirectories = unmanagedDirectories
        self.unrecognized = unrecognized
        self.conflicts = conflicts
    }

    public var isEmpty: Bool {
        adopted.isEmpty && unmanagedDirectories.isEmpty && unrecognized.isEmpty && conflicts.isEmpty
    }
}

/// Recognizes an existing skills layout without changing a byte of it.
///
/// The machines this ships to already have `~/.agents/skills` full of skills
/// and every app dir full of absolute symlinks into it, created by a different
/// tool. Import therefore has exactly one job: describe what is there — which
/// SSOT directories are skills, which app dirs already point at them, which
/// app-side directories are foreign, and what provenance
/// `~/.agents/.skill-lock.json` can still tell us — so Vibe Bar can start
/// managing that layout in place instead of rebuilding it.
///
/// Every filesystem call here is a read. The scan performs no creation, no
/// deletion, no relinking, and never writes the lock file, which belongs to
/// the tool that created it.
public enum SkillImportScanner {
    public static func scan(homeDirectory: String = RealHomeDirectory.path) -> SkillImportReport {
        let fm = FileManager.default
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let engine = SkillSyncEngine(homeDirectory: homeDirectory)

        var candidates: [String] = []
        var unrecognized: [String] = []
        for name in directoryEntries(at: ssot) {
            let directory = ssot.appendingPathComponent(name, isDirectory: true)
            guard SkillFileSystem.kind(of: directory) == .directory else { continue }
            if fm.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
                candidates.append(name)
            } else {
                unrecognized.append(name)
            }
        }
        let candidateNames = Set(candidates)
        let ssotNames = candidateNames.union(unrecognized)

        var evidence: [String: [SkillAppTarget]] = [:]
        var unmanaged: [String: [SkillAppTarget]] = [:]
        var unmanagedSample: [String: URL] = [:]
        var conflicts: [SkillImportConflict] = []

        for app in SkillAppTarget.managedHarnesses {
            let appDirectory = SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
            for name in directoryEntries(at: appDirectory) {
                let entry = appDirectory.appendingPathComponent(name, isDirectory: true)
                switch SkillFileSystem.kind(of: entry) {
                case .symlink:
                    // Dangling links, and links aimed anywhere other than this
                    // skill's own SSOT directory, are not adoption evidence.
                    guard
                        candidateNames.contains(name),
                        engine.adoptionState(skillDirectoryName: name, app: app) != nil
                    else { continue }
                    evidence[name, default: []].append(app)
                case .directory:
                    if ssotNames.contains(name) {
                        conflicts.append(SkillImportConflict(directoryName: name, app: app))
                    } else {
                        unmanaged[name, default: []].append(app)
                        if unmanagedSample[name] == nil { unmanagedSample[name] = entry }
                    }
                default:
                    continue
                }
            }
        }

        let lock = SkillLockFileReader.read(homeDirectory: homeDirectory)
        let adopted: [Skill] = candidates.map { name in
            let directory = ssot.appendingPathComponent(name, isDirectory: true)
            let frontmatter = SkillFrontmatterParser.parse(
                contentsOf: directory.appendingPathComponent("SKILL.md")
            )
            let provenance = lock.provenance(for: name)
            var apps: [SkillAppTarget: SkillMaterialization] = [:]
            for app in evidence[name] ?? [] {
                apps[app] = SkillMaterialization(method: .symlink, adopted: true)
            }
            return Skill(
                id: provenance.id,
                name: frontmatter.name ?? name,
                description: frontmatter.description,
                directory: name,
                repoBranch: provenance.branch,
                installedAt: provenance.installedAt ?? fileDate(of: directory, key: .creationDate) ?? .distantPast,
                contentHash: try? SkillDirectoryHasher.hash(directory: directory),
                updatedAt: provenance.updatedAt ?? fileDate(of: directory, key: .modificationDate),
                apps: apps
            )
        }

        let unmanagedDirectories: [UnmanagedSkillDirectory] = unmanaged.keys.sorted().map { name in
            let frontmatter = unmanagedSample[name].map {
                SkillFrontmatterParser.parse(contentsOf: $0.appendingPathComponent("SKILL.md"))
            } ?? .empty
            return UnmanagedSkillDirectory(
                directoryName: name,
                foundIn: unmanaged[name] ?? [],
                name: frontmatter.name,
                description: frontmatter.description
            )
        }

        return SkillImportReport(
            adopted: adopted,
            unmanagedDirectories: unmanagedDirectories,
            unrecognized: unrecognized,
            conflicts: conflicts
        )
    }

    private static func directoryEntries(at url: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func fileDate(of url: URL, key: FileAttributeKey) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[key] as? Date
    }
}

/// Read-only view of `~/.agents/.skill-lock.json`, the provenance file another
/// tool maintains. Vibe Bar recovers repository identity and branch from it so
/// adopted skills know where they came from; it never writes the file, and
/// treats every field as optional because the schema is not ours.
struct SkillLockFileReader {
    struct Provenance {
        let id: SkillID
        let branch: String?
        let installedAt: Date?
        let updatedAt: Date?
    }

    private let entries: [String: Entry]

    static func read(homeDirectory: String) -> SkillLockFileReader {
        let url = SkillAppCatalog.lockFileURL(homeDirectory: homeDirectory)
        guard
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(LockFile.self, from: data)
        else {
            return SkillLockFileReader(entries: [:])
        }
        var entries: [String: Entry] = [:]
        for (name, lossy) in file.skills ?? [:] {
            guard let entry = lossy.entry else { continue }
            entries[name] = entry
        }
        return SkillLockFileReader(entries: entries)
    }

    func provenance(for directoryName: String) -> Provenance {
        let entry = entries[directoryName]
        return Provenance(
            id: Self.identity(for: directoryName, entry: entry),
            branch: Self.branch(for: entry),
            installedAt: entry?.installedAt.flatMap(Self.date(from:)),
            updatedAt: entry?.updatedAt.flatMap(Self.date(from:))
        )
    }

    // MARK: - Parsing

    private static func identity(for directoryName: String, entry: Entry?) -> SkillID {
        guard
            let entry,
            entry.sourceType?.lowercased() == "github",
            let source = entry.source
        else { return .local(directory: directoryName) }
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return .local(directory: directoryName)
        }
        return .repo(owner: String(parts[0]), repo: String(parts[1]), directory: directoryName)
    }

    private static func branch(for entry: Entry?) -> String? {
        guard let entry else { return nil }
        if let branch = entry.branch, !branch.isEmpty { return branch }
        if let branch = entry.sourceBranch, !branch.isEmpty { return branch }
        guard let sourceURL = entry.sourceUrl else { return nil }
        return branch(fromSourceURL: sourceURL)
    }

    /// `sourceUrl` is a plain clone URL most of the time, but the installer
    /// also accepts the browse-URL forms people paste. Checked in order:
    /// a `/tree/<branch>/…` path segment, a `#branch` fragment, then a
    /// `?branch=` / `?ref=` query value. Only the first path segment after
    /// `/tree/` is taken — a slashed branch name is indistinguishable from
    /// `<branch>/<path>` without asking the remote.
    static func branch(fromSourceURL raw: String) -> String? {
        var base = raw
        var fragment: String?
        if let hash = base.firstIndex(of: "#") {
            fragment = String(base[base.index(after: hash)...])
            base = String(base[base.startIndex..<hash])
        }
        var query: String?
        if let mark = base.firstIndex(of: "?") {
            query = String(base[base.index(after: mark)...])
            base = String(base[base.startIndex..<mark])
        }
        if let treeRange = base.range(of: "/tree/") {
            let segment = base[treeRange.upperBound...]
                .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            if !segment.isEmpty { return segment }
        }
        if let fragment, !fragment.isEmpty { return fragment }
        for pair in (query ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "branch" || parts[0] == "ref" else { continue }
            let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Wire shape

    private struct LockFile: Decodable {
        let version: Int?
        let skills: [String: LossyEntry]?

        private enum CodingKeys: String, CodingKey {
            case version, skills
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try? c.decodeIfPresent(Int.self, forKey: .version)
            self.skills = try? c.decodeIfPresent([String: LossyEntry].self, forKey: .skills)
        }
    }

    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    struct Entry: Decodable {
        let source: String?
        let sourceType: String?
        let sourceUrl: String?
        let skillPath: String?
        let branch: String?
        let sourceBranch: String?
        let installedAt: String?
        let updatedAt: String?

        private enum CodingKeys: String, CodingKey {
            case source, sourceType, sourceUrl, skillPath, branch, sourceBranch, installedAt, updatedAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.source = try? c.decodeIfPresent(String.self, forKey: .source)
            self.sourceType = try? c.decodeIfPresent(String.self, forKey: .sourceType)
            self.sourceUrl = try? c.decodeIfPresent(String.self, forKey: .sourceUrl)
            self.skillPath = try? c.decodeIfPresent(String.self, forKey: .skillPath)
            self.branch = try? c.decodeIfPresent(String.self, forKey: .branch)
            self.sourceBranch = try? c.decodeIfPresent(String.self, forKey: .sourceBranch)
            self.installedAt = try? c.decodeIfPresent(String.self, forKey: .installedAt)
            self.updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }
}
