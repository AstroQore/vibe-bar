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
    /// A content hash together with the metadata stamp it was computed
    /// under. While the stamp is unchanged the hash is reused, which is what
    /// keeps the 2-second reload at stat level.
    private struct DirectoryVerification: Sendable {
        let metadataStamp: String
        let contentHash: String
    }
    /// Keyed by the app-side copy's standardized path.
    private var copyVerificationCache: [String: DirectoryVerification] = [:]
    /// Keyed by the SSOT directory's standardized path. Separate from the copy
    /// cache so each can be evicted against its own set of live paths.
    private var ssotVerificationCache: [String: DirectoryVerification] = [:]
    /// Full content hashes computed on behalf of the reload path. Tests read it
    /// to prove an unchanged tree is not re-read; nothing else should.
    private(set) var reloadRehashCount = 0

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
            .muse: harnessConfig.museStates(for: snapshots),
            .mistralVibe: harnessConfig.mistralVibeStates(for: snapshots),
        ]
        var result: [Skill] = []
        var liveCopyKeys: Set<String> = []
        var liveSSOTKeys: Set<String> = []
        var reconciledApps: [SkillID: [SkillAppTarget: SkillMaterialization]] = [:]
        var hashBackfills: [SkillID: String] = [:]
        result.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            var reconciled = snapshot
            reconciled.localContentHash = nil
            let recordedApps = snapshot.apps
            // Edits made to the shared copy outside Vibe Bar — by hand, by
            // another installer, by an agent — only show up by comparing the
            // tree against the hash recorded when Vibe Bar last wrote it.
            // lstat first: another installer may have swapped the directory
            // for a link, and hashing through it would read a tree nobody
            // registered. A link is not a shared copy and is never hashed.
            if SkillPathValidator.isValid(snapshot.directory),
               case let ssot = ssotDirectory(for: snapshot.directory),
               SkillFileSystem.kind(of: ssot) == .directory {
                let key = ssot.standardizedFileURL.path
                liveSSOTKeys.insert(key)
                let local = verifiedHash(at: ssot, key: key, cache: &ssotVerificationCache)
                reconciled.localContentHash = local
                // A row from an older build has no recorded hash, so there is
                // no baseline to call an edit against. Today's tree becomes
                // the baseline; reporting it as modified would flag every
                // such row at once for changes nobody can name.
                if snapshot.contentHash == nil, let local {
                    reconciled.contentHash = local
                    hashBackfills[snapshot.id] = local
                }
            }
            for (app, recorded) in recordedApps {
                let currentCopyHash: String?
                if recorded.method == .copy {
                    let destination = engine.destination(for: snapshot.directory, app: app)
                    let key = destination.standardizedFileURL.path
                    liveCopyKeys.insert(key)
                    currentCopyHash = verifiedHash(at: destination, key: key, cache: &copyVerificationCache)
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
                // Native state and the live content hash are intentionally
                // transient and do not make `apps` differ. Return the
                // enriched value even when no registry reconciliation needs
                // to be persisted.
                result.append(reconciled)
                continue
            }
            reconciledApps[snapshot.id] = reconciled.apps
            result.append(reconciled)
        }
        copyVerificationCache = copyVerificationCache.filter { liveCopyKeys.contains($0.key) }
        ssotVerificationCache = ssotVerificationCache.filter { liveSSOTKeys.contains($0.key) }
        guard !reconciledApps.isEmpty || !hashBackfills.isEmpty else { return result }
        do {
            let persisted = try await store.applyReconciliation(
                expectedRevision: storeSnapshot.revision,
                appsBySkill: reconciledApps,
                contentHashBackfills: hashBackfills
            )
            return Self.carryingTransientState(from: result, onto: persisted)
        } catch {
            SafeLog.warn("Persisting reconciled skill state failed.")
            return result
        }
    }

    /// The store hands back rows as decoded, without anything derived on this
    /// pass. Dropping that for the one poll that also persisted something
    /// would blink every badge off for two seconds. Matched by directory —
    /// the registry's own key — and `isLocallyModified` is recomputed against
    /// the persisted `contentHash`, so a stale proposal the store refused
    /// still reads correctly.
    private static func carryingTransientState(from live: [Skill], onto persisted: [Skill]) -> [Skill] {
        let byDirectory = Dictionary(live.map { ($0.directory, $0) }, uniquingKeysWith: { first, _ in first })
        return persisted.map { row in
            guard let derived = byDirectory[row.directory] else { return row }
            var enriched = row
            enriched.nativeDisabledApps = derived.nativeDisabledApps
            enriched.nativeStateUnknownApps = derived.nativeStateUnknownApps
            enriched.localContentHash = derived.localContentHash
            return enriched
        }
    }

    /// Content hash of `directory`, reusing the cached one while its metadata
    /// stamp is unchanged. The stamp is taken *before* the hash, so an edit
    /// racing the hash leaves a stamp that no longer matches and is re-read
    /// on the next pass rather than cached as current.
    private func verifiedHash(
        at directory: URL,
        key: String,
        cache: inout [String: DirectoryVerification]
    ) -> String? {
        guard let stamp = try? SkillDirectoryHasher.metadataStamp(directory: directory) else {
            cache[key] = nil
            return nil
        }
        if let cached = cache[key], cached.metadataStamp == stamp {
            return cached.contentHash
        }
        reloadRehashCount += 1
        guard let hash = try? SkillDirectoryHasher.hash(directory: directory) else {
            cache[key] = nil
            return nil
        }
        cache[key] = DirectoryVerification(metadataStamp: stamp, contentHash: hash)
        return hash
    }

    /// Records the shared copy's current contents as the known state, clearing
    /// the modified badge. The user is vouching for edits made outside Vibe
    /// Bar, so this is a full re-read, never the stamp-cached hash: a
    /// same-size edit that preserved mtime and inode would otherwise be
    /// accepted as the content it replaced.
    @discardableResult
    public func acceptLocalChanges(_ id: SkillID) async throws -> Skill {
        guard var skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        try SkillPathValidator.validate(directoryName: skill.directory)
        let directory = ssotDirectory(for: skill.directory)
        // lstat, not stat: a link where the shared copy should be is not a
        // copy the user can vouch for.
        guard SkillFileSystem.kind(of: directory) == .directory else {
            throw SkillError.sourceDirectoryMissing(skill.directory)
        }
        // An edit that removed SKILL.md left a tree no harness can load;
        // recording it as the baseline would clear the warning over a broken
        // skill.
        guard SkillTreeScanner.isSkillDirectory(directory) else {
            throw SkillError.missingSkillMD(skill.directory)
        }
        // Native activation is keyed by name in several harnesses (Codex
        // compares it exactly), so any rename in the frontmatter — even a
        // change of case — is refused rather than silently carried over an
        // entry written for the old name; the description is plain display
        // text and simply follows the file.
        let frontmatter = SkillFrontmatterParser.parse(
            contentsOf: directory.appendingPathComponent("SKILL.md")
        )
        let name = frontmatter.name ?? skill.directory
        guard name == skill.name else {
            throw SkillError.directoryConflict(name)
        }
        let stamp = try SkillDirectoryHasher.metadataStamp(directory: directory)
        let hash = try SkillDirectoryHasher.hash(directory: directory)
        skill.name = name
        skill.description = frontmatter.description
        skill.contentHash = hash
        skill.updatedAt = Date()
        // A harness holding a managed *copy* would otherwise keep the old
        // content while the badge cleared: the accepted tree is what every
        // projection must now show, exactly as an update re-copies it.
        for (app, materialization) in skill.apps
        where app.supportsProjection && materialization.method == .copy {
            skill.apps[app] = try engine.materialize(
                skillDirectoryName: skill.directory,
                into: app,
                method: .copy,
                recorded: materialization
            )
        }
        try await store.upsert(skill)
        // Seeded only after the write landed, so a failed upsert cannot leave
        // the cache vouching for a baseline the registry never recorded.
        ssotVerificationCache[directory.standardizedFileURL.path] = DirectoryVerification(
            metadataStamp: stamp,
            contentHash: hash
        )
        // Transient, so set on the returned value only: the store keeps rows
        // as they would decode from disk.
        skill.localContentHash = hash
        return skill
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

    /// `source` and `directoryName` name the skill about to be copied, so a
    /// harness that matches its lists by name can refuse before the copy.
    func validateNativeInstallationSelection(
        _ selectedApps: [SkillAppTarget],
        source: URL? = nil,
        directoryName: String? = nil
    ) throws {
        let selected = Set(selectedApps)
        let skillName = source
            .flatMap { SkillFrontmatterParser.parse(contentsOf: $0.appendingPathComponent("SKILL.md")).name }
            ?? directoryName
        for app in SkillAppTarget.managedHarnesses where app.supportsNativeSkillActivation {
            if selected.contains(app) {
                try harnessConfig.validateCanEnable(app, skillName: skillName)
            } else if app.discoversSharedSkillRoot {
                // The copy into the shared root is visible to this harness at
                // once, so its disable must be possible before the copy.
                try harnessConfig.validateCanDisable(app)
            }
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
        for app in SkillAppTarget.allCases where app.supportsProjection {
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
            // Provenance can move under a directory — another installer
            // rewrote `.skill-lock.json` — and the scan then reports the same
            // directory under a new id. That is still this row: carry its
            // state forward under the new id instead of recording a twin.
            let byID = await store.skill(with: skill.id)
            let byDirectory = byID == nil ? await store.skill(directory: skill.directory) : nil
            if let existing = byID ?? byDirectory {
                // The scanned row wins on identity and metadata; the stored
                // row contributes the materializations the scan did not
                // cover and the original install time.
                var merged = skill
                merged.installedAt = existing.installedAt
                merged.apps = existing.apps
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
        guard app.supportsProjection else { throw SkillError.projectionUnsupported(app) }
        let source = SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
        guard SkillFileSystem.kind(of: source) == .directory else {
            throw SkillError.sourceNotADirectory(directoryName)
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw SkillError.missingSkillMD(directoryName)
        }
        try validateNativeInstallationSelection(apps, source: source, directoryName: directoryName)
        try copyIntoSSOT(from: source, directoryName: directoryName)

        var skill = try makeLocalSkill(directoryName: directoryName)
        for target in apps where target.supportsProjection {
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
        try validateNativeInstallationSelection([])
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
