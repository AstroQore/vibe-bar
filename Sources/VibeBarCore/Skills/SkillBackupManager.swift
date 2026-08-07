import Foundation

/// Pre-uninstall snapshots of skill directories under
/// `~/.vibebar/skill_backups/`.
///
/// Layout of one backup:
///
/// ```text
/// 20260807_161200_my-skill[_2]/
/// ├── skill/       # verbatim recursive copy of ~/.agents/skills/my-skill
/// └── meta.json    # the Skill record, when it was taken, where it came from
/// ```
///
/// This is the only reason uninstalling a skill is safe to offer: a skill that
/// came from a repository can be re-fetched, but a locally authored one only
/// exists here once its SSOT directory is gone.
public struct SkillBackupManager: Sendable {
    public struct Metadata: Codable, Sendable {
        public let skill: Skill
        public let backupCreatedAt: Date
        public let sourcePath: String

        public init(skill: Skill, backupCreatedAt: Date, sourcePath: String) {
            self.skill = skill
            self.backupCreatedAt = backupCreatedAt
            self.sourcePath = sourcePath
        }
    }

    public struct Backup: Sendable, Hashable, Identifiable {
        public var id: String { directoryName }
        public let url: URL
        public let directoryName: String
        public let createdAt: Date
        public let skill: Skill?
    }

    public static let defaultRetainedBackups = 20

    public let homeDirectory: String

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    public var rootDirectory: URL {
        VibeBarLocalStore.skillBackupsDirectoryURL(homeDirectory: homeDirectory)
    }

    @discardableResult
    public func createBackup(of skillDirectoryName: String, skill: Skill) throws -> URL {
        try SkillPathValidator.validate(directoryName: skillDirectoryName)
        let source = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(skillDirectoryName, isDirectory: true)
        guard SkillFileSystem.kind(of: source) == .directory else {
            throw SkillError.sourceDirectoryMissing(skillDirectoryName)
        }

        let root = rootDirectory
        try SkillFileSystem.ensureDirectory(root, stopAt: homeURL, permissions: 0o700)

        let createdAt = Date()
        let backupURL = try uniqueBackupURL(for: skillDirectoryName, at: createdAt, in: root)
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: backupURL.path
        )
        try FileManager.default.copyItem(at: source, to: backupURL.appendingPathComponent("skill"))
        let metadata = Metadata(skill: skill, backupCreatedAt: createdAt, sourcePath: source.path)
        try VibeBarLocalStore.writeJSON(
            metadata,
            to: backupURL.appendingPathComponent("meta.json"),
            base: VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
        )
        prune()
        return backupURL
    }

    /// Newest first.
    public func listBackups() -> [Backup] {
        let root = rootDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        let backups: [Backup] = names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard SkillFileSystem.kind(of: url) == .directory else { return nil }
            let metadata = self.metadata(at: url)
            let createdAt = metadata?.backupCreatedAt ?? modificationDate(of: url) ?? .distantPast
            return Backup(url: url, directoryName: name, createdAt: createdAt, skill: metadata?.skill)
        }
        return backups.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.directoryName > $1.directoryName
        }
    }

    /// Copies a backup's payload back into the SSOT and returns the restored
    /// record with a freshly computed content hash. Refuses to overwrite: if
    /// the SSOT directory came back some other way, the user resolves that
    /// before restoring.
    @discardableResult
    public func restore(backupURL: URL) throws -> Skill {
        guard SkillAppCatalog.isPath(backupURL, under: rootDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(backupURL.path)
        }
        guard SkillFileSystem.kind(of: backupURL) == .directory else {
            throw SkillError.backupNotFound(backupURL.lastPathComponent)
        }
        guard let metadata = metadata(at: backupURL) else {
            throw SkillError.backupCorrupted(backupURL.lastPathComponent)
        }
        let payload = backupURL.appendingPathComponent("skill", isDirectory: true)
        guard SkillFileSystem.kind(of: payload) == .directory else {
            throw SkillError.backupCorrupted(backupURL.lastPathComponent)
        }

        var skill = metadata.skill
        try SkillPathValidator.validate(directoryName: skill.directory)
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let destination = ssot.appendingPathComponent(skill.directory, isDirectory: true)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }
        guard SkillFileSystem.kind(of: destination) == .missing else {
            throw SkillError.destinationExists(skill.directory)
        }
        try SkillFileSystem.ensureDirectory(ssot, stopAt: homeURL)
        try SkillFileSystem.replaceDirectory(at: destination, withCopyOf: payload)
        skill.contentHash = try SkillDirectoryHasher.hash(directory: destination)
        return skill
    }

    public func deleteBackup(_ url: URL) throws {
        let root = rootDirectory
        guard
            SkillAppCatalog.isPath(url, under: root),
            url.standardizedFileURL.path != root.standardizedFileURL.path
        else {
            throw SkillError.writeOutsideAllowedRoots(url.path)
        }
        guard SkillFileSystem.kind(of: url) != .missing else {
            throw SkillError.backupNotFound(url.lastPathComponent)
        }
        try FileManager.default.removeItem(at: url)
    }

    public func prune(keeping: Int = SkillBackupManager.defaultRetainedBackups) {
        let backups = listBackups()
        guard backups.count > keeping else { return }
        for backup in backups.dropFirst(keeping) {
            try? deleteBackup(backup.url)
        }
    }

    // MARK: - Internals

    private var homeURL: URL { URL(fileURLWithPath: homeDirectory, isDirectory: true) }

    private func metadata(at backupURL: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: backupURL.appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func uniqueBackupURL(for name: String, at date: Date, in root: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: date)
        let base = "\(stamp)_\(name)"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while SkillFileSystem.kind(of: candidate) != .missing {
            candidate = root.appendingPathComponent("\(base)_\(suffix)", isDirectory: true)
            suffix += 1
            if suffix > 1_000 { throw SkillError.destinationExists(base) }
        }
        return candidate
    }
}
