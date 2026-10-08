import Foundation

/// Stable identity of a skill.
///
/// A skill is identified by where it came from plus the directory name it
/// occupies in the SSOT (`~/.agents/skills/<directory>`). The directory name
/// is part of the identity because it is what every app-side materialization
/// is keyed on — two skills cannot share a directory.
///
/// Serialized form:
/// - `owner/repo:directory` for a GitHub-backed skill
/// - `local:directory` for a hand-installed or adopted one
///
/// Parsing splits on the *first* colon, so a directory name may itself contain
/// a colon and still round-trips. `local` always wins over a GitHub owner
/// literally named `local`, which cannot exist as a repo slug anyway (a slug
/// requires a `/`).
public enum SkillID: RawRepresentable, Hashable, Sendable, Codable {
    case repo(owner: String, repo: String, directory: String)
    case local(directory: String)

    public static let localSource = "local"

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":") else { return nil }
        let source = String(rawValue[rawValue.startIndex..<separator])
        let directory = String(rawValue[rawValue.index(after: separator)...])
        guard !directory.isEmpty else { return nil }
        if source == Self.localSource {
            self = .local(directory: directory)
            return
        }
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self = .repo(owner: String(parts[0]), repo: String(parts[1]), directory: directory)
    }

    public var rawValue: String {
        switch self {
        case let .repo(owner, repo, directory):
            return "\(owner)/\(repo):\(directory)"
        case let .local(directory):
            return "\(Self.localSource):\(directory)"
        }
    }

    /// SSOT directory name this identity occupies.
    public var directory: String {
        switch self {
        case let .repo(_, _, directory): return directory
        case let .local(directory): return directory
        }
    }

    /// `owner/repo` for GitHub-backed skills, `nil` for local ones.
    public var repositorySlug: String? {
        switch self {
        case let .repo(owner, repo, _): return "\(owner)/\(repo)"
        case .local: return nil
        }
    }

    public var isRepositoryBacked: Bool { repositorySlug != nil }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = SkillID(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unrecognized skill id"
                )
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One agent CLI that can consume skills. The raw values are the persisted
/// keys in `skills.json`, so renaming one is a schema change.
public enum SkillAppTarget: String, CaseIterable, Codable, Hashable, Sendable {
    case claude
    case codex
    case gemini
    case grok
    case hermes
    case opencode
    case antigravity
    case cursor
    case muse
    case mistralVibe

