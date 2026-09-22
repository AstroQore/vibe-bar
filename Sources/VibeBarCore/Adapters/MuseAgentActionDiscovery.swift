import Foundation

/// Where Muse's `fetchSubscriptionAction` currently lives.
public struct MuseAgentActionRecord: Codable, Equatable, Sendable {
    /// The Vercel deployment the id was found in (`dpl_…`), when the page
    /// named one. Informational: the server's "action not found" is what
    /// decides that an id is stale.
    public var deploymentID: String?
    public var actionID: String
    public var discoveredAt: Date

    public init(deploymentID: String?, actionID: String, discoveredAt: Date) {
        self.deploymentID = deploymentID
        self.actionID = actionID
        self.discoveredAt = discoveredAt
    }
}

/// Finds the current `fetchSubscriptionAction` id in the muse.ai web app.
///
/// A Next.js server action is called by a hash that is printed, next to the
/// action's name, in the client chunk that imports it:
/// `createServerReference)("<40-hex id>", …, "fetchSubscriptionAction")`.
/// The signed-in home page names its chunks as `static/chunks/<name>.js`, and
/// the chunks name further chunks the same way, so the search is a bounded
/// breadth-first walk: the page's chunks, then the chunks those mention.
///
/// The page is fetched with the session cookies (a signed-out visitor is
/// redirected to `auth.muse.ai` before any chunk is named); the chunks are
/// public static files and are fetched without them. Everything here is
/// bounded — at most `Limits.concurrency` requests at once, a file count, a
/// byte budget, a per-file cap and a wall-clock deadline — and stops at the
/// first match. It never runs on the main actor: its only caller is the
/// adapter, through `MuseAgentActionResolver`.
public struct MuseAgentActionDiscovery: Sendable {
    public struct Limits: Sendable, Equatable {
        public var concurrency: Int
        public var maxDepth: Int
        public var maxFiles: Int
        public var maxTotalBytes: Int
        public var maxFileBytes: Int
        public var deadline: TimeInterval

        public init(
            concurrency: Int = 8,
            maxDepth: Int = 2,
            maxFiles: Int = 600,
            maxTotalBytes: Int = 40 * 1024 * 1024,
            maxFileBytes: Int = 6 * 1024 * 1024,
            deadline: TimeInterval = 90
        ) {
            self.concurrency = max(1, min(concurrency, 8))
            self.maxDepth = maxDepth
            self.maxFiles = maxFiles
            self.maxTotalBytes = maxTotalBytes
            self.maxFileBytes = maxFileBytes
            self.deadline = deadline
        }
    }

    public static let actionName = "fetchSubscriptionAction"
    public static let homeURL = URL(string: "https://muse.ai/")!
    public static let chunkBaseURL = URL(string: "https://muse.ai/_next/static/chunks/")!

    /// What the card says when the id cannot be found or a fresh one is
    /// refused too: the page changed shape, not the user's session.
    static let changedMessage = "Muse's web app changed and Vibe Bar could not find its usage request. It will look again later."

    private let transport: any MuseAgentHTTPTransport
    private let limits: Limits
    private let now: @Sendable () -> Date

    public init(
        transport: any MuseAgentHTTPTransport,
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.limits = limits
        self.now = now
    }

    public func discover(cookieHeader: String) async throws -> MuseAgentActionRecord {
        let started = now()
        let html = try await fetchHome(cookieHeader: cookieHeader)
        let deploymentID = Self.deploymentID(inHTML: html)
        var seen: Set<String> = []
        var level = Self.chunkNames(in: html).filter { seen.insert($0).inserted }
        var files = 0
        var bytes = 0
        var depth = 1
        while !level.isEmpty, depth <= limits.maxDepth {
            let budget = max(0, limits.maxFiles - files)
            let batch = Array(level.prefix(budget))
            let outcome = try await scan(batch, started: started, bytesSoFar: bytes)
            files += outcome.filesRead
            bytes += outcome.bytesRead
            if let actionID = outcome.actionID {
                SafeLog.net("Muse subscription action found after \(files) chunk(s)")
                return MuseAgentActionRecord(deploymentID: deploymentID, actionID: actionID, discoveredAt: now())
            }
            guard files < limits.maxFiles, bytes < limits.maxTotalBytes else { break }
            level = outcome.referenced.filter { seen.insert($0).inserted }
            depth += 1
        }
        SafeLog.net("Muse subscription action not found in \(files) chunk(s)")
        throw QuotaError.parseFailure(Self.changedMessage)
    }

