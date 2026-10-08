import Darwin
import Foundation

/// A live, read-only entry in the shared root. Discovery never registers a
/// skill or grants ownership of a linked directory to Vibe Bar: adopting a
/// link (`SkillsService.adoptLinkedSkill`) is a separate, explicit action.
public struct SharedSkillDiscovery: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case ready, brokenLink, cyclicLink, missingSkillFile, unreadable, tooLarge
        /// Nothing is on disk at the shared path. Only a linked registry row
        /// whose link was removed is listed this way, so it can be unlinked.
        case missing
    }
    public enum Availability: Hashable, Sendable { case available, disabled, unknown }

    /// What `skills.json` says about this entry.
    public enum Registration: Hashable, Sendable {
        /// No registry row names this directory.
        case unregistered
        /// A row recorded before this directory became a link. It grants no
        /// ownership of whatever the link now points at.
        case ownedRecord(SkillID)
        /// An adopted link whose receipt no longer matches what is on disk.
        /// Every write waits until the user re-confirms or unlinks it.
        case receiptMismatch(SkillID, SkillLinkMismatch)
    }

    public let directoryName: String
    public let name: String
    public let description: String?
    public let logicalURL: URL
    public let resolvedURL: URL?
    public let isSymlink: Bool
    public let state: State
    /// Raw `readlink` string when the entry is a symlink.
    public let linkTarget: String?
    public internal(set) var agents: [SkillAppTarget: Availability] = [:]
    public internal(set) var projectedTo: Set<SkillAppTarget> = []
    public internal(set) var registration: Registration = .unregistered
    public var id: String { logicalURL.path }

    /// The registry row this entry belongs to, when there is one.
    public var registeredID: SkillID? {
        switch registration {
        case .unregistered: nil
        case let .ownedRecord(id), let .receiptMismatch(id, _): id
        }
    }

    /// A ready link nobody adopted yet, or one an old owned row still names.
    public var canAdoptLink: Bool {
        guard isSymlink, state == .ready else { return false }
        switch registration {
        case .unregistered, .ownedRecord: return true
        case .receiptMismatch: return false
        }
    }

    /// A changed link that is readable again and can be recorded anew.
    public var canReconfirmLink: Bool {
        guard isSymlink, state == .ready, case .receiptMismatch = registration else { return false }
        return true
    }

    /// The entry is still the link the receipt recorded, or is gone, so
    /// unlinking removes only what the user adopted.
    public var canUnlink: Bool {
        guard case let .receiptMismatch(_, reason) = registration else { return false }
        return reason.linkStillRecorded
    }
}

public enum SharedSkillReadError: Error {
    case invalidDirectory, changedSource, unavailable(SharedSkillDiscovery.State)
}

/// Owned by SkillsService's actor. Only the declared shared entries and
/// their SKILL.md metadata are read; linked trees are never recursively
/// hashed, copied, updated, or removed by this scanner.
final class SharedSkillDiscoveryScanner {
    static let maximumPreviewBytes = 256 * 1024
    static let frontmatterBytes = 16 * 1024

    /// Where a shared entry leads: followed one link at a time (at most 40,
    /// cycles refused), ending on a directory whose `SKILL.md` is a regular
    /// file inside it and within the preview limit.
    struct Resolution {
        let state: SharedSkillDiscovery.State
        let resolvedURL: URL?
        /// The canonical `SKILL.md` and its size/mtime/inode stamp, for
        /// `.ready` only.
        let skillFile: URL?
        let skillFileStamp: String?
    }

    private let homeDirectory: String
    private var metadata: [String: (stamp: String, value: SkillFrontmatterParser.Frontmatter)] = [:]

    init(homeDirectory: String) { self.homeDirectory = homeDirectory }

    func scan(excludingDirectories: Set<String>) -> [SharedSkillDiscovery] {
        let root = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let excluded = Set(excludingDirectories.map { $0.lowercased() })
        let result = names.sorted().compactMap { name -> SharedSkillDiscovery? in
            guard !name.hasPrefix("."), SkillPathValidator.isValid(name), !excluded.contains(name.lowercased()) else { return nil }
            let kind = SkillFileSystem.kind(of: root.appendingPathComponent(name))
            guard kind == .directory || kind == .symlink else { return nil }
            return entry(name: name)
        }
        let live = Set(result.map(\.id))
        metadata = metadata.filter { live.contains($0.key) }
        return result
    }