    /// Harnesses Vibe Bar can actually project a local skill directory into.
    ///
    /// ChatGPT Work, Claude Cowork, and Grok Bot do not expose an independent,
    /// stable local skills root that this filesystem feature can safely write.
    /// They therefore stay out of the toggle row instead of pretending a link
    /// can enable them. Hermes and OpenCode remain decodable for old
    /// `skills.json` files and safe uninstall cleanup; the managed core
    /// harnesses are listed below. Muse Code is managed without a projection
    /// — see `supportsProjection`.
    public static let managedHarnesses: [SkillAppTarget] = [
        .codex,
        .claude,
        .gemini,
        .antigravity,
        .grok,
        .cursor,
        .muse,
        .mistralVibe,
    ]

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok Build"
        case .hermes: return "Hermes"
        case .opencode: return "OpenCode"
        case .antigravity: return "AntiGravity"
        case .cursor: return "Cursor"
        case .muse: return "Muse Code"
        case .mistralVibe: return "Mistral Vibe"
        }
    }

    /// Whether Vibe Bar may create a link or copy in this harness's own skills
    /// directory.
    ///
    /// Muse Code may not. Its `~/.config/muse/skills` belongs to
    /// `muse skills install`, and Muse keys a skill's on/off switch by the
    /// path it was discovered at: a second copy there would be a different
    /// skill to Muse, silently escaping the switch the user set on the
    /// `~/.agents/skills` one Muse already reads.
    ///
    /// Mistral Vibe may not either: it reads `~/.agents/skills` itself, and
    /// its own `~/.vibe/skills` is the user's.
    public var supportsProjection: Bool {
        self != .muse && self != .mistralVibe
    }

    /// Whether the harness has a real per-skill runtime switch in addition to
    /// its filesystem discovery root.
    public var supportsNativeSkillActivation: Bool {
        switch self {
        case .codex, .claude, .gemini, .grok, .muse, .mistralVibe: true
        case .hermes, .opencode, .antigravity, .cursor: false
        }
    }

    /// Harnesses that discover the shared `~/.agents/skills` root directly.
    public var discoversSharedSkillRoot: Bool {
        switch self {
        case .codex, .gemini, .grok, .cursor, .muse, .mistralVibe: true
        case .claude, .hermes, .opencode, .antigravity: false
        }
    }

    /// Home-relative path of the file holding the harness's per-skill switch,
    /// `nil` when the harness has none. Display metadata for the wiring UI —
    /// the file is only ever read or patched through
    /// `SkillHarnessConfigManager`.
    public var nativeConfigRelativePath: String? {
        switch self {
        case .codex: ".codex/config.toml"
        case .claude: ".claude/settings.json"
        case .gemini: ".gemini/settings.json"
        case .grok: ".grok/config.toml"
        case .muse: ".config/muse/settings.json"
        case .mistralVibe: ".vibe/config.toml"
        case .hermes, .opencode, .antigravity, .cursor: nil
        }
    }

    /// The key inside that file, in the harness's own vocabulary.
    public var nativeConfigKeyDescription: String? {
        switch self {
        case .codex: "[[skills.config]]"
        case .claude: "skillOverrides"
        case .gemini: "skills.disabled"
        case .grok: "[skills] disabled"
        case .muse: "skills.activation.user"
        case .mistralVibe: "disabled_skills"
        case .hermes, .opencode, .antigravity, .cursor: nil
        }
    }
}

/// Effective state of one skill in one harness.
public enum SkillActivationState: String, Hashable, Sendable {
    case notProjected
    case enabled
    case disabledInHarness
    /// Still discovered through the shared or a compatibility root after the
    /// harness-specific projection is removed.
    case coupled
    case unknown
}

/// Explicit user choices shown by the Skills manager.
public enum SkillActivationAction: Hashable, Sendable {
    case enable
    case disableInHarness
    case removeProjection
}

/// How a skill should be projected from the SSOT into an app's skills dir.
///
/// `auto` is a *request*, never a recorded outcome: the sync engine resolves
/// it against what is already on disk and records the concrete method.
public enum SkillSyncMethod: String, CaseIterable, Codable, Hashable, Sendable {
    case auto
    case symlink
    case copy
}

/// What the sync engine actually did for one (skill, app) pair.
public struct SkillMaterialization: Codable, Hashable, Sendable {
    /// Always `.symlink` or `.copy` — `.auto` is resolved before recording.
    public let method: SkillSyncMethod
    /// True when the entry was already on disk (created by another tool) and
    /// Vibe Bar merely recognized it during import.
    public let adopted: Bool
    /// Directory hash captured right after a copy. `unmaterialize` refuses to
    /// delete a copy whose hash has since changed, so user edits survive.
    public let contentHashAtCopy: String?

    public init(method: SkillSyncMethod, adopted: Bool = false, contentHashAtCopy: String? = nil) {
        self.method = method == .auto ? .copy : method
        self.adopted = adopted
        self.contentHashAtCopy = contentHashAtCopy
    }
}

/// What Vibe Bar recorded about a shared skill that is a symlink to a folder
/// outside its management (a checkout, a dotfiles repository).
///
/// The receipt pins *which* link was adopted, not what the folder holds: the
/// link's own target string, the directory it resolved to, and that
/// directory's device and inode. A link re-pointed by hand, an intermediate
/// link that moved, or a folder deleted and re-created at the same path all
/// stop matching, and every write waits for the user to re-confirm. Edits
/// inside the folder do not — the link is a live view of it, and Vibe Bar
/// never hashes, copies, or writes that tree to find out what changed.
public struct SkillLinkReceipt: Codable, Hashable, Sendable {
    /// Raw `readlink` string of `~/.agents/skills/<directory>`.
    public let target: String
    /// Standardized directory the link resolved to when it was confirmed.
    public let resolvedPath: String
    public let device: UInt64
    public let inode: UInt64
    public let confirmedAt: Date

