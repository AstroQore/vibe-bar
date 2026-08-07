import Foundation

/// What an update check found for one installed, repository-backed skill.
public struct SkillUpdateState: Sendable, Hashable, Identifiable {
    public let id: SkillID
    public let name: String
    public let localHash: String?
    public let remoteHash: String?
    public let updateAvailable: Bool

    public init(id: SkillID, name: String, localHash: String?, remoteHash: String?, updateAvailable: Bool) {
        self.id = id
        self.name = name
        self.localHash = localHash
        self.remoteHash = remoteHash
        self.updateAvailable = updateAvailable
    }
}

/// The repository-facing half of `SkillsService`: browse, install, check, and
/// update.
///
/// The ordering rule from the core actor holds throughout — **filesystem
/// first, store second**. A skill is copied into the SSOT and materialized into
/// every requested app *before* `skills.json` learns it exists, so a failed
/// install leaves a registry that still describes the disk.
///
/// Failure isolation is per repository. Discovery over four repositories where
/// one has been deleted returns the skills from the other three and logs the
/// miss; it is a browser, not a transaction.
extension SkillsService {
    // MARK: - Configured repositories

    public func discoverRepos() async -> [String] {
        await store.discoverRepos()
    }

    public func discoverRepoRefs() async -> [SkillRepoRef] {
        await store.discoverRepoRefs()
    }

    public func setDiscoverRepos(_ repos: [String]) async throws {
        try await store.setDiscoverRepos(repos)
    }

    @discardableResult
    public func addDiscoverRepo(_ raw: String) async throws -> Bool {
        try await store.addDiscoverRepo(raw)
    }

    @discardableResult
    public func removeDiscoverRepo(_ raw: String) async throws -> Bool {
        try await store.removeDiscoverRepo(raw)
    }

    // MARK: - Discovery

    /// Downloads every configured repository and lists the skills in them.
    public func discoverSkills() async -> [DiscoveredSkill] {
        await discoverSkills(from: await store.discoverRepoRefs())
    }

    /// Downloads `repos` in parallel and lists the skills in them.
    ///
    /// The results point into a staging directory this actor owns; it survives
    /// until the next discovery pass or `clearDiscoveryStaging()`, which is
    /// what makes `install(_:enableFor:)` able to copy from them later.
    public func discoverSkills(from repos: [SkillRepoRef]) async -> [DiscoveredSkill] {
        guard !repos.isEmpty else { return [] }
        clearDiscoveryStaging()
        let staging = Self.temporaryDirectory(prefix: "discover")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            SafeLog.warn("Skills discovery: no staging directory")
            return []
        }
        discoveryStaging = staging

