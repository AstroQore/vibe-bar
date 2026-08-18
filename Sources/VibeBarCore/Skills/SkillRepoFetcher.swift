import Foundation

/// A GitHub repository the skills feature can read, written the way users type
/// it: `owner/repo`, optionally `owner/repo@branch`.
///
/// The shape is validated strictly rather than escaped later, because these
/// three strings are interpolated straight into a URL path and (for the
/// repository name) can become a directory name. GitHub's own rules are the
/// ceiling: owners are alphanumerics and hyphens, repository and branch names
/// add `.` and `_`. `..`, leading dots, and separators are refused outright.
public struct SkillRepoRef: Hashable, Sendable, Codable {
    public let owner: String
    public let repo: String
    public let branch: String?

    public var slug: String { "\(owner)/\(repo)" }

    /// Round-trips through `init?(_:)`.
    public var descriptor: String { branch.map { "\(slug)@\($0)" } ?? slug }

    public init?(owner: String, repo: String, branch: String? = nil) {
        guard
            Self.isValidOwner(owner),
            Self.isValidName(repo),
            branch.map(Self.isValidName) ?? true
        else { return nil }
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var body = trimmed
        var branch: String?
        if let marker = body.firstIndex(of: "@") {
            branch = String(body[body.index(after: marker)...])
            body = String(body[body.startIndex..<marker])
        }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), repo: String(parts[1]), branch: branch)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = SkillRepoRef(raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Bad repository reference")
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(descriptor)
    }

    /// Same ref with the branch replaced — used once a fallback branch has
    /// actually been resolved.
    public func with(branch: String?) -> SkillRepoRef {
        SkillRepoRef(owner: owner, repo: repo, branch: branch) ?? self
    }

    private static let maxLength = 100

    private static func isValidOwner(_ value: String) -> Bool {
        guard (1...maxLength).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }

    private static func isValidName(_ value: String) -> Bool {
        guard (1...maxLength).contains(value.count) else { return false }
        guard !value.hasPrefix("."), value != "..", !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || scalar == "_" || scalar == "."
                || (CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII)
        }
    }
}

/// One skill directory found inside a downloaded repository, before install.
public struct DiscoveredSkill: Sendable, Hashable, Identifiable {
    public let id: SkillID
    public let name: String
    public let description: String?
    /// The SSOT directory name this would install as — the last path segment.
    public let directory: String
    /// Path of the skill directory inside the repository, `""` when the
    /// repository root is itself the skill.
    public let repoRelativePath: String
    public let branch: String
    public let readmeURL: URL?
    /// Where the extracted copy lives right now. Valid only while the
    /// downloading service keeps its staging directory alive.
    public let sourceRoot: URL

    public init(
        id: SkillID,
        name: String,
        description: String?,
        directory: String,
        repoRelativePath: String,
        branch: String,
        readmeURL: URL?,
        sourceRoot: URL
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.directory = directory
        self.repoRelativePath = repoRelativePath
        self.branch = branch
        self.readmeURL = readmeURL
        self.sourceRoot = sourceRoot
    }

    public var repositorySlug: String? { id.repositorySlug }
}

public enum SkillRepoError: Error, Equatable, Sendable {
    case invalidRepositoryReference(String)
    case branchNotFound(slug: String, tried: [String])
    case malformedArchive(String)
    case timedOut(slug: String, seconds: Int)
}

extension SkillRepoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRepositoryReference(raw):
            return "\"\(raw)\" is not a valid owner/repo reference."
        case let .branchNotFound(slug, tried):
            return "Could not download \(slug) (tried \(tried.joined(separator: ", ")))."
        case let .malformedArchive(detail):
            return "The repository archive was not laid out as expected (\(detail))."
        case let .timedOut(slug, seconds):
            return "Downloading \(slug) timed out after \(seconds) s."
        }
    }
}

/// The seam `SkillsService` reaches the network through. Everything network-
/// facing in the skills feature is behind these two calls, so the service's
/// install / update / discovery logic is testable with a fake.
public protocol SkillRepoFetching: Sendable {
    /// Downloads and extracts `ref` under `tempDir`, returning the repository
    /// root inside the extraction and the branch that actually answered.
    func downloadRepo(_ ref: SkillRepoRef, into tempDir: URL) async throws -> (root: URL, resolvedBranch: String)

    func scanSkills(
        inRepoRoot root: URL,
        ref: SkillRepoRef,
        resolvedBranch: String
    ) throws -> [DiscoveredSkill]
}