    public init(target: String, resolvedPath: String, device: UInt64, inode: UInt64, confirmedAt: Date) {
        self.target = target
        self.resolvedPath = resolvedPath
        self.device = device
        self.inode = inode
        self.confirmedAt = confirmedAt
    }

    public var resolvedURL: URL { URL(fileURLWithPath: resolvedPath, isDirectory: true) }

    /// Same link and same source directory; when it was confirmed is
    /// bookkeeping, not identity.
    public func pinsSameSource(as other: SkillLinkReceipt) -> Bool {
        target == other.target && resolvedPath == other.resolvedPath
            && device == other.device && inode == other.inode
    }
}

/// Where a registered skill's shared entry comes from.
public enum SkillOrigin: Hashable, Sendable {
    /// `~/.agents/skills/<directory>` is a real directory Vibe Bar wrote,
    /// imported, or adopted.
    case owned
    /// `~/.agents/skills/<directory>` is a link the user made to a folder
    /// Vibe Bar does not manage. Only the link itself is Vibe Bar's to touch.
    case linked(SkillLinkReceipt)
}

/// Why a linked skill's receipt no longer matches the shared entry.
public enum SkillLinkMismatch: String, Hashable, Sendable {
    /// Nothing is at `~/.agents/skills/<directory>` any more.
    case missing
    /// The link was replaced by a real directory or a file.
    case notALink
    /// The link's own target string changed.
    case retargeted
    /// Same target string, but it now resolves to another directory.
    case resolvesElsewhere
    /// Same path, but a different directory (deleted and re-created).
    case replaced
    /// The link is broken, cyclic, or leads to something that is not a
    /// readable skill.
    case unavailable

    /// Whether the entry at the shared path is still the link the receipt
    /// recorded (or nothing at all), so removing it removes exactly what the
    /// user adopted.
    public var linkStillRecorded: Bool {
        switch self {
        case .missing, .resolvesElsewhere, .replaced, .unavailable: true
        case .notALink, .retargeted: false
        }
    }
}

/// Live verification of a linked skill's receipt.
public enum SkillLinkCheck: Hashable, Sendable {
    case matches
    case mismatch(SkillLinkMismatch)

    public var matches: Bool { self == .matches }

    public var mismatch: SkillLinkMismatch? {
        if case let .mismatch(reason) = self { return reason }
        return nil
    }
}

/// A skill installed in the SSOT (`~/.agents/skills/<directory>`), plus the
/// per-app materializations Vibe Bar knows about.
public struct Skill: Codable, Hashable, Sendable, Identifiable {
    public var id: SkillID
    /// `name:` from SKILL.md frontmatter, falling back to the directory name.
    public var name: String
    public var description: String?
    /// SSOT directory name. Kept alongside `id` because every filesystem
    /// operation keys on it and `id` is opaque to call sites.
    public var directory: String
    public var repoBranch: String?
    public var installedAt: Date
    public var contentHash: String?
    public var updatedAt: Date?
    public var apps: [SkillAppTarget: SkillMaterialization]
    /// Owned directory or adopted external link. Persisted as the optional
    /// `link` key, so a file written before links could be adopted decodes
    /// every row as `.owned`.
    public var origin: SkillOrigin
    /// Live verification of a linked row's receipt, derived on reload and
    /// omitted from `skills.json`. `nil` for owned rows.
    public var linkCheck: SkillLinkCheck?
    /// Linked rows only: harness copies Vibe Bar made for the owned row this
    /// one replaced, by the content hash recorded when it wrote them. They
    /// are not projections of the link — a linked row records links only —
    /// but they are still Vibe Bar's, so switching that harness on (or
    /// unlinking) may remove one while it still hashes to this value. An
    /// edited copy is the user's and stays a conflict. Persisted as the
    /// optional `retiredCopies` key.
    public var retiredCopyHashes: [SkillAppTarget: String] = [:]
    /// Live native-harness state, derived on reload and omitted from
    /// `skills.json`.
    public var nativeDisabledApps: Set<SkillAppTarget>
    public var nativeStateUnknownApps: Set<SkillAppTarget>
    /// Hash of the shared copy as it is on disk right now, derived on reload
    /// and omitted from `skills.json`. `nil` when the directory could not be
    /// read — which says nothing about whether it was edited.
    public var localContentHash: String?

