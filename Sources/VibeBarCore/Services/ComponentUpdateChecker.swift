import Foundation

/// A dotted version, compared the way semver says to.
///
/// Small on purpose: `agent-session-kit` tags are bare `X.Y.Z`, and the only
/// question anyone asks here is "is the tag on GitHub newer than the one
/// compiled into this binary?". Pre-release identifiers are parsed rather
/// than rejected — a `0.4.0-rc.1` tag would otherwise compare as newer than
/// `0.4.0`, which is exactly backwards.
public struct ComponentVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The `-` suffix, split on `.`. Empty means a final release.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2.3-rc.1`, `1.2.3+build`. Returns nil for
    /// anything else — an unparseable tag is reported as an error, never
    /// silently treated as "no update".
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, text.hasPrefix("v") || text.hasPrefix("V") {
            let rest = text.dropFirst()
            if rest.first?.isNumber == true { text = String(rest) }
        }
        // Build metadata is not part of precedence; drop it.
        if let plus = text.firstIndex(of: "+") { text = String(text[text.startIndex..<plus]) }
        var prereleasePart: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let suffix = text[text.index(after: dash)...]
            text = String(text[text.startIndex..<dash])
            guard !suffix.isEmpty else { return nil }
            prereleasePart = suffix.split(separator: ".").map(String.init)
            guard !prereleasePart.contains(where: \.isEmpty) else { return nil }
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prereleasePart)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: ComponentVersion, rhs: ComponentVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // A pre-release always precedes the release it leads to.
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true       // numeric identifiers rank lower
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// What a component-version check concluded. `message` is the sentence the
/// Settings row shows, kept here rather than in the view so the wording is
/// testable — and so the one thing that must never be implied has exactly
/// one place to go wrong.
public enum ComponentUpdateStatus: Sendable, Equatable {
    /// The newest release is the one compiled in.
    case upToDate(bundled: String)
    /// A newer release exists. It is *not* installable: this package is
    /// linked statically, so it arrives with the next build of the app.
    case updateAvailable(bundled: String, latest: String, releaseNotesURL: URL)
    /// The bundled build is ahead of the newest published release — normal
    /// while developing against an unreleased kit, or between a merge and
    /// its tag.
    case aheadOfLatestRelease(bundled: String, latest: String)
    /// The check did not complete. Never cached.
    case failed(reason: String)

    public var message: String {
        switch self {
        case .upToDate(let bundled):
            return "Up to date (\(bundled))"
        case .updateAvailable(_, let latest, _):
            return "Newer kit \(latest) available — ships with the next Vibe Bar build"
        case .aheadOfLatestRelease(let bundled, let latest):
            return "Bundled \(bundled) is ahead of the newest release (\(latest))"
        case .failed(let reason):
            return "Could not check for kit updates: \(reason)"
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The release to link to, when there is a newer one worth reading about.
    public var releaseNotesURL: URL? {
        if case .updateAvailable(_, _, let url) = self { return url }
        return nil
    }
}

public enum ComponentUpdateCheckError: Error, Sendable, Equatable {
    case notHTTP
    case noPublishedRelease
    case httpStatus(Int)
    case malformedResponse
    case unparseableTag

    /// Short, non-leaking, and safe to show in the Settings pane.
    public var displayReason: String {
        switch self {
        case .notHTTP: return "unexpected response"
        case .noPublishedRelease: return "no published release yet"
        case .httpStatus(let code): return "GitHub answered HTTP \(code)"
        case .malformedResponse: return "unreadable response"
        case .unparseableTag: return "unrecognised tag"
        }
    }
}

/// Asks GitHub what the newest `agent-session-kit` release is, so Settings
/// can say whether the version compiled into this app is the current one.
///
/// Three deliberate limits:
///
/// - **Manual only.** Nothing calls this on launch, on a timer, or when a
///   pane appears. A quota refresh is something the user asked for by
///   running the app; a version check is not, and a menu-bar app that
///   quietly talks to github.com every launch is a surprise. The Settings
///   button is the only trigger.
/// - **Unauthenticated.** No token, ever. The endpoint is public and the
///   answer is public; sending credentials to read a release number would
///   be strictly worse.
/// - **It cannot install anything.** `agent-session-kit` is linked
///   *statically* into this binary. A newer release reaches a user when
///   Vibe Bar bumps its pin and ships a build — never in place, never at
///   runtime. `ComponentUpdateStatus.message` says so in those words; do
///   not reword it into something that sounds like an available download.
///
/// The answer is cached in memory for six hours. Failures are not cached,
/// so a flaky network does not lock the row for the rest of the session,
/// and nothing is written to disk: this is a fact about the running binary,
/// not user state.
public actor ComponentUpdateChecker {
    public static let shared = ComponentUpdateChecker()

    /// `releases/latest` is the newest *published, non-prerelease* release —
    /// exactly what a consumer should be pinning to. Drafts never appear.
    public static let agentSessionKitLatestReleaseURL = URL(
        string: "https://api.github.com/repos/AstroQore/agent-session-kit/releases/latest"
    )!
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultCacheLifetime: TimeInterval = 6 * 60 * 60
    /// A release payload is a few kilobytes of JSON. The cap is defense in
    /// depth, not a tuning knob.
    public static let maxResponseBytes = 1024 * 1024

    private let session: URLSession
    private let endpoint: URL
    private let timeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    private var cachedStatus: ComponentUpdateStatus?
    private var cachedAt: Date?

    public init(
        session: URLSession? = nil,
        endpoint: URL = ComponentUpdateChecker.agentSessionKitLatestReleaseURL,
        timeout: TimeInterval = ComponentUpdateChecker.defaultTimeout,
        cacheLifetime: TimeInterval = ComponentUpdateChecker.defaultCacheLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session ?? ComponentUpdateChecker.makeSession()
        self.endpoint = endpoint
        self.timeout = timeout
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    /// Same posture as the remote-sync clients: ephemeral, no cache, no
    /// cookies, and redirects refused outright. A redirect off api.github.com
    /// is not something this request has any reason to follow.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = ComponentUpdateChecker.defaultTimeout
        return URLSession(
            configuration: configuration,
            delegate: RemoteNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// The newest published `agent-session-kit` release tag, normalised to a
    /// bare `X.Y.Z`.
    public func latestKitVersion() async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VibeBar", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await HTTPResponseLimit.boundedData(
            from: session,
            for: request,
            maxBytes: Self.maxResponseBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw ComponentUpdateCheckError.notHTTP
        }
        // A repository with tags but no Releases answers 404 here. That is a
        // fact, not a failure of ours, so it gets its own reason.
        if http.statusCode == 404 { throw ComponentUpdateCheckError.noPublishedRelease }
        guard http.statusCode == 200 else {
            throw ComponentUpdateCheckError.httpStatus(http.statusCode)
        }
        return try Self.parseTagName(from: data)
    }

    /// Decodes just the field this feature needs. GitHub's payload is large
    /// and mostly about assets and authors; none of it is stored.
    static func parseTagName(from data: Data) throws -> String {
        struct Release: Decodable { let tagName: String? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data) else {
            throw ComponentUpdateCheckError.malformedResponse
        }
        guard let raw = release.tagName else { throw ComponentUpdateCheckError.malformedResponse }
        let tag = AgentSessionKitInfo.normalizedTag(raw)
        guard ComponentVersion(tag) != nil else { throw ComponentUpdateCheckError.unparseableTag }
        return tag
    }

    /// Compares a fetched tag against the version compiled into this binary.
    /// Pure, so the three sentences the Settings row can show are testable
    /// without a network.
    public static func status(bundled: String, latest: String) -> ComponentUpdateStatus {
        guard let bundledVersion = ComponentVersion(bundled),
              let latestVersion = ComponentVersion(latest) else {
            return .failed(reason: ComponentUpdateCheckError.unparseableTag.displayReason)
        }
        if bundledVersion < latestVersion {
            return .updateAvailable(
                bundled: bundled,
                latest: latest,
                releaseNotesURL: AgentSessionKitInfo.releaseNotesURL(for: latest)
            )
        }
        if latestVersion < bundledVersion {
            return .aheadOfLatestRelease(bundled: bundled, latest: latest)
        }
        return .upToDate(bundled: bundled)
    }

    /// The Settings button's entry point. Returns the cached answer when it
    /// is under six hours old, unless the caller explicitly asks again.
    @discardableResult
    public func checkAgentSessionKit(force: Bool = false) async -> ComponentUpdateStatus {
        if !force, let cachedStatus, let cachedAt, now().timeIntervalSince(cachedAt) < cacheLifetime {
            return cachedStatus
        }
        do {
            let latest = try await latestKitVersion()
            let status = Self.status(bundled: AgentSessionKitInfo.version, latest: latest)
            // Only a real answer is worth remembering for six hours.
            if !status.isFailure {
                cachedStatus = status
                cachedAt = now()
            }
            return status
        } catch let error as ComponentUpdateCheckError {
            return .failed(reason: error.displayReason)
        } catch let error as HTTPResponseLimit.BoundedError {
            _ = error
            return .failed(reason: "response too large")
        } catch is CancellationError {
            return .failed(reason: "cancelled")
        } catch {
            // URLError and friends: report the class of failure, never the
            // URL or anything the system put in the description.
            let reason = (error as? URLError).map { "network error \($0.errorCode)" } ?? "network error"
            return .failed(reason: reason)
        }
    }

    /// The answer already in hand, if any, without touching the network.
    public func cachedAgentSessionKitStatus() -> ComponentUpdateStatus? {
        guard let cachedStatus, let cachedAt,
              now().timeIntervalSince(cachedAt) < cacheLifetime else { return nil }
        return cachedStatus
    }
}
