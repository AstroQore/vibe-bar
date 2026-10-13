import Foundation

/// The whole-file choice in a two-version merge. No line-level merge is inferred.
public enum SkillMergeSide: String, Sendable, Hashable {
    case base
    case compared
}

public enum SkillResolutionError: Error, Equatable, Sendable, LocalizedError {
    case incompleteComparison
    case unresolvedFiles
    case contentChanged
    case conflictingStructure

    public var errorDescription: String? {
        switch self {
        case .incompleteComparison: L10n.Workbench.Skills.Copies.errorIncomplete
        case .unresolvedFiles: L10n.Workbench.Skills.Copies.errorUnresolved
        case .contentChanged: L10n.Workbench.Skills.Copies.errorChanged
        case .conflictingStructure: L10n.Workbench.Skills.Copies.errorStructure
        }
    }
}

extension SkillsService {
    public nonisolated var backupDirectory: URL { backups.rootDirectory }

    /// Overwrites just the selected harness folder, preserving its previous
    /// tree in backups and retaining its existing management state.
    @discardableResult
    public func overwriteCopyWithShared(_ id: SkillID, copy: SkillCopy) async throws -> Skill {
        try await resolveProjection(id, copy: copy, adopt: false, replaceShared: false)
    }

    /// Adopts a same-directory independent copy. The caller must explicitly
    /// choose whether its content replaces shared content first. Neither
    /// choice changes the harness's native enable/disable configuration.
    @discardableResult
    public func adoptCopy(
        _ id: SkillID, copy: SkillCopy, replaceShared: Bool
    ) async throws -> Skill {
        try await resolveProjection(id, copy: copy, adopt: true, replaceShared: replaceShared)
    }

