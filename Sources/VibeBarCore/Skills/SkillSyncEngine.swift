import Foundation

/// lstat-level classification of a path. Everything in the skills layer
/// inspects the filesystem through this instead of `fileExists`, because the
/// whole feature turns on telling a symlink apart from the directory it points
/// at — and on never following one while deleting.
enum SkillFileKind: Equatable {
    case missing
    case symlink
    case directory
    case regularFile
    case other
}

enum SkillFileSystem {
    static func kind(of url: URL) -> SkillFileKind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .missing
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeSymbolicLink: return .symlink
        case .typeDirectory: return .directory
        case .typeRegular: return .regularFile
        default: return .other
        }
    }

    /// Creates `url` and any missing ancestors up to (but never above) `root`,
    /// one component at a time. `withIntermediateDirectories: true` would do
    /// the same thing in one call, but walking the chain explicitly keeps the
    /// creation provably confined to the terminal path — AntiGravity's
    /// `~/.gemini/config/skills` is created without the code ever being in a
    /// position to touch a sibling of `config/`.
    static func ensureDirectory(_ url: URL, stopAt root: URL, permissions: Int = 0o755) throws {
        switch kind(of: url) {
        case .directory: return
        case .missing: break
        default: throw SkillError.destinationExists(url.path)
        }
        let parent = url.deletingLastPathComponent()
        guard
            SkillAppCatalog.isPath(url, under: root),
            parent.standardizedFileURL.path != url.standardizedFileURL.path
        else {
            throw SkillError.writeOutsideAllowedRoots(url.path)
        }
        try ensureDirectory(parent, stopAt: root, permissions: permissions)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    /// Recursive copy that swaps `destination` in as a unit: the tree is built
    /// in a hidden sibling first and only then renamed into place, so an
    /// interrupted copy can never leave a half-written skill where an agent
    /// CLI would read it.
    ///
    /// `destination` must be missing or a real directory — callers unlink a
    /// symlink first, since replacing through one would write to its target.
    static func replaceDirectory(at destination: URL, withCopyOf source: URL) throws {
        let fm = FileManager.default
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
            )
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        if kind(of: destination) == .missing {
            try fm.moveItem(at: staging, to: destination)
            return
        }
        do {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// Resolves a symlink's recorded target lexically — relative targets
    /// against the link's own directory, `..` collapsed in the string. It
    /// deliberately does not resolve intermediate symlinks or require the
    /// target to exist: a dangling link still reports where it meant to point.
    static func lexicalSymlinkTarget(of link: URL) -> URL? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        return URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent())
            .absoluteURL
            .standardizedFileURL
    }
}

/// Projects skills from the SSOT (`~/.agents/skills`) into each agent CLI's
/// skills directory, and takes them back out again.
///
/// Two invariants hold for every mutation:
/// 1. the skill name passed `SkillPathValidator`, and the resolved path sits
///    under `SkillAppCatalog.allowedWriteRoots`;
/// 2. deletion never follows a symlink, and never removes anything the user
///    could have authored — a foreign directory, or a copy whose content has
///    drifted from the hash recorded when Vibe Bar wrote it.
public struct SkillSyncEngine: Sendable {
    public let homeDirectory: String

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    public func sourceDirectory(for skillDirectoryName: String) -> URL {
        SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(skillDirectoryName, isDirectory: true)
    }

    public func destination(for skillDirectoryName: String, app: SkillAppTarget) -> URL {
        SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
            .appendingPathComponent(skillDirectoryName, isDirectory: true)
    }

    /// Materializes `skillDirectoryName` into `app` and reports what it did.
    ///
    /// `recorded` is the materialization already stored for this pair, if any.
    /// It only matters when `.symlink` is forced over an existing real
    /// directory: that directory is replaceable when its hash still matches
    /// the copy Vibe Bar made (recorded hash, or a byte-identical copy of the
    /// current SSOT content). Anything else is user data and throws
    /// `directoryConflict`.
    @discardableResult
    public func materialize(
        skillDirectoryName: String,
        into app: SkillAppTarget,
        method: SkillSyncMethod,
        recorded: SkillMaterialization? = nil
    ) throws -> SkillMaterialization {
        try SkillPathValidator.validate(directoryName: skillDirectoryName)
        let source = sourceDirectory(for: skillDirectoryName)
        switch SkillFileSystem.kind(of: source) {
        case .directory: break
        case .missing: throw SkillError.sourceDirectoryMissing(skillDirectoryName)
        default: throw SkillError.sourceNotADirectory(skillDirectoryName)
        }
        guard
            FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path)
        else {
            throw SkillError.missingSkillMD(skillDirectoryName)
        }