    /// The shared copy's files no longer match what Vibe Bar recorded at
    /// install, adoption, update, or the last accept. Both hashes have to be
    /// known: a row without a recorded hash is back-filled rather than
    /// reported, and an unreadable directory is not evidence of an edit.
    public var isLocallyModified: Bool {
        guard let localContentHash, let contentHash else { return false }
        return localContentHash != contentHash
    }
    /// Every other copy of this skill on the Mac — real directories in a
    /// harness folder and harness built-ins with the same name — attached by
    /// `SkillsService.installedSkills()`. Transient like the native state:
    /// it describes the disk right now and is never written to `skills.json`.
    public var otherCopies: [SkillCopy] = []
    /// The shared copy's live metadata, attached alongside `otherCopies` and
    /// only when there is something to compare it with.
    public var sharedCopy: SkillCopy?

    public init(
        id: SkillID,
        name: String,
        description: String? = nil,
        directory: String,
        repoBranch: String? = nil,
        installedAt: Date,
        contentHash: String? = nil,
        updatedAt: Date? = nil,
        apps: [SkillAppTarget: SkillMaterialization] = [:],
        nativeDisabledApps: Set<SkillAppTarget> = [],
        nativeStateUnknownApps: Set<SkillAppTarget> = [],
        localContentHash: String? = nil,
        origin: SkillOrigin = .owned
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.directory = directory
        self.repoBranch = repoBranch
        self.installedAt = installedAt
        self.contentHash = contentHash
        self.updatedAt = updatedAt
        self.apps = apps
        self.nativeDisabledApps = nativeDisabledApps
        self.nativeStateUnknownApps = nativeStateUnknownApps
        self.localContentHash = localContentHash
        self.origin = origin
        self.linkCheck = nil
    }

    /// The receipt of a linked row, `nil` for an owned one.
    public var linkReceipt: SkillLinkReceipt? {
        if case let .linked(receipt) = origin { return receipt }
        return nil
    }

    public var isLinked: Bool { linkReceipt != nil }

    public var enabledApps: [SkillAppTarget] {
        SkillAppTarget.allCases.filter { activationState(for: $0) == .enabled }
    }

    /// Harness-specific link/copy entries that Vibe Bar has recorded.
    ///
    /// This is deliberately separate from `enabledApps`: Codex, Gemini CLI,
    /// Grok Build, and Cursor discover the shared SSOT directly, so a skill
    /// can be effectively enabled without a redundant app-side projection.
    public var projectedApps: [SkillAppTarget] {
        SkillAppTarget.allCases.filter { apps[$0] != nil }
    }

    public func isEnabled(for app: SkillAppTarget) -> Bool {
        activationState(for: app) == .enabled
    }

    public func isProjected(for app: SkillAppTarget) -> Bool {
        apps[app] != nil
    }

    /// Whether `app` would still discover this skill with its own projection
    /// gone: through the shared root it scans, or — for AntiGravity — through
    /// the Gemini CLI folder it reads for compatibility.
    ///
    /// `activationState` reports a direct projection as `.enabled` and so
    /// hides this second route; anything that removes a projection to turn a
    /// skill off has to ask here whether that can work at all.
    public func isDiscoveredWithoutProjection(for app: SkillAppTarget) -> Bool {
        app.discoversSharedSkillRoot || (app == .antigravity && isProjected(for: .gemini))
    }

