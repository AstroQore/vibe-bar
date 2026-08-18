import Foundation

/// Where a one-shot skill install is being asked to read from.
///
/// This is the non-UI entry point into the Skills manager: an agent naming a
/// skill in one string, the way a person would write it in chat. Three
/// spellings reach the same two cases —
///
/// - `owner/repo`, `owner/repo@branch`, either plus `#directory`;
/// - a GitHub URL on `SkillRepoFetcher.allowedHosts` (the repository page, a
///   `/tree/<branch>` page, or an `/archive/….zip`), which is folded back into
///   the first case rather than downloaded as an arbitrary file;
/// - an absolute local directory holding `SKILL.md`.
///
/// Folding URLs into `SkillRepoRef` is the security-relevant part: nothing
/// here can turn into "download whatever this URL points at". A host outside
/// the allowlist is refused during parsing, before any network call, and the
/// download still goes through `SkillRepoFetching` with its size cap and
/// redirect allowlist.
public enum SkillInstallSource: Sendable, Equatable {
    /// A GitHub repository, optionally narrowed to one skill directory inside
    /// it. `skillDirectory` is required when the repository holds several.
    case repository(ref: SkillRepoRef, skillDirectory: String?)
    /// A directory on this Mac that is itself a skill.
    case localDirectory(URL)

    /// How the source was written, for echoing back in a result.
    public var descriptor: String {
        switch self {
        case let .repository(ref, skillDirectory):
            return skillDirectory.map { "\(ref.descriptor)#\($0)" } ?? ref.descriptor
        case let .localDirectory(url):
            return url.path
        }
    }

    public init(_ raw: String, homeDirectory: String = RealHomeDirectory.path) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillInstallSourceError.unrecognized(raw) }

        if trimmed.hasPrefix("/") {
            self = .localDirectory(URL(fileURLWithPath: trimmed, isDirectory: true))
            return
        }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            // Expanded here rather than by Foundation, so the one helper that
            // owns "the user's real home" stays the only one that answers it.
            let relative = String(trimmed.dropFirst(2))
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            self = .localDirectory(
                relative.isEmpty ? home : home.appendingPathComponent(relative, isDirectory: true)
            )
            return
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            self = try Self.parseURL(trimmed)
            return
        }
        if trimmed.hasPrefix(".") || trimmed.contains("\\") {
            throw SkillInstallSourceError.notAbsolutePath(trimmed)
        }
        self = try Self.parseSlug(trimmed)
    }

    // MARK: - Internals

    private static func parseSlug(_ raw: String) throws -> SkillInstallSource {
        var body = raw
        var directory: String?
        if let marker = body.firstIndex(of: "#") {
            directory = String(body[body.index(after: marker)...])
            body = String(body[body.startIndex..<marker])
        }
        guard let ref = SkillRepoRef(body) else {
            throw SkillInstallSourceError.unrecognized(raw)
        }
        if let directory {
            guard SkillPathValidator.isValid(directory) else {
                throw SkillInstallSourceError.invalidSkillDirectory(directory)
            }
        }
        return .repository(ref: ref, skillDirectory: directory)
    }

    /// GitHub spellings an agent plausibly pastes, all resolved to a ref. The
    /// host check happens first: an off-allowlist URL is refused here, not
    /// followed and then rejected.
    private static func parseURL(_ raw: String) throws -> SkillInstallSource {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else {
            throw SkillInstallSourceError.unrecognized(raw)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SkillInstallSourceError.insecureURL(raw)
        }
        guard SkillRepoFetcher.allowedHosts.contains(host) else {
            throw SkillInstallSourceError.hostNotAllowed(host)
        }
        var components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 2 else { throw SkillInstallSourceError.unsupportedURL(raw) }
        let owner = components.removeFirst()
        var repo = components.removeFirst()
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }

        var branch: String?
        if let kind = components.first {
            var rest = Array(components.dropFirst())
            // `/refs/heads/<branch>` and a bare `<branch>` are both in the
            // wild; so is `.zip` on the end of either.
            if rest.first == "refs", rest.dropFirst().first == "heads" { rest = Array(rest.dropFirst(2)) }
            switch kind {
            case "archive", "zip", "tree", "blob":
                guard var last = rest.last else { throw SkillInstallSourceError.unsupportedURL(raw) }
                if last.hasSuffix(".zip") { last = String(last.dropLast(4)) }
                branch = last
            default:
                throw SkillInstallSourceError.unsupportedURL(raw)
            }
        }
        guard let ref = SkillRepoRef(owner: owner, repo: repo, branch: branch) else {
            throw SkillInstallSourceError.unrecognized(raw)
        }
        var directory: String?
        if let fragment = url.fragment, !fragment.isEmpty {
            guard SkillPathValidator.isValid(fragment) else {
                throw SkillInstallSourceError.invalidSkillDirectory(fragment)
            }
            directory = fragment
        }
        return .repository(ref: ref, skillDirectory: directory)
    }
}

public enum SkillInstallSourceError: Error, Equatable, Sendable {
    case unrecognized(String)
    case notAbsolutePath(String)
    case insecureURL(String)
    case hostNotAllowed(String)
    case unsupportedURL(String)
    case invalidSkillDirectory(String)
    case noSkillsFound(String)
    case ambiguous(source: String, available: [String])
    case skillNotFound(name: String, source: String, available: [String])
}

extension SkillInstallSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unrecognized(raw):
            return "\"\(raw)\" is not owner/repo[@branch][#skill], a github.com URL, "
                + "or an absolute path to a skill directory."
        case let .notAbsolutePath(raw):
            return "\"\(raw)\" is a relative path. Local sources must be absolute."
        case let .insecureURL(raw):
            return "\"\(raw)\" is not https."
        case let .hostNotAllowed(host):
            return "Skills can only be installed from \(SkillRepoFetcher.allowedHosts.sorted().joined(separator: " and "))"
                + ", not \"\(host)\"."
        case let .unsupportedURL(raw):
            return "\"\(raw)\" is not a repository, branch, or archive URL. "
                + "Use owner/repo[@branch] instead."
        case let .invalidSkillDirectory(name):
            return "\"\(name)\" is not a usable skill directory name."
        case let .noSkillsFound(source):
            return "No SKILL.md was found in \(source)."
        case let .ambiguous(source, available):
            return "\(source) holds several skills. Name one with "
                + "'\(source)#<skill>': \(available.joined(separator: ", "))."
        case let .skillNotFound(name, source, available):
            return "\(source) has no skill called \"\(name)\". It has: "
                + "\(available.joined(separator: ", "))."
        }
    }
}

/// What one `install(from:enableFor:method:)` call did.
public struct SkillInstallOutcome: Sendable {
    public struct Installed: Sendable {
        public let skill: Skill
        /// The SSOT directory the payload now lives in.
        public let path: String
        /// Per app, where the skill was projected to.
        public let projectedTo: [SkillAppTarget: String]

        public init(skill: Skill, path: String, projectedTo: [SkillAppTarget: String]) {
            self.skill = skill
            self.path = path
            self.projectedTo = projectedTo
        }
    }

    /// A skill that was found but not installed — a name already held by a
    /// different skill, most often.
    public struct Skipped: Sendable {
        public let name: String
        public let reason: String

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public let source: String
    public let installed: [Installed]
    public let skipped: [Skipped]

    public init(source: String, installed: [Installed], skipped: [Skipped]) {
        self.source = source
        self.installed = installed
        self.skipped = skipped
    }
}
