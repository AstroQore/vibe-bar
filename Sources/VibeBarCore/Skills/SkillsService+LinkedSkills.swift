import Darwin
import Foundation

/// Linked skills: shared entries that are symlinks to folders Vibe Bar does
/// not manage (a checkout, a dotfiles repository).
///
/// Adopting one records it with a `SkillLinkReceipt` and changes nothing on
/// disk. From then on it is switched per harness like any other skill, with
/// two differences that keep the linked folder out of reach: a projection is
/// always a symlink to the shared path (never a copy of the folder), and
/// every write first checks that the link is still the one the receipt
/// pinned. The folder itself is never written, hashed, or walked — the one
/// exception is `convertLinkedSkillToCopy`, which reads it once, bounded, at
/// the user's explicit request.
extension SkillsService {
    /// Records the link at `~/.agents/skills/<directoryName>` as a managed
    /// skill. Only `skills.json` is written. Harness links that already point
    /// at the shared path are recorded as adopted projections; native
    /// switches are left exactly as they are.
    ///
    /// A row recorded before the directory became a link keeps its install
    /// time and its link projections, and takes the link's identity. A row
    /// that is already linked is re-confirmed instead.
    @discardableResult
    public func adoptLinkedSkill(directoryName: String) async throws -> Skill {
        let capture = try SkillLinkInspector.capture(directoryName: directoryName, homeDirectory: homeDirectory)
        let existing = await store.skill(directory: directoryName)
        if let existing, existing.isLinked {
            return try await reconfirmLinkedSkill(existing.id)
        }
        // A copy projection recorded for the old owned directory is not a
        // projection of the link; only links to the shared path carry over.
        // The copies themselves stay where they are — adopting writes no
        // file — and are remembered by hash, so switching that harness on
        // can replace one Vibe Bar made without treating it as a conflict.
        var apps = (existing?.apps ?? [:]).filter { $0.value.method == .symlink }
        var retired: [SkillAppTarget: String] = [:]
        for (app, materialization) in existing?.apps ?? [:] where materialization.method == .copy {
            if let hash = materialization.contentHashAtCopy { retired[app] = hash }
        }
        for app in SkillAppTarget.managedHarnesses where app.supportsProjection {
            if let evidence = engine.adoptionState(skillDirectoryName: directoryName, app: app) {
                apps[app] = evidence
                retired[app] = nil
            }
        }
        var skill = Skill(
            id: .local(directory: directoryName),
            name: capture.frontmatter.name ?? directoryName,
            description: capture.frontmatter.description,
            directory: directoryName,
            installedAt: existing?.installedAt ?? Date(),
            apps: apps,
            origin: .linked(capture.receipt)
        )
        skill.retiredCopyHashes = retired
        try await store.upsert(skill)
        skill.linkCheck = .matches
        return skill
    }

    /// Takes a new receipt for a linked skill whose link changed — or simply
    /// records the current one again. The folder must be a readable skill;
    /// nothing on disk is written.
    ///
    /// The skill's name must not change, exactly as `acceptLocalChanges`
    /// requires: Codex, Claude, Gemini CLI, Grok Build and Mistral Vibe key
    /// their per-skill switches by name, so a new name would leave the old
    /// entries behind — a skill switched off would read as on, and unlink
    /// could no longer find what to clear. A renamed skill is unlinked and
    /// adopted again instead. The description simply follows the file.
    @discardableResult
    public func reconfirmLinkedSkill(_ id: SkillID) async throws -> Skill {
        guard var skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        guard skill.isLinked else { throw SkillError.notALink(skill.directory) }
        let capture = try SkillLinkInspector.capture(directoryName: skill.directory, homeDirectory: homeDirectory)
        let name = capture.frontmatter.name ?? skill.directory
        guard name == skill.name else { throw SkillError.linkedSkillRenamed(skill.directory, name) }
        skill.origin = .linked(capture.receipt)
        skill.description = capture.frontmatter.description
        skill.updatedAt = Date()
        try await store.upsert(skill)
        skill.linkCheck = .matches
        return skill
    }

    /// Replaces the link with a copy of the folder it points at, turning the
    /// row into an ordinary owned skill. The only operation that reads the
    /// linked tree: once, through `SkillLinkConversionBudget`'s bounds, into
    /// a hidden staging directory in the shared root. The folder itself is
    /// left unchanged, and the link is swapped only if the whole receipt —
    /// target string, resolved directory, device and inode — still matches
    /// when the copy finished.
    @discardableResult
    public func convertLinkedSkillToCopy(
        _ id: SkillID,
        budget: SkillLinkConversionBudget = .standard
    ) async throws -> Skill {
        try await convertLinkedSkill(id, budget: budget, afterCopy: { _ in })
    }