    public func activationState(for app: SkillAppTarget) -> SkillActivationState {
        let projected = isProjected(for: app)
        let shared = app.discoversSharedSkillRoot
        guard projected || isDiscoveredWithoutProjection(for: app) else { return .notProjected }
        if nativeStateUnknownApps.contains(app) { return .unknown }
        if nativeDisabledApps.contains(app) { return .disabledInHarness }
        if projected { return .enabled }
        if shared, app.supportsNativeSkillActivation { return .enabled }
        return .coupled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, directory, repoBranch, installedAt, contentHash, updatedAt, apps, link
        case retiredCopies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(SkillID.self, forKey: .id)
        self.directory = try c.decodeIfPresent(String.self, forKey: .directory) ?? id.directory
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? directory
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.repoBranch = try c.decodeIfPresent(String.self, forKey: .repoBranch)
        self.installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date(timeIntervalSince1970: 0)
        self.contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        // App keys are decoded through their raw strings so a file written by
        // a newer build (which knows more agent CLIs) still loads here, minus
        // the entries this build cannot act on.
        let raw = try c.decodeIfPresent([String: SkillMaterialization].self, forKey: .apps) ?? [:]
        var apps: [SkillAppTarget: SkillMaterialization] = [:]
        for (key, value) in raw {
            guard let app = SkillAppTarget(rawValue: key) else { continue }
            apps[app] = value
        }
        self.apps = apps
        // A receipt that does not decode is not evidence of a link Vibe Bar
        // may write through: the row falls back to `.owned`, which grants
        // nothing while its shared entry is a symlink, and the link shows up
        // again as one the user can adopt.
        if let receipt = try? c.decodeIfPresent(SkillLinkReceipt.self, forKey: .link) {
            self.origin = .linked(receipt)
        } else {
            self.origin = .owned
        }
        self.linkCheck = nil
        var retired: [SkillAppTarget: String] = [:]
        for (key, hash) in (try? c.decodeIfPresent([String: String].self, forKey: .retiredCopies)) ?? [:] {
            guard let app = SkillAppTarget(rawValue: key) else { continue }
            retired[app] = hash
        }
        self.retiredCopyHashes = retired
        self.nativeDisabledApps = []
        self.nativeStateUnknownApps = []
        self.localContentHash = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(directory, forKey: .directory)
        try c.encodeIfPresent(repoBranch, forKey: .repoBranch)
        try c.encode(installedAt, forKey: .installedAt)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        var rawApps: [String: SkillMaterialization] = [:]
        for (app, value) in apps { rawApps[app.rawValue] = value }
        try c.encode(rawApps, forKey: .apps)
        try c.encodeIfPresent(linkReceipt, forKey: .link)
        if !retiredCopyHashes.isEmpty {
            var rawRetired: [String: String] = [:]
            for (app, hash) in retiredCopyHashes { rawRetired[app.rawValue] = hash }
            try c.encode(rawRetired, forKey: .retiredCopies)
        }
    }
}