/// Downloads GitHub repository zipballs and finds the skills inside them.
///
/// No git, no API token, no clone: `codeload.github.com` serves a zip of any
/// public branch, and `github.com/<o>/<r>/archive/refs/heads/<b>.zip` is the
/// stable public form of that URL — it 302s to codeload, which is why both
/// hosts are on the allowlist and why the redirect check in `BoundedDownloader`
/// is a set membership test rather than a same-host test.
///
/// Branch resolution is "whatever answers first" over
/// `[requested, main, master]`: a 404 is a normal outcome for `main` on older
/// repositories, not an error worth surfacing. Only when every candidate fails
/// does this report `branchNotFound`, naming what it tried.
///
/// One repository gets `maxWallTime` in total, spread across every candidate
/// branch it tries. `timeout` alone cannot bound this: it is an idle timer per
/// request, so three candidates each dribbling bytes could hold a "Scan repos"
/// spinner open indefinitely. The remaining budget is recomputed before each
/// candidate and handed to the downloader as its resource ceiling.
public struct SkillRepoFetcher: SkillRepoFetching {
    /// A GitHub zipball of a skills repository is a few hundred KB; 128 MiB is
    /// a hard stop for something that has gone wrong, not a working budget.
    public static let maxArchiveBytes: Int64 = 128 * 1024 * 1024
    public static let defaultTimeout: TimeInterval = 60
    /// Wall-clock ceiling for one repository, every branch candidate included.
    /// A `vibe-bar`-sized zipball (8 MB) lands in about four seconds, so this
    /// is a "something is wrong" stop, not a working budget.
    public static let maxWallTime: TimeInterval = 120
    public static let allowedHosts: Set<String> = ["github.com", "codeload.github.com"]
    public static let fallbackBranches = ["main", "master"]

    private let downloader: BoundedDownloader
    private let maxArchiveBytes: Int64
    private let timeout: TimeInterval
    private let maxWallTime: TimeInterval

    public init(
        downloader: BoundedDownloader = BoundedDownloader(),
        maxArchiveBytes: Int64 = SkillRepoFetcher.maxArchiveBytes,
        timeout: TimeInterval = SkillRepoFetcher.defaultTimeout,
        maxWallTime: TimeInterval = SkillRepoFetcher.maxWallTime
    ) {
        self.downloader = downloader
        self.maxArchiveBytes = maxArchiveBytes
        self.timeout = timeout
        self.maxWallTime = maxWallTime
    }

    public static func archiveURL(owner: String, repo: String, branch: String) -> URL? {
        URL(string: "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(branch).zip")
    }

    public func downloadRepo(
        _ ref: SkillRepoRef,
        into tempDir: URL
    ) async throws -> (root: URL, resolvedBranch: String) {
        let candidates = Self.branchCandidates(for: ref)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(maxWallTime)
        let expired = SkillRepoError.timedOut(slug: ref.slug, seconds: Int(maxWallTime.rounded()))

        var lastError: Error?
        for branch in candidates {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw expired }
            guard let url = Self.archiveURL(owner: ref.owner, repo: ref.repo, branch: branch) else { continue }
            let zipURL = tempDir.appendingPathComponent("\(ref.repo)-\(branch).zip")
            do {
                try await downloader.download(
                    from: url,
                    to: zipURL,
                    maxBytes: maxArchiveBytes,
                    timeout: min(timeout, remaining),
                    allowedHosts: Self.allowedHosts,
                    resourceTimeout: remaining
                )
            } catch let error as BoundedDownloader.DownloadError {
                // A redirect off the allowlist is a security signal, not a
                // "try the next branch" signal.
                if case .redirectHostNotAllowed = error { throw error }
                lastError = error
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .timedOut {
                // The budget is per repository, not per branch: a candidate
                // that ran out of clock means the next one has none either.
                throw expired
            } catch {
                lastError = error
                continue
            }
            defer { try? FileManager.default.removeItem(at: zipURL) }
            try Task.checkCancellation()
            let extraction = tempDir.appendingPathComponent("extract-\(branch)", isDirectory: true)
            try? FileManager.default.removeItem(at: extraction)
            try SkillArchiveExtractor.extract(zipFileURL: zipURL, into: extraction)
            let root = try Self.repositoryRoot(in: extraction)
            SafeLog.net("Skills: fetched \(ref.slug)@\(branch)")
            return (root, branch)
        }
        if let lastError, !(lastError is BoundedDownloader.DownloadError) { throw lastError }
        throw SkillRepoError.branchNotFound(slug: ref.slug, tried: candidates)
    }