        let appDirectory = SkillAppCatalog.skillsDirectory(for: app, homeDirectory: homeDirectory)
        let destination = destination(for: skillDirectoryName, app: app)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }
        try SkillFileSystem.ensureDirectory(appDirectory, stopAt: homeURL)

        let fm = FileManager.default
        let existing = SkillFileSystem.kind(of: destination)
        switch method {
        case .auto:
            switch existing {
            case .missing:
                do {
                    return try link(source: source, destination: destination)
                } catch {
                    return try copy(source: source, destination: destination)
                }
            case .symlink:
                try fm.removeItem(at: destination)
                return try link(source: source, destination: destination)
            case .directory:
                return try copy(source: source, destination: destination)
            default:
                throw SkillError.directoryConflict(skillDirectoryName)
            }

        case .symlink:
            switch existing {
            case .missing:
                break
            case .symlink:
                try fm.removeItem(at: destination)
            case .directory:
                guard try isVibeBarCopy(destination: destination, source: source, recorded: recorded) else {
                    throw SkillError.directoryConflict(skillDirectoryName)
                }
                try fm.removeItem(at: destination)
            default:
                throw SkillError.directoryConflict(skillDirectoryName)
            }
            return try link(source: source, destination: destination)

        case .copy:
            switch existing {
            case .missing, .directory:
                break
            case .symlink:
                try fm.removeItem(at: destination)
            default:
                throw SkillError.directoryConflict(skillDirectoryName)
            }
            return try copy(source: source, destination: destination)
        }
    }

    /// Removes `skillDirectoryName` from `app`, and reports whether anything
    /// was actually removed. `false` means the entry was left alone on
    /// purpose: it is a foreign directory, a link pointing outside the SSOT,
    /// or a copy the user has since edited.
    @discardableResult
    public func unmaterialize(
        skillDirectoryName: String,
        from app: SkillAppTarget,
        recorded: SkillMaterialization?
    ) throws -> Bool {
        try SkillPathValidator.validate(directoryName: skillDirectoryName)
        let destination = destination(for: skillDirectoryName, app: app)
        guard SkillAppCatalog.isWriteAllowed(destination, homeDirectory: homeDirectory) else {
            throw SkillError.writeOutsideAllowedRoots(destination.path)
        }

        switch SkillFileSystem.kind(of: destination) {
        case .missing:
            return true
        case .symlink:
            guard
                let resolved = SkillFileSystem.lexicalSymlinkTarget(of: destination),
                SkillAppCatalog.isPath(resolved, under: SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory))
            else { return false }
            try FileManager.default.removeItem(at: destination)
            return true
        case .directory:
            guard
                recorded?.method == .copy,
                let expected = recorded?.contentHashAtCopy,
                let current = try? SkillDirectoryHasher.hash(directory: destination),
                current == expected
            else { return false }
            try FileManager.default.removeItem(at: destination)
            return true
        case .regularFile, .other:
            return false
        }
    }

    /// lstat-only inspection used by import: reports an existing symlink into
    /// the SSOT as an already-materialized skill Vibe Bar can adopt as-is. A
    /// real directory returns `nil` — it is foreign until the user says
    /// otherwise.
    public func adoptionState(skillDirectoryName: String, app: SkillAppTarget) -> SkillMaterialization? {
        guard SkillPathValidator.isValid(skillDirectoryName) else { return nil }
        let destination = destination(for: skillDirectoryName, app: app)
        guard SkillFileSystem.kind(of: destination) == .symlink else { return nil }
        guard let resolved = SkillFileSystem.lexicalSymlinkTarget(of: destination) else { return nil }
        let source = sourceDirectory(for: skillDirectoryName).standardizedFileURL
        guard resolved.path == source.path else { return nil }
        return SkillMaterialization(method: .symlink, adopted: true)
    }

    // MARK: - Internals

    var homeURL: URL { URL(fileURLWithPath: homeDirectory, isDirectory: true) }

    private func link(source: URL, destination: URL) throws -> SkillMaterialization {
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: source.standardizedFileURL
        )
        return SkillMaterialization(method: .symlink)
    }

    private func copy(source: URL, destination: URL) throws -> SkillMaterialization {
        try SkillFileSystem.replaceDirectory(at: destination, withCopyOf: source)
        let hash = try SkillDirectoryHasher.hash(directory: destination)
        return SkillMaterialization(method: .copy, contentHashAtCopy: hash)
    }

    private func isVibeBarCopy(
        destination: URL,
        source: URL,
        recorded: SkillMaterialization?
    ) throws -> Bool {
        let current = try SkillDirectoryHasher.hash(directory: destination)
        if recorded?.method == .copy, let recordedHash = recorded?.contentHashAtCopy {
            if recordedHash == current { return true }
        }
        return current == (try SkillDirectoryHasher.hash(directory: source))
    }
}