public enum SkillError: Error, Equatable, Sendable {
    case invalidDirectoryName(String)
    case missingSkillMD(String)
    case directoryConflict(String)
    case notInstalled(SkillID)
    case writeOutsideAllowedRoots(String)
    case sourceDirectoryMissing(String)
    case sourceNotADirectory(String)
    case destinationExists(String)
    case backupNotFound(String)
    case backupCorrupted(String)
    case notRepositoryBacked(SkillID)
    case updateSourceMissing(String)
    case nativeActivationUnsupported(SkillAppTarget)
    case nativeConfigUnreadable(SkillAppTarget)
    case nativeSkillsGloballyDisabled(SkillAppTarget)
    case nativeSkillDisabledByPattern(SkillAppTarget)
    case projectionUnsupported(SkillAppTarget)
    case copyOutsideScannedRoots(String)
    /// The shared entry is not a symlink, so there is no link to adopt.
    case notALink(String)
    /// The link leads to something that is not a readable skill right now.
    case linkedSourceUnavailable(String)
    /// A linked skill's receipt no longer matches the link on disk.
    case linkReceiptMismatch(String)
    /// The link resolves to a folder that contains the shared skills root.
    case linkTargetUnsupported(String)
    /// The operation would read, hash, or write the linked folder's files.
    case linkedSkillUnsupported(String)
    /// The linked folder is larger than a copy into the shared root allows.
    case copyLimitExceeded(String)
    /// The linked folder now names its skill differently (directory, new
    /// name). Native switches are keyed by name, so it is not renamed.
    case linkedSkillRenamed(String, String)
}

extension SkillError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidDirectoryName(name):
            return "\"\(name)\" is not a valid skill directory name."
        case let .missingSkillMD(name):
            return "Skill \"\(name)\" has no SKILL.md."
        case let .directoryConflict(name):
            return "\"\(name)\" already exists and was not created by Vibe Bar."
        case let .notInstalled(id):
            return "Skill \"\(id.directory)\" is not installed."
        case let .writeOutsideAllowedRoots(path):
            return "Refusing to write outside the managed skill directories: \(path)"
        case let .sourceDirectoryMissing(name):
            return "Skill directory \"\(name)\" is missing."
        case let .sourceNotADirectory(name):
            return "\"\(name)\" is not a directory."
        case let .destinationExists(name):
            return "\"\(name)\" already exists."
        case let .backupNotFound(name):
            return "Backup \"\(name)\" was not found."
        case let .backupCorrupted(name):
            return "Backup \"\(name)\" is missing its metadata."
        case let .notRepositoryBacked(id):
            return "Skill \"\(id.directory)\" was not installed from a repository, so it cannot be updated."
        case let .updateSourceMissing(name):
            return "Skill \"\(name)\" is no longer in its source repository."
        case let .nativeActivationUnsupported(app):
            return "\(app.displayName) does not expose a native per-skill enable switch."
        case let .nativeConfigUnreadable(app):
            return "\(app.displayName)'s skill configuration could not be read safely."
        case let .nativeSkillsGloballyDisabled(app):
            return "\(app.displayName) has Skills disabled globally. Enable its global Skills switch before enabling an individual skill."
        case let .nativeSkillDisabledByPattern(app):
            return "A pattern in \(app.displayName)'s disabled skills list also matches this skill. Edit that pattern in its configuration to enable it."
        case let .projectionUnsupported(app):
            return "\(app.displayName) reads skills from ~/.agents/skills itself; Vibe Bar never writes into its own skills folder."
        case let .copyOutsideScannedRoots(path):
            return "\(path) is not a skill copy Vibe Bar recognizes."
        case let .notALink(name):
            return "\"\(name)\" in ~/.agents/skills is not a link."
        case let .linkedSourceUnavailable(name):
            return "The folder \"\(name)\" links to is not a readable skill right now."
        case let .linkReceiptMismatch(name):
            return "The link for \"\(name)\" no longer points where Vibe Bar recorded it. Re-confirm its source first."
        case let .linkTargetUnsupported(name):
            return "\"\(name)\" links to a folder that contains ~/.agents/skills itself, which Vibe Bar cannot manage."
        case let .linkedSkillUnsupported(name):
            return "\"\(name)\" links to a folder outside Vibe Bar's management. Convert it to a copy before changing its files."
        case let .copyLimitExceeded(name):
            return "\"\(name)\" is too large to copy into the shared library."
        case let .linkedSkillRenamed(name, newName):
            return "\"\(name)\" now links to a skill named \"\(newName)\". Agent switches are kept by skill name, so Vibe Bar does not rename it: unlink it and adopt the link again."
        }
    }
}