    func preview(_ snapshot: SharedSkillDiscovery) throws -> String {
        guard SkillPathValidator.isValid(snapshot.directoryName),
              snapshot.logicalURL.standardizedFileURL == SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
                .appendingPathComponent(snapshot.directoryName).standardizedFileURL else {
            throw SharedSkillReadError.invalidDirectory
        }
        let current = entry(name: snapshot.directoryName)
        guard current.state == .ready, let resolved = current.resolvedURL else {
            throw SharedSkillReadError.unavailable(current.state)
        }
        guard resolved == snapshot.resolvedURL else { throw SharedSkillReadError.changedSource }
        let data = try Self.boundedRead(resolved.appendingPathComponent("SKILL.md"), limit: Self.maximumPreviewBytes)
        return String(decoding: data, as: UTF8.self)
    }

    /// The row listed for a linked registry entry whose link is gone: there
    /// is nothing on disk to scan, but the row still needs a way out.
    func missingEntry(for skill: Skill) -> SharedSkillDiscovery {
        var entry = SharedSkillDiscovery(
            directoryName: skill.directory,
            name: skill.name,
            description: skill.description,
            logicalURL: SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
                .appendingPathComponent(skill.directory),
            resolvedURL: skill.linkReceipt?.resolvedURL,
            isSymlink: true,
            state: .missing,
            linkTarget: skill.linkReceipt?.target
        )
        entry.registration = .receiptMismatch(skill.id, .missing)
        return entry
    }

    private func entry(name: String) -> SharedSkillDiscovery {
        let logical = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory).appendingPathComponent(name)
        let linked = SkillFileSystem.kind(of: logical) == .symlink
        let target = linked ? (try? FileManager.default.destinationOfSymbolicLink(atPath: logical.path)) : nil
        let resolution = Self.resolve(logical)
        var frontmatter = SkillFrontmatterParser.Frontmatter.empty
        var state = resolution.state
        if state == .ready, let skillFile = resolution.skillFile, let stamp = resolution.skillFileStamp {
            if let cached = metadata[logical.path], cached.stamp == stamp {
                frontmatter = cached.value
            } else if let parsed = Self.frontmatter(of: skillFile) {
                frontmatter = parsed
                metadata[logical.path] = (stamp, parsed)
            } else {
                state = .unreadable
            }
        }
        return SharedSkillDiscovery(
            directoryName: name, name: frontmatter.name ?? name, description: frontmatter.description,
            logicalURL: logical, resolvedURL: resolution.resolvedURL, isSymlink: linked, state: state,
            linkTarget: target
        )
    }

    /// Follows `logical` the way discovery always has, without reading
    /// anything but link targets and the metadata of one `SKILL.md`.
    static func resolve(_ logical: URL) -> Resolution {
        let linked = SkillFileSystem.kind(of: logical) == .symlink
        func result(_ state: SharedSkillDiscovery.State, resolved: URL? = nil,
                    skillFile: URL? = nil, stamp: String? = nil) -> Resolution {
            Resolution(state: state, resolvedURL: resolved, skillFile: skillFile, skillFileStamp: stamp)
        }
        var cursor = logical.standardizedFileURL
        var seen: Set<String> = []
        for _ in 0..<40 {
            guard seen.insert(cursor.path).inserted else { return result(.cyclicLink) }
            switch SkillFileSystem.kind(of: cursor) {
            case .symlink:
                guard let next = SkillFileSystem.lexicalSymlinkTarget(of: cursor) else { return result(.unreadable) }
                cursor = next
            case .directory:
                let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
                let skillFile = resolved.appendingPathComponent("SKILL.md")
                let canonicalFile = skillFile.resolvingSymlinksInPath().standardizedFileURL
                guard SkillAppCatalog.isPath(canonicalFile, under: resolved) else { return result(.unreadable, resolved: resolved) }
                guard SkillFileSystem.kind(of: canonicalFile) == .regularFile else { return result(.missingSkillFile, resolved: resolved) }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalFile.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue else { return result(.unreadable, resolved: resolved) }
                guard size <= maximumPreviewBytes else { return result(.tooLarge, resolved: resolved) }
                let stamp = "\(resolved.path):\(size):\(attributes[.modificationDate] ?? ""): \(attributes[.systemFileNumber] ?? "")"
                return result(.ready, resolved: resolved, skillFile: canonicalFile, stamp: stamp)
            case .missing: return result(linked ? .brokenLink : .unreadable)
            default: return result(.missingSkillFile)
            }
        }
        return result(.unreadable)
    }

    /// The first 16 KB of one `SKILL.md`, parsed; `nil` when unreadable.
    static func frontmatter(of skillFile: URL) -> SkillFrontmatterParser.Frontmatter? {
        guard let data = try? boundedRead(skillFile, limit: frontmatterBytes, allowTruncation: true) else { return nil }
        return SkillFrontmatterParser.parse(String(decoding: data, as: UTF8.self))
    }

    private static func boundedRead(_ url: URL, limit: Int, allowTruncation: Bool = false) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if data.count > limit, !allowTruncation { throw SharedSkillReadError.unavailable(.tooLarge) }
        return data.prefix(limit)
    }
}