    /// `afterCopy` runs right after the copy, with the staging directory,
    /// before anything about the copy or the link is checked again; tests
    /// use it to change the disk at exactly that moment.
    func convertLinkedSkill(
        _ id: SkillID,
        budget: SkillLinkConversionBudget,
        afterCopy: @Sendable (URL) throws -> Void
    ) async throws -> Skill {
        guard var skill = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        guard let receipt = skill.linkReceipt else { throw SkillError.notALink(skill.directory) }
        try SkillPathValidator.validate(directoryName: skill.directory)
        guard SkillLinkInspector.check(receipt, directoryName: skill.directory, homeDirectory: homeDirectory) == .matches else {
            throw SkillError.linkReceiptMismatch(skill.directory)
        }
        let source = receipt.resolvedURL
        try budget.check(source, directoryName: skill.directory)

        let shared = ssotDirectory(for: skill.directory)
        guard SkillAppCatalog.isWriteAllowed(shared, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(shared.path)
        }
        let fm = FileManager.default
        let staging = shared.deletingLastPathComponent().appendingPathComponent(
            ".\(skill.directory).convert-\(getpid())-\(UInt32.random(in: 0...UInt32.max))",
            isDirectory: true
        )
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        try afterCopy(staging)
        // The preflight bounded the folder as it was before the copy; files
        // added or grown while it ran would still land. What is actually
        // about to be installed is held to the same budget.
        try budget.check(staging, directoryName: skill.directory)
        guard SkillTreeScanner.isSkillDirectory(staging) else { throw SkillError.missingSkillMD(skill.directory) }
        // The same rule as re-confirming: the copy keeps the name the native
        // switches were written for, or the link stays as it is.
        let frontmatter = SkillFrontmatterParser.parse(contentsOf: staging.appendingPathComponent("SKILL.md"))
        let copiedName = frontmatter.name ?? skill.directory
        guard copiedName == skill.name else { throw SkillError.linkedSkillRenamed(skill.directory, copiedName) }

        // The copy took time. The link must still be the one the receipt
        // pins, and still lead to the same directory: a folder deleted and
        // re-created at the same path keeps the target string but not the
        // inode, and its content is not what the user confirmed. Checked in
        // full here, immediately before the link goes; `removeLink` then
        // re-checks the target string itself.
        guard SkillLinkInspector.check(receipt, directoryName: skill.directory, homeDirectory: homeDirectory) == .matches else {
            throw SkillError.linkReceiptMismatch(skill.directory)
        }
        try SkillLinkInspector.removeLink(directoryName: skill.directory, receipt: receipt, homeDirectory: homeDirectory)
        do {
            try fm.moveItem(at: staging, to: shared)
        } catch {
            // Put the link back rather than leave the skill missing.
            try? fm.createSymbolicLink(atPath: shared.path, withDestinationPath: receipt.target)
            throw error
        }

        skill.origin = .owned
        skill.linkCheck = nil
        skill.description = frontmatter.description
        skill.contentHash = try SkillDirectoryHasher.hash(directory: shared)
        skill.updatedAt = Date()
        // Harness links already point at the shared path, which is now the
        // copy; there are no copy projections of a linked skill to redo.
        // Copies retired at adoption are owned-row copies again.
        skill.apps = skill.apps.filter { $0.value.method == .symlink }
        for (app, hash) in skill.retiredCopyHashes where skill.apps[app] == nil {
            skill.apps[app] = SkillMaterialization(method: .copy, contentHashAtCopy: hash)
        }
        skill.retiredCopyHashes = [:]
        try await store.upsert(skill)
        skill.localContentHash = skill.contentHash
        return skill
    }

    /// `uninstall` for a linked skill. Backs up the link (its target string,
    /// not the folder), removes every Vibe Bar projection of it, returns its
    /// native switches to their default, removes the link itself, and
    /// forgets the row. Refused while the shared entry is anything other
    /// than the recorded link or nothing at all — a re-pointed link is the
    /// user's, until they re-confirm it.
    func unlinkLinkedSkill(_ skill: Skill, receipt: SkillLinkReceipt) async throws -> UninstallResult {
        try SkillPathValidator.validate(directoryName: skill.directory)
        let check = SkillLinkInspector.check(receipt, directoryName: skill.directory, homeDirectory: homeDirectory)
        if let reason = check.mismatch, !reason.linkStillRecorded {
            throw SkillError.linkReceiptMismatch(skill.directory)
        }
        let backupURL = try backups.createBackup(of: skill.directory, skill: skill)
        var removedByApp: [SkillAppTarget: Bool] = [:]
        for app in SkillAppTarget.allCases where app.supportsProjection {
            // A copy retired at adoption goes too, while it is unchanged.
            removedByApp[app] = try engine.unmaterialize(
                skillDirectoryName: skill.directory,
                from: app,
                recorded: skill.apps[app] ?? retiredCopy(of: skill, in: app)
            )
        }
        let retainedNative = await restoreNativeDefaults(for: skill)
        try SkillLinkInspector.removeLink(directoryName: skill.directory, receipt: receipt, homeDirectory: homeDirectory)
        try await store.remove(id: skill.id)
        return UninstallResult(backupURL: backupURL, removedByApp: removedByApp, retainedNativeApps: retainedNative)
    }