    // MARK: Steps

    private func fetchHome(cookieHeader: String) async throws -> String {
        var request = URLRequest(url: Self.homeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await transport.send(request)
        } catch {
            throw mapURLError(error)
        }
        switch http.statusCode {
        case 200..<300:
            return String(decoding: data.prefix(limits.maxFileBytes), as: UTF8.self)
        case 300..<400, 401, 403:
            // `307 → https://auth.muse.ai/…` is the signed-out page.
            throw QuotaError.needsLogin
        case 429:
            throw QuotaError.rateLimited
        case 500...599:
            throw QuotaError.network("server \(http.statusCode)")
        default:
            throw QuotaError.unknown("HTTP \(http.statusCode)")
        }
    }

    struct ChunkRead: Sendable {
        var actionID: String?
        var referenced: [String]
        var size: Int
    }

    struct ScanOutcome {
        var actionID: String?
        var referenced: [String] = []
        var filesRead = 0
        var bytesRead = 0
    }

    /// Reads `names` with at most `limits.concurrency` in flight, and stops
    /// launching new reads the moment one of them holds the action.
    private func scan(_ names: [String], started: Date, bytesSoFar: Int) async throws -> ScanOutcome {
        var outcome = ScanOutcome()
        var referenced: Set<String> = []
        try await withThrowingTaskGroup(of: ChunkRead.self) { group in
            var pending = names[...]
            var inFlight = 0
            while inFlight < limits.concurrency, let name = pending.popFirst() {
                group.addTask { try await self.readChunk(name) }
                inFlight += 1
            }
            while inFlight > 0 {
                guard let read = try await group.next() else { break }
                inFlight -= 1
                outcome.filesRead += 1
                outcome.bytesRead += read.size
                for name in read.referenced where referenced.insert(name).inserted {
                    outcome.referenced.append(name)
                }
                if let actionID = read.actionID {
                    outcome.actionID = actionID
                    group.cancelAll()
                    return
                }
                let overBudget = bytesSoFar + outcome.bytesRead >= limits.maxTotalBytes
                let overTime = now().timeIntervalSince(started) >= limits.deadline
                if overBudget || overTime || Task.isCancelled {
                    group.cancelAll()
                    return
                }
                if let name = pending.popFirst() {
                    group.addTask { try await self.readChunk(name) }
                    inFlight += 1
                }
            }
        }
        return outcome
    }

