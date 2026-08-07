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

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .grok: return "Grok"
        case .hermes: return "Hermes"
        case .opencode: return "OpenCode"
        case .antigravity: return "AntiGravity"
        }
    }
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

    public init(
        id: SkillID,
        name: String,
        description: String? = nil,
        directory: String,
        repoBranch: String? = nil,
        installedAt: Date,
        contentHash: String? = nil,
        updatedAt: Date? = nil,
        apps: [SkillAppTarget: SkillMaterialization] = [:]
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
    }

    public var enabledApps: [SkillAppTarget] {
        SkillAppTarget.allCases.filter { apps[$0] != nil }
    }

    public func isEnabled(for app: SkillAppTarget) -> Bool {
        apps[app] != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, directory, repoBranch, installedAt, contentHash, updatedAt, apps
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
        }
    }
}