/// Takes and checks the receipts of adopted links (`SkillLinkReceipt`).
///
/// Every call is a read of the link itself, its target chain, the resolved
/// directory's own metadata, and one `SKILL.md`'s metadata — never the
/// linked tree. Nothing here writes.
enum SkillLinkInspector {
    /// The receipt and frontmatter of the link at `~/.agents/skills/<name>`.
    struct Capture {
        let receipt: SkillLinkReceipt
        let frontmatter: SkillFrontmatterParser.Frontmatter
    }

    static func logicalURL(directoryName: String, homeDirectory: String) -> URL {
        SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func capture(directoryName: String, homeDirectory: String, at date: Date = Date()) throws -> Capture {
        try SkillPathValidator.validate(directoryName: directoryName)
        let logical = logicalURL(directoryName: directoryName, homeDirectory: homeDirectory)
        guard SkillFileSystem.kind(of: logical) == .symlink,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: logical.path)
        else { throw SkillError.notALink(directoryName) }
        let resolution = SharedSkillDiscoveryScanner.resolve(logical)
        guard resolution.state == .ready, let resolved = resolution.resolvedURL, let skillFile = resolution.skillFile,
              let identity = directoryIdentity(resolved),
              let frontmatter = SharedSkillDiscoveryScanner.frontmatter(of: skillFile)
        else { throw SkillError.linkedSourceUnavailable(directoryName) }
        // A link to an ancestor of the shared root would make "the linked
        // folder" contain every skill Vibe Bar manages, the link included.
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let canonicalSSOT = ssot.resolvingSymlinksInPath().standardizedFileURL
        guard !SkillAppCatalog.isPath(ssot, under: resolved),
              !SkillAppCatalog.isPath(canonicalSSOT, under: resolved)
        else { throw SkillError.linkTargetUnsupported(directoryName) }
        return Capture(
            receipt: SkillLinkReceipt(
                target: target,
                resolvedPath: resolved.path,
                device: identity.device,
                inode: identity.inode,
                confirmedAt: date
            ),
            frontmatter: frontmatter
        )
    }

    /// Whether the link at the shared path is still the one `receipt` pins.
    static func check(_ receipt: SkillLinkReceipt, directoryName: String, homeDirectory: String) -> SkillLinkCheck {
        guard SkillPathValidator.isValid(directoryName) else { return .mismatch(.unavailable) }
        let logical = logicalURL(directoryName: directoryName, homeDirectory: homeDirectory)
        switch SkillFileSystem.kind(of: logical) {
        case .missing: return .mismatch(.missing)
        case .symlink: break
        case .directory, .regularFile, .other: return .mismatch(.notALink)
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: logical.path) else {
            return .mismatch(.unavailable)
        }
        guard target == receipt.target else { return .mismatch(.retargeted) }
        let resolution = SharedSkillDiscoveryScanner.resolve(logical)
        guard resolution.state == .ready, let resolved = resolution.resolvedURL else { return .mismatch(.unavailable) }
        guard resolved.path == receipt.resolvedPath else { return .mismatch(.resolvesElsewhere) }
        guard let identity = directoryIdentity(resolved),
              identity.device == receipt.device, identity.inode == receipt.inode
        else { return .mismatch(.replaced) }
        return .matches
    }

    /// The raw target string of the link at the shared path, when it is one.
    static func currentTarget(directoryName: String, homeDirectory: String) -> String? {
        let logical = logicalURL(directoryName: directoryName, homeDirectory: homeDirectory)
        guard SkillFileSystem.kind(of: logical) == .symlink else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: logical.path)
    }

    /// Removes the link at the shared path, and only when it is still the
    /// link `receipt` recorded. `unlink(2)` removes a symlink itself and
    /// refuses a directory, so this can never reach the linked folder.
    static func removeLink(directoryName: String, receipt: SkillLinkReceipt, homeDirectory: String) throws {
        try SkillPathValidator.validate(directoryName: directoryName)
        let ssot = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let logical = logicalURL(directoryName: directoryName, homeDirectory: homeDirectory)
        guard SkillAppCatalog.isPath(logical, under: ssot),
              SkillAppCatalog.isWriteAllowed(logical, homeDirectory: homeDirectory)
        else { throw SkillError.writeOutsideAllowedRoots(logical.path) }
        switch SkillFileSystem.kind(of: logical) {
        case .missing:
            return
        case .symlink:
            guard currentTarget(directoryName: directoryName, homeDirectory: homeDirectory) == receipt.target else {
                throw SkillError.linkReceiptMismatch(directoryName)
            }
            guard Darwin.unlink(logical.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logical.path])
            }
        case .directory, .regularFile, .other:
            throw SkillError.linkReceiptMismatch(directoryName)
        }
    }

    private static func directoryIdentity(_ url: URL) -> (device: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return (device, inode)
    }
}
