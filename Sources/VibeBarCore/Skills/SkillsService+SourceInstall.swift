import Foundation

/// One-shot install from a source someone named, rather than one they picked
/// out of a discovery list.
///
/// This is what the MCP `skills.install` tool calls, and it deliberately goes
/// through the *same* `install(_:enableFor:method:)` and
/// `installLocalDirectory(...)` the Workbench uses: same SSOT copy, same
/// `SkillSyncEngine` materialization, same write allowlist. Nothing here
/// touches the filesystem itself, so there is exactly one place where a skill
/// can land on disk.
///
/// It does not share the discovery staging directory. The Workbench keeps that
/// alive so its rows stay installable, and an agent installing a skill in the
/// background must not delete the tree the user is looking at — so this owns a
/// temporary directory for the length of the call and removes it.
extension SkillsService {
    @discardableResult
    public func install(
        from source: SkillInstallSource,
        enableFor apps: [SkillAppTarget] = [],
        method: SkillSyncMethod = .auto
    ) async throws -> SkillInstallOutcome {
        switch source {
        case let .repository(ref, skillDirectory):
            return try await installFromRepository(
                ref: ref,
                skillDirectory: skillDirectory,
                descriptor: source.descriptor,
                apps: apps,
                method: method
            )
        case let .localDirectory(url):
            return try await installFromLocalPath(at: url, apps: apps, method: method)
        }
    }

    // MARK: - Repository

    private func installFromRepository(
        ref: SkillRepoRef,
        skillDirectory: String?,
        descriptor: String,
        apps: [SkillAppTarget],
        method: SkillSyncMethod
    ) async throws -> SkillInstallOutcome {
        let staging = Self.temporaryDirectory(prefix: "mcp-install")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let (root, branch) = try await fetcher.downloadRepo(ref, into: staging)
        let discovered = try fetcher.scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: branch)
        guard !discovered.isEmpty else {
            throw SkillInstallSourceError.noSkillsFound(ref.slug)
        }

        let target: DiscoveredSkill
        if let skillDirectory {
            // A repository lays a skill out under a directory but names it in
            // frontmatter; an agent will have read either one.
            guard let match = Self.match(directory: skillDirectory, in: discovered)
                ?? discovered.first(where: { $0.name.caseInsensitiveCompare(skillDirectory) == .orderedSame })
            else {
                throw SkillInstallSourceError.skillNotFound(
                    name: skillDirectory,
                    source: ref.slug,
                    available: discovered.map(\.directory)
                )
            }
            target = match
        } else if discovered.count == 1 {
            target = discovered[0]
        } else {
            // Installing all of them is not a reasonable guess: a skills
            // collection can hold dozens, and each one is a directory in
            // every enabled agent CLI.
            throw SkillInstallSourceError.ambiguous(
                source: ref.descriptor,
                available: discovered.map(\.directory)
            )
        }

        let skill = try await install(target, enableFor: apps, method: method)
        return SkillInstallOutcome(
            source: descriptor,
            installed: [record(skill)],
            skipped: []
        )
    }

    // MARK: - Local directory

    /// The local half is deliberately narrow: one directory that is itself a
    /// skill. `kind(of:)` lstats, so a symlink is refused rather than followed
    /// — a link is an invitation to copy from somewhere the caller never
    /// named.
    private func installFromLocalPath(
        at url: URL,
        apps: [SkillAppTarget],
        method: SkillSyncMethod
    ) async throws -> SkillInstallOutcome {
        let source = url.standardizedFileURL
        guard SkillFileSystem.kind(of: source) == .directory else {
            throw SkillError.sourceNotADirectory(source.path)
        }
        let directoryName = source.lastPathComponent
        try SkillPathValidator.validate(directoryName: directoryName)
        guard SkillTreeScanner.isSkillDirectory(source) else {
            throw SkillError.missingSkillMD(directoryName)
        }

        // Re-pointing at a directory that is already installed is an enable,
        // matching what `install(_:enableFor:)` does for a repository skill.
        if let existing = await store.skill(directory: directoryName) {
            guard existing.id == .local(directory: directoryName) else {
                throw SkillError.directoryConflict(directoryName)
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
            return SkillInstallOutcome(
                source: source.path,
                installed: [record(skill)],
                skipped: [SkillInstallOutcome.Skipped(name: directoryName, reason: "already installed")]
            )
        }

        let skill = try await installLocalDirectory(
            at: source,
            directoryName: directoryName,
            enableFor: apps,
            method: method
        )
        return SkillInstallOutcome(source: source.path, installed: [record(skill)], skipped: [])
    }

    // MARK: - Internals

    private func record(_ skill: Skill) -> SkillInstallOutcome.Installed {
        var projected: [SkillAppTarget: String] = [:]
        for app in skill.projectedApps {
            projected[app] = SkillAppCatalog
                .skillsDirectory(for: app, homeDirectory: homeDirectory)
                .appendingPathComponent(skill.directory, isDirectory: true)
                .path
        }
        return SkillInstallOutcome.Installed(
            skill: skill,
            path: ssotDirectory(for: skill.directory).path,
            projectedTo: projected
        )
    }
}