    /// Clears every native per-skill disable this skill has, so nothing the
    /// harness configs say about it outlives the link. Returns the harnesses
    /// left as they were: an unreadable or refused config, or a name-keyed
    /// switch (Claude, Gemini CLI, Grok Build, Mistral Vibe, and Codex's
    /// name blocks) that another skill on this Mac also answers to — clearing
    /// it would switch that one back on. Muse keys by path and is always
    /// cleared.
    private func restoreNativeDefaults(for skill: Skill) async -> [SkillAppTarget] {
        let rows = [skill]
        let states: [SkillAppTarget: SkillHarnessConfigManager.NativeState] = [
            .codex: harnessConfig.codexStates(for: rows)[skill.directory] ?? .unknown,
            .claude: harnessConfig.claudeStates(for: rows)[skill.directory] ?? .unknown,
            .gemini: harnessConfig.geminiStates(for: rows)[skill.directory] ?? .unknown,
            .grok: harnessConfig.grokStates(for: rows)[skill.directory] ?? .unknown,
            .muse: harnessConfig.museStates(for: rows)[skill.directory] ?? .unknown,
            .mistralVibe: harnessConfig.mistralVibeStates(for: rows)[skill.directory] ?? .unknown,
        ]
        let disabled = SkillAppTarget.managedHarnesses.filter {
            $0.supportsNativeSkillActivation && states[$0] != .enabled
        }
        guard !disabled.isEmpty else { return [] }
        let nameIsShared = await anotherSkillAnswers(to: skill.name, besides: skill.directory)
        var retained: [SkillAppTarget] = []
        for app in disabled {
            guard states[app] == .disabled, app == .muse || !nameIsShared else {
                retained.append(app)
                continue
            }
            do {
                try harnessConfig.setNativeEnabled(
                    true,
                    directoryName: skill.directory,
                    skillName: skill.name,
                    app: app
                )
            } catch {
                retained.append(app)
            }
        }
        return retained
    }

    /// Whether any other skill this Mac exposes — another registry row, a
    /// shared entry, a harness folder copy, or a built-in — has `name`.
    /// Scanned with fresh scanners so the reload's caches are not disturbed.
    private func anotherSkillAnswers(to name: String, besides directory: String) async -> Bool {
        let key = name.lowercased()
        if await store.all().contains(where: { $0.directory != directory && $0.name.lowercased() == key }) {
            return true
        }
        let shared = SharedSkillDiscoveryScanner(homeDirectory: homeDirectory)
            .scan(excludingDirectories: [directory])
        if shared.contains(where: { $0.name.lowercased() == key }) { return true }
        return SkillCopyScanner(homeDirectory: homeDirectory).scan().contains { $0.groupKey == key }
    }
}

/// The bounds a linked folder has to fit before it is copied into the shared
/// root — the same budget an archive install is held to, walked at lstat
/// level (links inside are counted and copied as links, never followed).
public struct SkillLinkConversionBudget: Sendable, Hashable {
    public var maxEntries: Int
    public var maxBytes: Int64
    public var maxDepth: Int

    public init(
        maxEntries: Int = SkillArchiveExtractor.maxEntries,
        maxBytes: Int64 = SkillArchiveExtractor.maxExtractedBytes,
        maxDepth: Int = 32
    ) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
    }

    public static let standard = SkillLinkConversionBudget()

    /// Every entry counts, hidden ones included: the copy takes them all.
    func check(_ root: URL, directoryName: String) throws {
        let fm = FileManager.default
        var entries = 0
        var bytes: Int64 = 0
        func walk(_ directory: URL, depth: Int) throws {
            guard depth <= maxDepth else { throw SkillError.copyLimitExceeded(directoryName) }
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw SkillError.linkedSourceUnavailable(directoryName)
            }
            for name in names {
                entries += 1
                guard entries <= maxEntries else { throw SkillError.copyLimitExceeded(directoryName) }
                let child = directory.appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: child.path) else {
                    throw SkillError.linkedSourceUnavailable(directoryName)
                }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    try walk(child, depth: depth + 1)
                case .typeRegular:
                    bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard bytes <= maxBytes else { throw SkillError.copyLimitExceeded(directoryName) }
                case .typeSymbolicLink:
                    continue
                default:
                    // Sockets, pipes, devices: not skill content, and not
                    // something a copy should try to reproduce.
                    throw SkillError.linkedSourceUnavailable(directoryName)
                }
            }
        }
        try walk(root, depth: 0)
    }
}