    /// All differing files require a decision, including additions/deletions.
    /// Hidden shared files survive unchanged; a truncated comparison is refused.
    /// Expected hashes bind UI choices to the versions the user actually saw.
    @discardableResult
    public func mergeIntoShared(
        _ id: SkillID, from copy: SkillCopy, resolutions: [String: SkillMergeSide],
        expectedSharedHash: String? = nil
    ) async throws -> Skill {
        let existing = try await editableSkill(id)
        let source = try validatedCopySource(copy)
        guard readScope.resolvedSkillDirectory(source) != nil else {
            throw SkillError.copyOutsideScannedRoots(copy.directoryName)
        }
        let shared = ssotDirectory(for: existing.directory)
        let sharedHash = try SkillDirectoryHasher.hash(directory: shared)
        let sourceHash = try SkillDirectoryHasher.hash(directory: source)
        if let expectedSharedHash, expectedSharedHash != sharedHash { throw SkillResolutionError.contentChanged }
        if let expected = copy.contentHash, expected != sourceHash { throw SkillResolutionError.contentChanged }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("skill-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let assembled = temporary.appendingPathComponent("assembled")
        let compared = temporary.appendingPathComponent("compared")
        try FileManager.default.copyItem(at: shared, to: assembled)
        try FileManager.default.copyItem(at: source, to: compared)
        guard try SkillDirectoryHasher.hash(directory: assembled) == sharedHash,
              try SkillDirectoryHasher.hash(directory: compared) == sourceHash else {
            throw SkillResolutionError.contentChanged
        }
        let comparison = try SkillContentDiff.compare(
            left: assembled, right: compared, scope: SkillReadScope(roots: [temporary])
        )
        guard !comparison.truncated else { throw SkillResolutionError.incompleteComparison }
        let changed = comparison.files.filter { $0.change != .unchanged }
        guard changed.allSatisfy({ resolutions[$0.path] != nil }),
              Set(resolutions.keys).isSubset(of: Set(changed.map(\.path))) else {
            throw SkillResolutionError.unresolvedFiles
        }
        let chosen = changed.filter { resolutions[$0.path] == .compared }
        // Remove old leaves first, so a file can become a directory (or the
        // reverse) without ever opening a link as a destination directory.
        for file in chosen where file.left != nil {
            let target = try mergeLeaf(file.path, in: assembled)
            try FileManager.default.removeItem(at: target)
        }
        for file in chosen where file.right != nil {
            let target = try mergeLeaf(file.path, in: assembled, createParents: true)
            if SkillFileSystem.kind(of: target) == .directory {
                guard try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty else {
                    throw SkillResolutionError.conflictingStructure
                }
                try FileManager.default.removeItem(at: target)
            }
            guard SkillFileSystem.kind(of: target) == .missing else {
                throw SkillResolutionError.conflictingStructure
            }
            let from = try mergeLeaf(file.path, in: compared)
            // copyItem preserves a leaf symlink; it never writes its target.
            try FileManager.default.copyItem(at: from, to: target)
        }
        guard try SkillDirectoryHasher.hash(directory: shared) == sharedHash,
              try SkillDirectoryHasher.hash(directory: source) == sourceHash else {
            throw SkillResolutionError.contentChanged
        }
        return try await commitSharedContent(existing, from: assembled)
    }

    /// Restores a listed backup over an installed skill through the normal
    /// backup + shared commit path. Arbitrary folders cannot pose as backups.
    @discardableResult
    public func restoreBackupToShared(_ id: SkillID, backupURL: URL) async throws -> Skill {
        let existing = try await editableSkill(id)
        guard let backup = backups.listBackups().first(where: {
            $0.url.standardizedFileURL == backupURL.standardizedFileURL && $0.skill?.id == id
        }) else { throw SkillError.backupNotFound(backupURL.lastPathComponent) }
        let payload = backup.url.appendingPathComponent("skill")
        guard SkillFileSystem.kind(of: payload) == .directory,
              readScope.resolvedSkillDirectory(payload) != nil else {
            throw SkillError.backupCorrupted(backup.directoryName)
        }
        try SkillFileSystem.validateDirectoryAncestors(payload, homeDirectory: homeDirectory)
        // Staged outside the backup root: the commit takes a backup of the
        // current shared content first, and that backup's prune may delete
        // this very directory when it is the oldest of the retained set.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("skill-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("skill")
        try FileManager.default.copyItem(at: payload, to: staged)
        return try await commitSharedContent(existing, from: staged)
    }

    private func editableSkill(_ id: SkillID) async throws -> Skill {
        guard let skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        guard !skill.isLinked else { throw SkillError.linkedSkillUnsupported(skill.directory) }
        let shared = ssotDirectory(for: skill.directory)
        guard SkillFileSystem.kind(of: shared) == .directory else {
            throw SkillError.sourceNotADirectory(skill.directory)
        }
        guard SkillAppCatalog.isWriteAllowed(shared, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(shared.path)
        }
        try SkillFileSystem.validateDirectoryAncestors(shared, homeDirectory: homeDirectory)
        return skill
    }

    private func resolveProjection(
        _ id: SkillID, copy: SkillCopy, adopt: Bool, replaceShared: Bool
    ) async throws -> Skill {
        var skill = try await editableSkill(id)
        let source = try validatedCopySource(copy)
        guard case let .appFolder(app) = copy.location, app.supportsProjection,
              copy.directoryName == skill.directory,
              SkillAppCatalog.isWriteAllowed(source, homeDirectory: homeDirectory) else {
            throw SkillError.copyOutsideScannedRoots(copy.directoryName)
        }
        try SkillFileSystem.validateDirectoryAncestors(source, homeDirectory: homeDirectory)
        let currentHash = try SkillDirectoryHasher.hash(directory: source)
        if let expected = copy.contentHash, expected != currentHash { throw SkillResolutionError.contentChanged }
        try backups.createBackup(ofCopy: source, app: app, skill: skill)
        if replaceShared {
            // The selected copy is already backed up and is the source of
            // the replacement; leave it for the final projection step.
            skill.apps[app] = nil
            skill = try await commitSharedContent(skill, from: source)
        }
        // This fresh receipt is only used after the explicit overwrite/adopt
        // choice and its backup; ordinary toggles still refuse foreign copies.
        let receipt = SkillMaterialization(method: .copy, contentHashAtCopy: currentHash)
        let wasManaged = skill.apps[app] != nil
        let materialization = try engine.materialize(
            skillDirectoryName: skill.directory, into: app,
            method: adopt ? .auto : .copy, recorded: receipt
        )
        if adopt || wasManaged { skill.apps[app] = materialization }
        skill.retiredCopyHashes[app] = nil
        skill.updatedAt = Date()
        try await store.upsert(skill)
        return skill
    }

    private func mergeLeaf(_ path: String, in root: URL, createParents: Bool = false) throws -> URL {
        guard SkillContentDiff.isSafeRelativePath(path) else { throw SkillDiffError.invalidRelativePath(path) }
        let parts = path.split(separator: "/").map(String.init)
        var directory = root
        for part in parts.dropLast() {
            directory.appendPathComponent(part)
            if createParents, SkillFileSystem.kind(of: directory) == .missing {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            guard SkillFileSystem.kind(of: directory) == .directory else {
                throw SkillResolutionError.conflictingStructure
            }
        }
        return directory.appendingPathComponent(parts.last!)
    }
}
