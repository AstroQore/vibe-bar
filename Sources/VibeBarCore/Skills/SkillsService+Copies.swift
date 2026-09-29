import Foundation

/// The installed list plus the harness built-ins that have no shared
/// counterpart — the two things the Skills page lists, taken from one scan.
public struct SkillsInventory: Sendable, Hashable {
    public let installed: [Skill]
    /// `.builtIn` copies whose name and directory match no installed skill,
    /// sorted by name. Built-ins that do match are in that skill's
    /// `otherCopies` instead, so nothing is listed twice.
    public let builtIns: [SkillCopy]

    public init(installed: [Skill], builtIns: [SkillCopy]) {
        self.installed = installed
        self.builtIns = builtIns
    }
}

/// Every copy of a skill on this Mac, and the two actions that act on one.
///
/// Reads come from `SkillCopyScanner`, which never writes. The only writes
/// here land in the shared library: `replaceSharedCopy` swaps the SSOT
/// directory's content for a copy's (after a backup), and `copyToShared`
/// installs a built-in through the ordinary `installLocal` path. A
/// harness's own folder is only ever the *source* of a copy.
extension SkillsService {
    public func installedSkills() async -> [Skill] {
        await inventory().installed
    }

    /// Harness built-ins with no installed counterpart.
    public func builtInSkills() async -> [SkillCopy] {
        await inventory().builtIns
    }

    /// One pass for the page's reload: the reconciled registry with copies
    /// attached, plus the standalone built-ins.
    public func inventory() async -> SkillsInventory {
        attachCopies(to: await reconciledInstalledSkills()).inventory
    }

    /// Every copy on the Mac, shared ones included, keyed by lower-cased
    /// frontmatter name (directory name when there is none). Copies attached
    /// to an installed skill carry their comparison flags and hashes; the
    /// shared copy leads its group.
    public func skillCopies() async -> [String: [SkillCopy]] {
        let (inventory, scanned) = attachCopies(to: await reconciledInstalledSkills())
        var byPath: [String: SkillCopy] = [:]
        for copy in scanned { byPath[copy.id] = copy }
        for skill in inventory.installed {
            for copy in skill.otherCopies { byPath[copy.id] = copy }
            if let shared = skill.sharedCopy ?? copyScanner.sharedCopy(directoryName: skill.directory) {
                byPath[shared.id] = shared
            }
        }
        var groups: [String: [SkillCopy]] = [:]
        for copy in byPath.values { groups[copy.groupKey, default: []].append(copy) }
        return groups.mapValues { $0.sorted(by: Self.copyOrder) }
    }

    /// Replaces the shared copy of `id` with `copy`'s content.
    ///
    /// Same shape as `update(_:)`: backup first, then the SSOT swap, then a
    /// fresh hash, then every Vibe Bar-managed `.copy` projection re-copied so
    /// harnesses that do not follow links see the new content too. Symlinked
    /// harnesses see it at once.
    ///
    /// `copy` is only trusted as a *name*: its URL must be exactly the
    /// directory the scanner would report at that location, so a stale or
    /// forged value cannot point the copy at an arbitrary path.
    @discardableResult
    public func replaceSharedCopy(_ id: SkillID, with copy: SkillCopy) async throws -> Skill {
        guard let existing = await store.skill(with: id) else { throw SkillError.notInstalled(id) }
        let source = try validatedCopySource(copy)

        try backups.createBackup(of: existing.directory, skill: existing)

        let destination = ssotDirectory(for: existing.directory)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }
        try SkillFileSystem.replaceDirectory(at: destination, withCopyOf: source)

