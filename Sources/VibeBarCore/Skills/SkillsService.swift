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

        public var retainedApps: [SkillAppTarget] {
            SkillAppTarget.allCases.filter { removedByApp[$0] == false }
        }
    }

    // Internal rather than private: the repository-facing half of this actor
    // lives in `SkillsService+Repositories.swift`.
    let homeDirectory: String
    let store: SkillsStore
    let engine: SkillSyncEngine
    let harnessConfig: SkillHarnessConfigManager
    let backups: SkillBackupManager
    let fetcher: SkillRepoFetching
    /// Where the trees behind the current `[DiscoveredSkill]` live. Discovery
    /// results reference files on disk, so the extraction has to outlive the
    /// call that produced it; it is replaced on the next discovery pass and can
    /// be dropped explicitly once the user closes the browser.
    var discoveryStaging: URL?
    private struct CopyVerification: Sendable {
        let metadataStamp: String
        let contentHash: String
    }
    private var copyVerificationCache: [String: CopyVerification] = [:]

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        fetcher: SkillRepoFetching = SkillRepoFetcher()
    ) {
        self.homeDirectory = homeDirectory
        self.store = SkillsStore(homeDirectory: homeDirectory)
        self.engine = SkillSyncEngine(homeDirectory: homeDirectory)
        self.harnessConfig = SkillHarnessConfigManager(homeDirectory: homeDirectory)
        self.backups = SkillBackupManager(homeDirectory: homeDirectory)
        self.fetcher = fetcher
    }

    deinit {
        if let discoveryStaging { try? FileManager.default.removeItem(at: discoveryStaging) }
    }

    public func installedSkills() async -> [Skill] {
        let storeSnapshot = await store.snapshot()
        let snapshots = storeSnapshot.skills
        let nativeStates: [SkillAppTarget: [String: SkillHarnessConfigManager.NativeState]] = [
            .codex: harnessConfig.codexStates(for: snapshots),
            .claude: harnessConfig.claudeStates(for: snapshots),
            .gemini: harnessConfig.geminiStates(for: snapshots),
            .grok: harnessConfig.grokStates(for: snapshots),
        ]
        var result: [Skill] = []
        var liveCopyKeys: Set<String> = []
        var reconciledApps: [SkillID: [SkillAppTarget: SkillMaterialization]] = [:]
        result.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            var reconciled = snapshot
            let recordedApps = snapshot.apps
            for (app, recorded) in recordedApps {
                let currentCopyHash: String?
                if recorded.method == .copy {
                    let destination = engine.destination(for: snapshot.directory, app: app)
                    let key = destination.standardizedFileURL.path
                    liveCopyKeys.insert(key)
                    currentCopyHash = verifiedCopyHash(at: destination, key: key)
                } else {
                    currentCopyHash = nil
                }
                if let live = engine.liveMaterialization(
                    skillDirectoryName: snapshot.directory,
                    app: app,
                    recorded: recorded,
                    currentCopyHash: currentCopyHash
                ) {
                    reconciled.apps[app] = live
                } else {
                    reconciled.apps[app] = nil
                }
            }
            for app in SkillAppTarget.managedHarnesses where app.supportsNativeSkillActivation {
                switch nativeStates[app]?[snapshot.directory] ?? .unknown {
                case .enabled: break
                case .disabled: reconciled.nativeDisabledApps.insert(app)
                case .unknown: reconciled.nativeStateUnknownApps.insert(app)
                }
            }
            guard reconciled.apps != recordedApps else {
                // Native state is intentionally transient and does not make
                // `apps` differ. Return the enriched value even when no
                // registry reconciliation needs to be persisted.
                result.append(reconciled)
                continue
            }
            reconciledApps[snapshot.id] = reconciled.apps
            result.append(reconciled)
        }
        copyVerificationCache = copyVerificationCache.filter { liveCopyKeys.contains($0.key) }
        guard !reconciledApps.isEmpty else { return result }
        do {
            return try await store.applyReconciliation(
                expectedRevision: storeSnapshot.revision,
                appsBySkill: reconciledApps
            )
        } catch {
            SafeLog.warn("Persisting reconciled skill state failed.")
            return result
        }
    }

    private func verifiedCopyHash(at directory: URL, key: String) -> String? {
        guard let stamp = try? SkillDirectoryHasher.metadataStamp(directory: directory) else {
            copyVerificationCache[key] = nil
            return nil
        }
        if let cached = copyVerificationCache[key], cached.metadataStamp == stamp {
            return cached.contentHash
        }
        guard let hash = try? SkillDirectoryHasher.hash(directory: directory) else {
            copyVerificationCache[key] = nil
            return nil
        }
        copyVerificationCache[key] = CopyVerification(metadataStamp: stamp, contentHash: hash)
        return hash
    }

    /// Applies the native half of a pending install selection.
    ///
    /// Codex, Gemini CLI, and Grok Build discover the shared SSOT even when
    /// their app-specific projection is absent. A brand-new install must
    /// therefore write a native disable for every unchecked direct-discovery
    /// harness; selected native harnesses are explicitly returned to their
    /// enabled state. Re-installing an existing skill passes
    /// `disableUnselected: false` because that operation only adds targets and
    /// must not clear choices made earlier.
    func applyNativeInstallationSelection(
        to skill: Skill,
        selectedApps: [SkillAppTarget],
        disableUnselected: Bool
    ) throws {
        let selected = Set(selectedApps)
        for app in SkillAppTarget.managedHarnesses where app.supportsNativeSkillActivation {
            if selected.contains(app) {
                try harnessConfig.setNativeEnabled(
                    true,
                    directoryName: skill.directory,
                    skillName: skill.name,
                    app: app
                )
            } else if disableUnselected, app.discoversSharedSkillRoot {
                try harnessConfig.setNativeEnabled(
                    false,
                    directoryName: skill.directory,
                    skillName: skill.name,
                    app: app
                )
            }
        }
    }

    func validateNativeInstallationSelection(_ selectedApps: [SkillAppTarget]) throws {
        for app in selectedApps where app.supportsNativeSkillActivation {
            try harnessConfig.validateCanEnable(app)
        }
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

    /// Applies the user's explicit projection/runtime choice for one harness.
    ///
    /// Codex has two layers: the symlink/copy and `[[skills.config]]`. Other
    /// harnesses currently have only the first. The legacy `setEnabled`
    /// remains the filesystem-only API used by existing callers; the Skills
    /// page uses this richer operation so native-disabled links never read as
    /// enabled.
    @discardableResult
    public func setActivation(
        _ id: SkillID,
        app: SkillAppTarget,
        action: SkillActivationAction,
        method: SkillSyncMethod = .auto
    ) async throws -> Bool {
        guard var skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        switch action {
        case .removeProjection:
            let removed = try engine.unmaterialize(
                skillDirectoryName: skill.directory,
                from: app,
                recorded: skill.apps[app]
            )
            skill.apps[app] = nil
            try await store.upsert(skill)
            return removed

        case .enable, .disableInHarness:
            if action == .disableInHarness, !app.supportsNativeSkillActivation {
                throw SkillError.nativeActivationUnsupported(app)
            }
            // A shared-root harness without a native switch (Cursor) has
            // nothing to change on either layer: discovery comes from the
            // SSOT itself and there is no per-skill config to write. Report
            // the no-op honestly so the UI can explain it instead of
            // pretending the click landed.
            if action == .enable,
               app.discoversSharedSkillRoot,
               !app.supportsNativeSkillActivation {
                return false
            }
            let prior = skill.apps[app]
            let materialization: SkillMaterialization?
            if app.discoversSharedSkillRoot {
                // The SSOT is already a native discovery root. Creating a
                // second link is redundant and, in Gemini, surfaces as a
                // conflict warning. Native state alone controls these apps.
                materialization = prior
            } else {
                materialization = try engine.materialize(
                    skillDirectoryName: skill.directory,
                    into: app,
                    method: method,
                    recorded: prior
                )
            }
            do {
                if app.supportsNativeSkillActivation {
                    try harnessConfig.setNativeEnabled(
                        action == .enable,
                        directoryName: skill.directory,
                        skillName: skill.name,
                        app: app
                    )
                }
            } catch {
                // A newly-created projection without its matching native
                // state is misleading. Roll back only what this call created;
                // an existing projection belongs to the prior state.
                if prior == nil, let materialization {
                    _ = try? engine.unmaterialize(
                        skillDirectoryName: skill.directory,
                        from: app,
                        recorded: materialization
                    )
                }
                throw error
            }
            if let materialization { skill.apps[app] = materialization }
            try await store.upsert(skill)
            return true
        }
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
        apps: [SkillAppTarget] = SkillAppTarget.managedHarnesses
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
        try applyNativeInstallationSelection(
            to: skill,
            selectedApps: apps,
            disableUnselected: true
        )
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
        try applyNativeInstallationSelection(
            to: skill,
            selectedApps: [],
            disableUnselected: true
        )
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