    public func scanSkills(
        inRepoRoot root: URL,
        ref: SkillRepoRef,
        resolvedBranch: String
    ) throws -> [DiscoveredSkill] {
        let found = SkillTreeScanner.scan(root: root)
        var seen = Set<String>()
        var results: [DiscoveredSkill] = []
        for entry in found {
            let directory = entry.relativePath.isEmpty
                ? ref.repo
                : String(entry.relativePath.split(separator: "/").last ?? "")
            guard SkillPathValidator.isValid(directory), seen.insert(directory).inserted else { continue }
            let frontmatter = SkillFrontmatterParser.parse(
                contentsOf: entry.url.appendingPathComponent("SKILL.md")
            )
            let markdownPath = entry.relativePath.isEmpty ? "SKILL.md" : "\(entry.relativePath)/SKILL.md"
            results.append(
                DiscoveredSkill(
                    id: .repo(owner: ref.owner, repo: ref.repo, directory: directory),
                    name: frontmatter.name ?? directory,
                    description: frontmatter.description,
                    directory: directory,
                    repoRelativePath: entry.relativePath,
                    branch: resolvedBranch,
                    readmeURL: Self.blobURL(ref: ref, branch: resolvedBranch, path: markdownPath),
                    sourceRoot: entry.url
                )
            )
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Internals

    static func branchCandidates(for ref: SkillRepoRef) -> [String] {
        var seen = Set<String>()
        return ([ref.branch].compactMap { $0 } + fallbackBranches).filter { seen.insert($0).inserted }
    }

    static func blobURL(ref: SkillRepoRef, branch: String, path: String) -> URL? {
        let encoded = path
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://github.com/\(ref.owner)/\(ref.repo)/blob/\(branch)/\(encoded)")
    }

    /// A GitHub zipball wraps everything in one `<repo>-<branch>` directory.
    /// Any single top-level directory is accepted, since the wrapper name is
    /// GitHub's business (a slashed branch name flattens it, for one).
    static func repositoryRoot(in extraction: URL) throws -> URL {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: extraction.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        guard names.count == 1 else {
            throw SkillRepoError.malformedArchive("expected one top-level directory, found \(names.count)")
        }
        let root = extraction.appendingPathComponent(names[0], isDirectory: true)
        guard SkillFileSystem.kind(of: root) == .directory else {
            throw SkillRepoError.malformedArchive("top-level entry is not a directory")
        }
        return root
    }
}

/// Finds skill directories in an arbitrary extracted tree.
///
/// One rule: a directory holding `SKILL.md` *is* a skill, and the walk does not
/// descend into it. Skills bundle reference material and helper scripts, and
/// some of that material is itself a `SKILL.md` example — descending would turn
/// one skill into several. Hidden directories are skipped, which is also how
/// `.git/` and `.github/` stay out of the results.
enum SkillTreeScanner {
    struct Found: Hashable {
        /// Path relative to the scan root; `""` when the root is the skill.
        let relativePath: String
        let url: URL
    }

    static let maxDepth = 8
    static let maxResults = 2_000

    static func scan(root: URL, maxDepth: Int = SkillTreeScanner.maxDepth) -> [Found] {
        guard SkillFileSystem.kind(of: root) == .directory else { return [] }
        if isSkillDirectory(root) { return [Found(relativePath: "", url: root)] }
        var results: [Found] = []
        walk(directory: root, relativePath: "", depth: 0, maxDepth: maxDepth, into: &results)
        return results.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    static func isSkillDirectory(_ url: URL) -> Bool {
        SkillFileSystem.kind(of: url.appendingPathComponent("SKILL.md")) == .regularFile
    }

    private static func walk(
        directory: URL,
        relativePath: String,
        depth: Int,
        maxDepth: Int,
        into results: inout [Found]
    ) {
        guard depth <= maxDepth, results.count < maxResults else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        for name in names where !name.hasPrefix(".") {
            let child = directory.appendingPathComponent(name, isDirectory: true)
            // lstat, not stat: a symlinked directory inside the archive is
            // never followed. `SkillArchiveExtractor` refuses symlink entries,
            // so this only matters for trees that arrived another way.
            guard SkillFileSystem.kind(of: child) == .directory else { continue }
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            if isSkillDirectory(child) {
                results.append(Found(relativePath: childPath, url: child))
                continue
            }
            walk(directory: child, relativePath: childPath, depth: depth + 1, maxDepth: maxDepth, into: &results)
        }
    }
}