        let frontmatter = SkillFrontmatterParser.parse(
            contentsOf: destination.appendingPathComponent("SKILL.md")
        )
        var skill = existing
        skill.name = frontmatter.name ?? existing.directory
        skill.description = frontmatter.description
        skill.contentHash = try SkillDirectoryHasher.hash(directory: destination)
        skill.updatedAt = Date()
        for (app, materialization) in existing.apps
        where app.supportsProjection && materialization.method == .copy {
            skill.apps[app] = try engine.materialize(
                skillDirectoryName: skill.directory,
                into: app,
                method: .copy,
                recorded: materialization
            )
        }
        try await store.upsert(skill)
        return skill
    }

    /// Installs a built-in (or any scanned copy) into the shared library
    /// under its own directory name, with no harness enabled — exactly what
    /// installing a local folder does.
    @discardableResult
    public func copyToShared(_ copy: SkillCopy) async throws -> Skill {
        let source = try validatedCopySource(copy)
        return try await installLocal(from: source, name: copy.directoryName)
    }

    // MARK: - Internals

    /// Full-content hashes the copy scanner has computed; lets tests prove
    /// the two-second reload does not rehash an unchanged tree.
    var copyHashComputations: Int { copyScanner.hashComputations }

    /// Scans once and attaches, to each installed skill, every copy that
    /// shares its name or its directory name.
    ///
    /// Only the attached copies — and, for those skills, the shared copy —
    /// are hashed, and the scanner caches each hash until that tree's stamp
    /// changes. Skills with no other copy cost nothing beyond the scan.
    func attachCopies(to skills: [Skill]) -> (inventory: SkillsInventory, scanned: [SkillCopy]) {
        let scanned = copyScanner.scan()
        var byKey: [String: [Int]] = [:]
        for (index, copy) in scanned.enumerated() {
            byKey[copy.groupKey, default: []].append(index)
            let directoryKey = copy.directoryName.lowercased()
            if directoryKey != copy.groupKey { byKey[directoryKey, default: []].append(index) }
        }

        var matched: Set<Int> = []
        var installed = skills
        for position in installed.indices {
            var skill = installed[position]
            let candidates = Set(
                (byKey[skill.name.lowercased()] ?? []) + (byKey[skill.directory.lowercased()] ?? [])
            )
            var others: [SkillCopy] = []
            for index in candidates.sorted() {
                let copy = scanned[index]
                // Vibe Bar's own managed copy, still byte-identical to what
                // it wrote (reconciliation drops the record otherwise), is
                // the projection the toggle already shows — not a second copy.
                if case let .appFolder(app) = copy.location,
                   copy.directoryName == skill.directory,
                   skill.apps[app]?.method == .copy {
                    matched.insert(index)
                    continue
                }
                others.append(copy)
                matched.insert(index)
            }
            guard !others.isEmpty else {
                skill.otherCopies = []
                skill.sharedCopy = nil
                installed[position] = skill
                continue
            }
            let shared = copyScanner.sharedCopy(directoryName: skill.directory)
                .map(copyScanner.withContentHash)
            let sharedHash = shared?.contentHash ?? skill.contentHash
            skill.otherCopies = others
                .map { copy in
                    var compared = copyScanner.withContentHash(copy)
                    compared.sameAsShared = sharedHash != nil && compared.contentHash == sharedHash
                    if case .appFolder = compared.location {
                        compared.shadowsShared = compared.directoryName == skill.directory
                    }
                    return compared
                }
                .sorted(by: Self.copyOrder)
            skill.sharedCopy = shared
            installed[position] = skill
        }

        let builtIns = scanned.indices
            .filter { !matched.contains($0) && scanned[$0].location.isBuiltIn }
            .map { scanned[$0] }
            .sorted(by: Self.copyOrder)
        return (SkillsInventory(installed: installed, builtIns: builtIns), scanned)
    }

    /// Re-derives the directory a copy names from the scanner's own roots
    /// and refuses anything else: the shared library itself, a path outside
    /// the roots, a symlink, or a folder without SKILL.md.
    func validatedCopySource(_ copy: SkillCopy) throws -> URL {
        guard SkillPathValidator.isValid(copy.directoryName) else {
            throw SkillError.invalidDirectoryName(copy.directoryName)
        }
        let candidate = copy.url.standardizedFileURL.path
        let match = SkillCopyScanner.roots(homeDirectory: homeDirectory)
            .filter { $0.location == copy.location }
            .map { $0.url.appendingPathComponent(copy.directoryName, isDirectory: true) }
            .first { $0.standardizedFileURL.path == candidate }
        guard let source = match else {
            throw SkillError.copyOutsideScannedRoots(copy.directoryName)
        }
        guard SkillFileSystem.kind(of: source) == .directory else {
            throw SkillError.sourceNotADirectory(copy.directoryName)
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw SkillError.missingSkillMD(copy.directoryName)
        }
        return source
    }

    /// Shared first, then harness folders, then built-ins; within each, the
    /// harness order the toggle row uses, then name, then path.
    static func copyOrder(_ lhs: SkillCopy, _ rhs: SkillCopy) -> Bool {
        let left = (rank(lhs.location), lhs.name.lowercased(), lhs.url.path)
        let right = (rank(rhs.location), rhs.name.lowercased(), rhs.url.path)
        return left < right
    }

    private static func rank(_ location: SkillCopy.Location) -> Int {
        let order = SkillAppTarget.managedHarnesses
        func index(_ app: SkillAppTarget) -> Int { order.firstIndex(of: app) ?? order.count }
        switch location {
        case .shared: return 0
        case let .appFolder(app): return 1 + index(app)
        case let .builtIn(app): return 100 + index(app)
        }
    }
}