        let fetcher = self.fetcher
        let discovered = await withTaskGroup(of: [DiscoveredSkill].self) { group in
            for (index, ref) in repos.enumerated() {
                let directory = staging.appendingPathComponent("repo-\(index)", isDirectory: true)
                group.addTask {
                    do {
                        let (root, branch) = try await fetcher.downloadRepo(ref, into: directory)
                        return try fetcher.scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: branch)
                    } catch {
                        SafeLog.warn(
                            "Skills discovery skipped \(ref.slug): \(SafeLog.sanitize(error.localizedDescription))"
                        )
                        return []
                    }
                }
            }
            var all: [DiscoveredSkill] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        var seen = Set<SkillID>()
        return discovered
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Drops the extracted repositories the last discovery pass left behind.
    /// Any `DiscoveredSkill` from that pass becomes uninstallable afterwards.
    public func clearDiscoveryStaging() {
        guard let staging = discoveryStaging else { return }
        discoveryStaging = nil
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Install

    /// Installs a discovered skill into the SSOT and enables it for `apps`.
    ///
    /// Re-installing the same id is an enable, not a conflict: the SSOT copy is
    /// left alone (`update(_:)` is the way to refresh content) and only the
    /// requested apps are materialized. A *different* skill already holding the
    /// directory name is a `directoryConflict` — the directory name is part of
    /// every skill's identity and cannot be shared.
    @discardableResult
    public func install(
        _ discovered: DiscoveredSkill,
        enableFor apps: [SkillAppTarget],
        method: SkillSyncMethod = .auto
    ) async throws -> Skill {
        try SkillPathValidator.validate(directoryName: discovered.directory)

        if let existing = await store.skill(directory: discovered.directory) {
            guard existing.id == discovered.id else {
                throw SkillError.directoryConflict(discovered.directory)
            }
            var skill = existing
            for app in apps {
                skill.apps[app] = try engine.materialize(
                    skillDirectoryName: skill.directory,
                    into: app,
                    method: method,
                    recorded: skill.apps[app]
                )
            }
            try await store.upsert(skill)
            return skill
        }

        guard SkillFileSystem.kind(of: discovered.sourceRoot) == .directory else {
            throw SkillError.sourceNotADirectory(discovered.directory)
        }
        guard SkillTreeScanner.isSkillDirectory(discovered.sourceRoot) else {
            throw SkillError.missingSkillMD(discovered.directory)
        }
        try copyIntoSSOT(from: discovered.sourceRoot, directoryName: discovered.directory)

        let installed = ssotDirectory(for: discovered.directory)
        var skill = Skill(
            id: discovered.id,
            name: discovered.name,
            description: discovered.description,
            directory: discovered.directory,
            repoBranch: discovered.branch,
            installedAt: Date(),
            contentHash: try SkillDirectoryHasher.hash(directory: installed)
        )
        for app in apps {
            skill.apps[app] = try engine.materialize(
                skillDirectoryName: skill.directory,
                into: app,
                method: method
            )
        }
        try await store.upsert(skill)
        return skill
    }

    /// Installs every skill found inside a local `.zip`, as `.local` skills.
    ///
    /// Best-effort by design: a zip holding five skills where two collide with
    /// installed directories installs the other three. It throws only when the
    /// archive itself is unusable or holds no skill at all — the caller can
    /// compare the returned count against what it expected.
    @discardableResult
    public func installFromZip(
        at zipURL: URL,
        enableFor apps: [SkillAppTarget],
        method: SkillSyncMethod = .auto
    ) async throws -> [Skill] {
        let staging = Self.temporaryDirectory(prefix: "zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try SkillArchiveExtractor.extract(zipFileURL: zipURL, into: staging)

        // Three archive shapes reach this line and the scanner handles all of
        // them: a bare `SKILL.md` at the root (the zip *is* the skill, named
        // after the file), a single skill folder, and a folder of skill
        // folders. Nobody has to tell us which one the user picked.
        let found = SkillTreeScanner.scan(root: staging)
        guard !found.isEmpty else {
            throw SkillError.missingSkillMD(zipURL.deletingPathExtension().lastPathComponent)
        }

        var installed: [Skill] = []
        for entry in found {
            let directory = entry.relativePath.isEmpty
                ? zipURL.deletingPathExtension().lastPathComponent
                : String(entry.relativePath.split(separator: "/").last ?? "")
            guard SkillPathValidator.isValid(directory) else {
                SafeLog.warn("Skills zip import skipped an entry with an unusable directory name")
                continue
            }
            if await store.skill(directory: directory) != nil { continue }
            do {
                installed.append(
                    try await installLocalDirectory(
                        at: entry.url,
                        directoryName: directory,
                        enableFor: apps,
                        method: method
                    )
                )
            } catch {
                SafeLog.warn("Skills zip import skipped a skill: \(SafeLog.sanitize(error.localizedDescription))")
            }
        }
        return installed
    }

    // MARK: - Updates

    /// Downloads every repository that has installed skills (once per
    /// owner/repo/branch, however many skills came from it) and compares
    /// directory hashes.
    ///
    /// A local hash missing from the registry — an adopted skill, or one
    /// written by an older build — is computed here and written back, so the
    /// next check has it.
    public func checkForUpdates() async -> [SkillUpdateState] {
        let installed = await store.all().filter { $0.id.isRepositoryBacked }
        guard !installed.isEmpty else { return [] }

        var groups: [String: (ref: SkillRepoRef, skills: [Skill])] = [:]
        for skill in installed {
            guard
                case let .repo(owner, repo, _) = skill.id,
                let ref = SkillRepoRef(owner: owner, repo: repo, branch: skill.repoBranch)
            else { continue }
            groups[ref.descriptor, default: (ref, [])].skills.append(skill)
        }
        guard !groups.isEmpty else { return [] }

        let staging = Self.temporaryDirectory(prefix: "updates")
        defer { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let fetcher = self.fetcher
        let remoteHashes: [SkillID: String] = await withTaskGroup(
            of: [SkillID: String].self
        ) { group in
            for (index, entry) in groups.values.enumerated() {
                let directory = staging.appendingPathComponent("repo-\(index)", isDirectory: true)
                let ref = entry.ref
                let wanted = entry.skills.map(\.directory)
                group.addTask {
                    do {
                        let (root, branch) = try await fetcher.downloadRepo(ref, into: directory)
                        let discovered = try fetcher.scanSkills(
                            inRepoRoot: root,
                            ref: ref,
                            resolvedBranch: branch
                        )
                        var hashes: [SkillID: String] = [:]
                        for name in wanted {
                            guard
                                let match = Self.match(directory: name, in: discovered),
                                let hash = try? SkillDirectoryHasher.hash(directory: match.sourceRoot)
                            else { continue }
                            hashes[.repo(owner: ref.owner, repo: ref.repo, directory: name)] = hash
                        }
                        return hashes
                    } catch {
                        SafeLog.warn(
                            "Skills update check skipped \(ref.slug): \(SafeLog.sanitize(error.localizedDescription))"
                        )
                        return [:]
                    }
                }
            }
            var merged: [SkillID: String] = [:]
            for await batch in group { merged.merge(batch) { current, _ in current } }
            return merged
        }

        var states: [SkillUpdateState] = []
        for skill in installed {
            var localHash = skill.contentHash
            if localHash == nil {
                localHash = try? SkillDirectoryHasher.hash(directory: ssotDirectory(for: skill.directory))
                if let localHash {
                    var backfilled = skill
                    backfilled.contentHash = localHash
                    try? await store.upsert(backfilled)
                }
            }
            let remoteHash = remoteHashes[skill.id]
            states.append(
                SkillUpdateState(
                    id: skill.id,
                    name: skill.name,
                    localHash: localHash,
                    remoteHash: remoteHash,
                    updateAvailable: remoteHash != nil && localHash != nil && remoteHash != localHash
                )
            )
        }
        return states.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Re-downloads a repository-backed skill and replaces its SSOT directory.
    ///
    /// A backup is taken first — same contract as uninstall — because the
    /// replacement is destructive to anything the user edited in place. Apps
    /// that had the skill enabled are re-materialized with the method they were
    /// already using, so an app holding a managed *copy* sees the new content
    /// rather than silently keeping the old one.
    @discardableResult
    public func update(_ id: SkillID) async throws -> Skill {
        guard let existing = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        guard
            case let .repo(owner, repo, _) = id,
            let ref = SkillRepoRef(owner: owner, repo: repo, branch: existing.repoBranch)
        else { throw SkillError.notRepositoryBacked(id) }

        let staging = Self.temporaryDirectory(prefix: "update")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let (root, branch) = try await fetcher.downloadRepo(ref, into: staging)
        let discovered = try fetcher.scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: branch)
        guard let match = Self.match(directory: existing.directory, in: discovered) else {
            throw SkillError.updateSourceMissing(existing.directory)
        }
        guard SkillTreeScanner.isSkillDirectory(match.sourceRoot) else {
            throw SkillError.missingSkillMD(existing.directory)
        }

        try backups.createBackup(of: existing.directory, skill: existing)

        let destination = ssotDirectory(for: existing.directory)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }
        try SkillFileSystem.replaceDirectory(at: destination, withCopyOf: match.sourceRoot)

        var skill = existing
        skill.name = match.name
        skill.description = match.description
        skill.repoBranch = branch
        skill.contentHash = try SkillDirectoryHasher.hash(directory: destination)
        skill.updatedAt = Date()
        for (app, materialization) in existing.apps {
            skill.apps[app] = try engine.materialize(
                skillDirectoryName: skill.directory,
                into: app,
                method: materialization.method,
                recorded: materialization
            )
        }
        try await store.upsert(skill)
        return skill
    }

    // MARK: - Internals

    /// Installs one already-extracted skill directory as a `.local` skill and
    /// enables the requested apps. Filesystem first, store second.
    private func installLocalDirectory(
        at source: URL,
        directoryName: String,
        enableFor apps: [SkillAppTarget],
        method: SkillSyncMethod
    ) async throws -> Skill {
        try SkillPathValidator.validate(directoryName: directoryName)
        guard SkillTreeScanner.isSkillDirectory(source) else {
            throw SkillError.missingSkillMD(directoryName)
        }
        try copyIntoSSOT(from: source, directoryName: directoryName)

        let installed = ssotDirectory(for: directoryName)
        let frontmatter = SkillFrontmatterParser.parse(
            contentsOf: installed.appendingPathComponent("SKILL.md")
        )
        var skill = Skill(
            id: .local(directory: directoryName),
            name: frontmatter.name ?? directoryName,
            description: frontmatter.description,
            directory: directoryName,
            installedAt: Date(),
            contentHash: try SkillDirectoryHasher.hash(directory: installed)
        )
        for app in apps {
            skill.apps[app] = try engine.materialize(
                skillDirectoryName: directoryName,
                into: app,
                method: method
            )
        }
        try await store.upsert(skill)
        return skill
    }

    /// Repository layouts are not case-consistent (`PDF/` vs `pdf/`), and the
    /// SSOT lives on a case-insensitive filesystem, so matching an installed
    /// directory to a discovered one is case-insensitive too.
    static func match(directory: String, in discovered: [DiscoveredSkill]) -> DiscoveredSkill? {
        discovered.first { $0.directory == directory }
            ?? discovered.first { $0.directory.caseInsensitiveCompare(directory) == .orderedSame }
    }

    static func temporaryDirectory(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSkills-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
