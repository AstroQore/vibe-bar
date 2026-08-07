import Foundation

/// Orchestrates the registry, the sync engine, and backups.
///
/// The ordering rule every mutating method follows: **filesystem first, store
/// second**. `skills.json` is a description of what is on disk, so a failed
/// materialize must leave the registry exactly as it was rather than claiming
/// a state the filesystem never reached. The reverse order would make the
/// enable bits lie after the first permission error.
///
/// Everything that reaches the network does so through `SkillRepoFetching`,
/// which is injected: `Skill.id` carries the repository slug and
/// `Skill.repoBranch` the branch, so discovery, install, update checks, and
/// updates are all expressible against that one seam — and testable without it.
public actor SkillsService {
    public struct UninstallResult: Sendable {
        public let backupURL: URL
        /// Per app: whether the app-side entry was actually removed. `false`
        /// means something the user could have authored was left in place.
        public let removedByApp: [SkillAppTarget: Bool]
    }

    // Internal rather than private: the repository-facing half of this actor
    // lives in `SkillsService+Repositories.swift`.
    let homeDirectory: String
    let store: SkillsStore
    let engine: SkillSyncEngine
    let backups: SkillBackupManager
    let fetcher: SkillRepoFetching
    /// Where the trees behind the current `[DiscoveredSkill]` live. Discovery
    /// results reference files on disk, so the extraction has to outlive the
    /// call that produced it; it is replaced on the next discovery pass and can
    /// be dropped explicitly once the user closes the browser.
    var discoveryStaging: URL?

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        fetcher: SkillRepoFetching = SkillRepoFetcher()
    ) {
        self.homeDirectory = homeDirectory
        self.store = SkillsStore(homeDirectory: homeDirectory)
        self.engine = SkillSyncEngine(homeDirectory: homeDirectory)
        self.backups = SkillBackupManager(homeDirectory: homeDirectory)
        self.fetcher = fetcher
    }

    deinit {
        if let discoveryStaging { try? FileManager.default.removeItem(at: discoveryStaging) }
    }

    public func installedSkills() async -> [Skill] {
        await store.all()
    }

    public func skill(with id: SkillID) async -> Skill? {
        await store.skill(with: id)
    }

    /// Enables or disables `id` for one app. Returns whether the filesystem
    /// changed: disabling reports `false` when the app-side entry was left
    /// alone (a foreign directory, or a copy the user has edited), while the
    /// enable bit still clears — the user asked Vibe Bar to stop managing it.
    @discardableResult
    public func setEnabled(
        _ id: SkillID,
        app: SkillAppTarget,
        enabled: Bool,
        method: SkillSyncMethod = .auto
    ) async throws -> Bool {
        guard var skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        if enabled {
            let materialization = try engine.materialize(
                skillDirectoryName: skill.directory,
                into: app,
                method: method,
                recorded: skill.apps[app]
            )
            skill.apps[app] = materialization
            try await store.upsert(skill)
            return true
        }
        let removed = try engine.unmaterialize(
            skillDirectoryName: skill.directory,
            from: app,
            recorded: skill.apps[app]
        )
        skill.apps[app] = nil
        try await store.upsert(skill)
        return removed
    }

    /// Backs the skill up, unmaterializes it from every app, deletes the SSOT
    /// directory, and forgets it. The backup is taken first so a failure
    /// anywhere later still leaves the content recoverable.
    @discardableResult
    public func uninstall(_ id: SkillID) async throws -> UninstallResult {
        guard let skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        let backupURL = try backups.createBackup(of: skill.directory, skill: skill)
        var removedByApp: [SkillAppTarget: Bool] = [:]
        for app in SkillAppTarget.allCases {
            removedByApp[app] = try engine.unmaterialize(
                skillDirectoryName: skill.directory,
                from: app,
                recorded: skill.apps[app]
            )
        }
        try removeFromSSOT(skill.directory)
        try await store.remove(id: id)
        return UninstallResult(backupURL: backupURL, removedByApp: removedByApp)
    }

    public nonisolated func scanForImport() -> SkillImportReport {
        SkillImportScanner.scan(homeDirectory: homeDirectory)
    }

    /// Records the skills an import scan recognized. Only materializations for
    /// `apps` are taken from the report; anything already recorded for another
    /// app is preserved, so a partial import never drops known state.
    @discardableResult
    public func importAdopted(
        _ report: SkillImportReport,
        apps: [SkillAppTarget] = SkillAppTarget.allCases
    ) async throws -> [Skill] {
        let allowed = Set(apps)
        var imported: [Skill] = []
        for scanned in report.adopted {
            var skill = scanned
            skill.apps = skill.apps.filter { allowed.contains($0.key) }
            if let existing = await store.skill(with: skill.id) {
                var merged = existing
                merged.name = skill.name
                merged.description = skill.description
                merged.directory = skill.directory
                merged.repoBranch = skill.repoBranch
                merged.contentHash = skill.contentHash
                merged.updatedAt = skill.updatedAt
                for (app, materialization) in skill.apps { merged.apps[app] = materialization }
                skill = merged
            }
            try await store.upsert(skill)
            imported.append(skill)
        }
        return imported
    }

    /// Brings a foreign app-side skill directory under management: copies it
    /// into the SSOT, then materializes it into the chosen apps (including,
    /// normally, the one it came from — which replaces the original directory
    /// with a link or a managed copy).
    @discardableResult
    public func adoptUnmanaged(
        directoryName: String,
        from app: SkillAppTarget,
        apps: [SkillAppTarget],
        method: SkillSyncMethod = .auto
    ) async throws -> Skill {
        try SkillPathValidator.validate(directoryName: directoryName)
        let source = SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
        guard SkillFileSystem.kind(of: source) == .directory else {
            throw SkillError.sourceNotADirectory(directoryName)
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw SkillError.missingSkillMD(directoryName)
        }
        try copyIntoSSOT(from: source, directoryName: directoryName)

        var skill = try makeLocalSkill(directoryName: directoryName)
        for target in apps {
            skill.apps[target] = try engine.materialize(
                skillDirectoryName: directoryName,
                into: target,
                method: method
            )
        }
        try await store.upsert(skill)
        return skill
    }

    /// Installs a skill from an arbitrary directory on disk. No app is enabled
    /// — the caller decides that separately.
    @discardableResult
    public func installLocal(from sourceDir: URL, name: String) async throws -> Skill {
        try SkillPathValidator.validate(directoryName: name)
        guard SkillFileSystem.kind(of: sourceDir) == .directory else {
            throw SkillError.sourceNotADirectory(sourceDir.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent("SKILL.md").path) else {
            throw SkillError.missingSkillMD(name)
        }
        try copyIntoSSOT(from: sourceDir, directoryName: name)
        let skill = try makeLocalSkill(directoryName: name)
        try await store.upsert(skill)
        return skill
    }

    // MARK: - Backups

    public nonisolated func listBackups() -> [SkillBackupManager.Backup] {
        backups.listBackups()
    }

    @discardableResult
    public func restoreBackup(_ backupURL: URL) async throws -> Skill {
        let skill = try backups.restore(backupURL: backupURL)
        try await store.upsert(skill)
        return skill
    }

    public nonisolated func deleteBackup(_ backupURL: URL) throws {
        try backups.deleteBackup(backupURL)
    }

    // MARK: - Internals

    var homeURL: URL { URL(fileURLWithPath: homeDirectory, isDirectory: true) }

    func ssotDirectory(for directoryName: String) -> URL {
        SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    func copyIntoSSOT(from source: URL, directoryName: String) throws {
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let destination = ssot.appendingPathComponent(directoryName, isDirectory: true)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }
        guard SkillFileSystem.kind(of: destination) == .missing else {
            throw SkillError.directoryConflict(directoryName)
        }
        try SkillFileSystem.ensureDirectory(ssot, stopAt: homeURL)
        try SkillFileSystem.replaceDirectory(at: destination, withCopyOf: source)
    }

    private func removeFromSSOT(_ directoryName: String) throws {
        try SkillPathValidator.validate(directoryName: directoryName)
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let directory = ssot.appendingPathComponent(directoryName, isDirectory: true)
        guard
            SkillAppCatalog.isPath(directory, under: ssot),
            SkillAppCatalog.isWriteAllowed(directory, homeDirectory: homeDirectory)
        else {
            throw SkillError.writeOutsideAllowedRoots(directory.path)
        }
        switch SkillFileSystem.kind(of: directory) {
        case .missing: return
        case .directory: try FileManager.default.removeItem(at: directory)
        default: throw SkillError.sourceNotADirectory(directoryName)
        }
    }

    private func makeLocalSkill(directoryName: String) throws -> Skill {
        let directory = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
        let frontmatter = SkillFrontmatterParser.parse(
            contentsOf: directory.appendingPathComponent("SKILL.md")
        )
        return Skill(
            id: .local(directory: directoryName),
            name: frontmatter.name ?? directoryName,
            description: frontmatter.description,
            directory: directoryName,
            installedAt: Date(),
            contentHash: try SkillDirectoryHasher.hash(directory: directory)
        )
    }
}