    /// One chunk: the action id if it declares one, the chunks it names, and
    /// its size. A chunk that fails to load is skipped, not fatal — the id is
    /// usually in one of a few dozen, and one CDN hiccup should not cost the
    /// whole search.
    private func readChunk(_ name: String) async throws -> ChunkRead {
        try Task.checkCancellation()
        guard let url = Self.chunkURL(name) else { return ChunkRead(actionID: nil, referenced: [], size: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (data, http) = try? await transport.send(request), (200..<300).contains(http.statusCode) else {
            try Task.checkCancellation()
            return ChunkRead(actionID: nil, referenced: [], size: 0)
        }
        let text = String(decoding: data.prefix(limits.maxFileBytes), as: UTF8.self)
        return ChunkRead(actionID: Self.actionID(inChunk: text), referenced: Self.chunkNames(in: text), size: data.count)
    }

    // MARK: Pure helpers (tested)

    /// `static/chunks/<name>.js` references, in order of first appearance.
    /// Only a single safe path segment is accepted, so a reference can never
    /// point the download outside `/_next/static/chunks/`.
    public static func chunkNames(in text: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for match in chunkPattern.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            guard isSafeChunkName(name), seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// The deployment id the page was rendered by (`dpl_…`), if it says.
    public static func deploymentID(inHTML html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = deploymentPattern.firstMatch(in: html, range: range),
              let idRange = Range(match.range, in: html) else { return nil }
        return String(html[idRange])
    }

    /// The hex id `createServerReference` registers under the action's name.
    public static func actionID(inChunk text: String) -> String? {
        guard text.contains(actionName) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = actionPattern.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[idRange])
    }

    /// Whether a 404 is Next.js saying it has no action by that id.
    public static func isActionNotFound(headers: HTTPURLResponse, data: Data) -> Bool {
        if headers.value(forHTTPHeaderField: "x-nextjs-action-not-found") != nil { return true }
        return String(decoding: data.prefix(256), as: UTF8.self).contains("Server action not found")
    }

    static func chunkURL(_ name: String) -> URL? {
        guard isSafeChunkName(name) else { return nil }
        return URL(string: name, relativeTo: chunkBaseURL)?.absoluteURL
    }

    static func isSafeChunkName(_ name: String) -> Bool {
        guard name.hasSuffix(".js"), !name.hasPrefix("."), !name.contains(".."), name.count <= 160 else { return false }
        return name.unicodeScalars.allSatisfy { safeChunkCharacters.contains($0) }
    }

    private static let safeChunkCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
    )
    private static let chunkPattern = try! NSRegularExpression(
        pattern: #"static/chunks/([A-Za-z0-9_\-.]+?\.js)"#
    )
    private static let deploymentPattern = try! NSRegularExpression(pattern: #"dpl_[A-Za-z0-9]+"#)
    private static let actionPattern = try! NSRegularExpression(
        pattern: #"createServerReference\)\("([0-9a-f]{20,})",[^"]{0,120}"fetchSubscriptionAction"\)"#
    )
}

/// Owns the cached action id: loads it once from
/// `~/.vibebar/muse_agent_action.json`, coalesces concurrent re-discoveries
/// into one, and after a failed search waits `failureBackoff` before scanning
/// the app again — a changed page must not turn every scheduled refresh into
/// a 15 MB download.
public actor MuseAgentActionResolver {
    public static let shared = MuseAgentActionResolver()

    private let fileURL: URL
    private let base: URL
    private let failureBackoff: TimeInterval
    private let limits: MuseAgentActionDiscovery.Limits
    private let now: @Sendable () -> Date

    private var loaded = false
    private var record: MuseAgentActionRecord?
    private var lastFailure: (at: Date, error: QuotaError)?
    private var inFlight: Task<MuseAgentActionRecord, Error>?

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        failureBackoff: TimeInterval = 30 * 60,
        limits: MuseAgentActionDiscovery.Limits = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = VibeBarLocalStore.museAgentActionURL(homeDirectory: homeDirectory)
        self.base = VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
        self.failureBackoff = failureBackoff
        self.limits = limits
        self.now = now
    }

    /// The remembered id, if any.
    public func current() -> MuseAgentActionRecord? {
        loadIfNeeded()
        return record
    }

    /// Finds the id again. `invalidating` is the id the caller just saw
    /// refused: if another caller has already replaced it, that answer is
    /// returned without a second search.
    public func rediscover(
        invalidating stale: String?,
        cookieHeader: String,
        transport: any MuseAgentHTTPTransport
    ) async throws -> MuseAgentActionRecord {
        loadIfNeeded()
        if let record, record.actionID != stale { return record }
        if let inFlight { return try await inFlight.value }
        if let lastFailure, now().timeIntervalSince(lastFailure.at) < failureBackoff {
            throw lastFailure.error
        }
        let discovery = MuseAgentActionDiscovery(transport: transport, limits: limits, now: now)
        let task = Task { try await discovery.discover(cookieHeader: cookieHeader) }
        inFlight = task
        defer { inFlight = nil }
        do {
            let found = try await task.value
            record = found
            lastFailure = nil
            persist(found)
            return found
        } catch {
            let quotaError = mapURLError(error)
            // A signed-out session says nothing about the page; the user can
            // fix it right away, so it must not hold the next attempt back.
            if quotaError != .needsLogin {
                lastFailure = (now(), quotaError)
            }
            throw quotaError
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        record = try? decoder.decode(MuseAgentActionRecord.self, from: data)
    }

    private func persist(_ record: MuseAgentActionRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(record) else { return }
        do {
            try VibeBarLocalStore.writeData(data, to: fileURL, base: base)
        } catch {
            SafeLog.net("Could not save the Muse action id: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }
}
