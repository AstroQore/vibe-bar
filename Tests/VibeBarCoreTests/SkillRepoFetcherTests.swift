import XCTest
@testable import VibeBarCore

/// Covers the three jobs of the fetcher — parsing what the user typed,
/// downloading a branch, and recognizing skills in what came back — plus the
/// `BoundedDownloader` guarantees the download leans on. Nothing here touches
/// the real network: every request is served by a `URLProtocol` stub, which is
/// also the only way to exercise the redirect check.
final class SkillRepoFetcherTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarFetcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Reference parsing

    func testParsesWellFormedReferences() {
        XCTAssertEqual(SkillRepoRef("anthropics/skills")?.descriptor, "anthropics/skills")
        XCTAssertEqual(SkillRepoRef("cexll/myclaude@master")?.branch, "master")
        XCTAssertEqual(SkillRepoRef("  JimLiu/baoyu-skills  ")?.slug, "JimLiu/baoyu-skills")
        XCTAssertEqual(SkillRepoRef("a/b.c_d-e@v1.2_x-y")?.descriptor, "a/b.c_d-e@v1.2_x-y")
        XCTAssertNil(SkillRepoRef("anthropics/skills")?.branch)
    }

    func testRejectsMalformedReferences() {
        let bad = [
            "", "anthropics", "anthropics/", "/skills", "a/b/c", "a b/c",
            "a/..", "a/../b", "a/b@..", "a/b@x/y", "a/b@", "a/.hidden",
            "a/b@.hidden", "own er/repo", "a/b c", "https://github.com/a/b",
            "a/b#main", "a_b/c", String(repeating: "x", count: 101) + "/repo"
        ]
        for raw in bad {
            XCTAssertNil(SkillRepoRef(raw), "\"\(raw)\" must not parse")
        }
    }

    func testBranchCandidatesTryTheRequestedBranchFirstAndNeverRepeat() {
        XCTAssertEqual(
            SkillRepoFetcher.branchCandidates(for: SkillRepoRef("a/b@dev")!),
            ["dev", "main", "master"]
        )
        XCTAssertEqual(
            SkillRepoFetcher.branchCandidates(for: SkillRepoRef("a/b@main")!),
            ["main", "master"]
        )
        XCTAssertEqual(SkillRepoFetcher.branchCandidates(for: SkillRepoRef("a/b")!), ["main", "master"])
    }

    // MARK: - Scanning

    func testScanFindsNestedSkillsAndStopsDescendingAtSkillMD() throws {
        let root = workspace.appendingPathComponent("myskills-master", isDirectory: true)
        try makeSkill(at: root.appendingPathComponent("skills/pdf"), name: "PDF tools", description: "Reads PDFs")
        try makeSkill(at: root.appendingPathComponent("skills/deep/nested/docx"))
        // A SKILL.md used as sample material inside another skill must not
        // become a second skill.
        try makeSkill(at: root.appendingPathComponent("skills/pdf/examples/sample"))
        try makeSkill(at: root.appendingPathComponent(".github/hidden"))
        try write("# readme", to: root.appendingPathComponent("README.md"))

        let ref = SkillRepoRef("acme/myskills@master")!
        let found = try SkillRepoFetcher().scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: "master")

        XCTAssertEqual(found.map(\.directory), ["docx", "pdf"])
        let pdf = try XCTUnwrap(found.first { $0.directory == "pdf" })
        XCTAssertEqual(pdf.id, .repo(owner: "acme", repo: "myskills", directory: "pdf"))
        XCTAssertEqual(pdf.name, "PDF tools")
        XCTAssertEqual(pdf.description, "Reads PDFs")
        XCTAssertEqual(pdf.repoRelativePath, "skills/pdf")
        XCTAssertEqual(pdf.branch, "master")
        XCTAssertEqual(
            pdf.readmeURL?.absoluteString,
            "https://github.com/acme/myskills/blob/master/skills/pdf/SKILL.md"
        )
        XCTAssertEqual(pdf.sourceRoot.lastPathComponent, "pdf")
    }

    func testScanTreatsARepositoryThatIsItselfASkillAsOne() throws {
        let root = workspace.appendingPathComponent("solo-main", isDirectory: true)
        try makeSkill(at: root, name: "Solo")

        let ref = SkillRepoRef("acme/solo")!
        let found = try SkillRepoFetcher().scanSkills(inRepoRoot: root, ref: ref, resolvedBranch: "main")

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].directory, "solo")
        XCTAssertEqual(found[0].repoRelativePath, "")
        XCTAssertEqual(
            found[0].readmeURL?.absoluteString,
            "https://github.com/acme/solo/blob/main/SKILL.md"
        )
    }

    // MARK: - Downloading

    func testDownloadsAndFallsBackFromMainToMaster() async throws {
        StubURLProtocol.replies[Self.archive("acme", "myskills", "main")] = .init(statusCode: 404)
        StubURLProtocol.replies[Self.archive("acme", "myskills", "master")] = .init(body: Self.repositoryZip())

        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        let (root, branch) = try await fetcher.downloadRepo(
            SkillRepoRef("acme/myskills")!,
            into: workspace.appendingPathComponent("dl", isDirectory: true)
        )

        XCTAssertEqual(branch, "master")
        XCTAssertEqual(root.lastPathComponent, "myskills-master")
        let skills = try fetcher.scanSkills(
            inRepoRoot: root,
            ref: SkillRepoRef("acme/myskills")!,
            resolvedBranch: branch
        )
        XCTAssertEqual(skills.map(\.directory), ["alpha"])
        XCTAssertEqual(skills[0].name, "Alpha")
        XCTAssertEqual(
            StubURLProtocol.requested,
            [Self.archive("acme", "myskills", "main"), Self.archive("acme", "myskills", "master")]
        )
    }

    func testRefusesARedirectThatLeavesTheAllowedHosts() async {
        StubURLProtocol.replies[Self.archive("acme", "myskills", "main")] = .init(
            redirectTo: URL(string: "https://evil.example.com/payload.zip")!
        )
        StubURLProtocol.replies["https://evil.example.com/payload.zip"] = .init(body: Self.repositoryZip())

        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        do {
            _ = try await fetcher.downloadRepo(
                SkillRepoRef("acme/myskills@main")!,
                into: workspace.appendingPathComponent("dl", isDirectory: true)
            )
            XCTFail("A redirect off the allowlist must fail the download")
        } catch let error as BoundedDownloader.DownloadError {
            XCTAssertEqual(error, .redirectHostNotAllowed("evil.example.com"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(
            StubURLProtocol.requested.contains("https://evil.example.com/payload.zip"),
            "The blocked redirect must never be fetched"
        )
    }

    func testFollowsARedirectThatStaysOnTheAllowedHosts() async throws {
        // github.com legitimately 302s to codeload.github.com.
        StubURLProtocol.replies[Self.archive("acme", "myskills", "main")] = .init(
            redirectTo: URL(string: "https://codeload.github.com/acme/myskills/zip/refs/heads/main")!
        )
        StubURLProtocol.replies["https://codeload.github.com/acme/myskills/zip/refs/heads/main"] = .init(
            body: Self.repositoryZip(branch: "main")
        )

        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        let (root, branch) = try await fetcher.downloadRepo(
            SkillRepoRef("acme/myskills@main")!,
            into: workspace.appendingPathComponent("dl", isDirectory: true)
        )

        XCTAssertEqual(branch, "main")
        XCTAssertEqual(root.lastPathComponent, "myskills-main")
    }

    func testReportsBranchNotFoundWhenNoCandidateAnswers() async {
        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        do {
            _ = try await fetcher.downloadRepo(
                SkillRepoRef("acme/ghost")!,
                into: workspace.appendingPathComponent("dl", isDirectory: true)
            )
            XCTFail("Expected branchNotFound")
        } catch let error as SkillRepoError {
            XCTAssertEqual(error, .branchNotFound(slug: "acme/ghost", tried: ["main", "master"]))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testRejectsAnArchiveWithoutASingleTopLevelDirectory() async {
        var builder = RawZipBuilder()
        builder.entries = [.file("a/SKILL.md", "---\n"), .file("b/SKILL.md", "---\n")]
        StubURLProtocol.replies[Self.archive("acme", "flat", "main")] = .init(body: builder.build())

        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        do {
            _ = try await fetcher.downloadRepo(
                SkillRepoRef("acme/flat@main")!,
                into: workspace.appendingPathComponent("dl", isDirectory: true)
            )
            XCTFail("Expected malformedArchive")
        } catch let error as SkillRepoError {
            XCTAssertEqual(
                error,
                .malformedArchive("expected one top-level directory, found 2")
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    // MARK: - BoundedDownloader

    func testDownloaderRefusesPlainHTTPAndForeignHostsBeforeTheNetwork() async {
        let downloader = Self.stubbedDownloader()
        let destination = workspace.appendingPathComponent("out.zip")

        do {
            try await downloader.download(
                from: URL(string: "http://github.com/a/b.zip")!,
                to: destination,
                maxBytes: 1024,
                timeout: 5,
                allowedHosts: SkillRepoFetcher.allowedHosts
            )
            XCTFail("Expected insecureScheme")
        } catch {
            XCTAssertEqual(error as? BoundedDownloader.DownloadError, .insecureScheme("http"))
        }

        do {
            try await downloader.download(
                from: URL(string: "https://example.com/a/b.zip")!,
                to: destination,
                maxBytes: 1024,
                timeout: 5,
                allowedHosts: SkillRepoFetcher.allowedHosts
            )
            XCTFail("Expected hostNotAllowed")
        } catch {
            XCTAssertEqual(error as? BoundedDownloader.DownloadError, .hostNotAllowed("example.com"))
        }
        XCTAssertTrue(StubURLProtocol.requested.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloaderStopsMidStreamOnAnUndeclaredOversizeBody() async {
        // No Content-Length, so only the running byte count can catch this.
        StubURLProtocol.replies["https://github.com/a/b.zip"] = .init(
            body: Data(repeating: 0x41, count: 300_000),
            includeContentLength: false
        )
        let destination = workspace.appendingPathComponent("out.zip")

        do {
            try await Self.stubbedDownloader().download(
                from: URL(string: "https://github.com/a/b.zip")!,
                to: destination,
                maxBytes: 4_096,
                timeout: 5,
                allowedHosts: ["github.com"]
            )
            XCTFail("Expected tooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedDownloader.DownloadError, .tooLarge(limit: 4_096))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "The partial download must be deleted"
        )
    }

    func testDownloaderRefusesADeclaredOversizeBodyBeforeReadingIt() async {
        StubURLProtocol.replies["https://github.com/a/b.zip"] = .init(
            body: Data(repeating: 0x41, count: 300_000)
        )
        do {
            try await Self.stubbedDownloader().download(
                from: URL(string: "https://github.com/a/b.zip")!,
                to: workspace.appendingPathComponent("out.zip"),
                maxBytes: 1_024,
                timeout: 5,
                allowedHosts: ["github.com"]
            )
            XCTFail("Expected tooLarge")
        } catch {
            XCTAssertEqual(error as? BoundedDownloader.DownloadError, .tooLarge(limit: 1_024))
        }
    }

    /// The complaint this whole path exists to answer: a download that never
    /// finishes must end when the user says so, not when the server does.
    func testDownloaderFailsWithCancellationWhenTheTaskIsCancelled() async throws {
        StubURLProtocol.replies["https://github.com/a/b.zip"] = .init(hangs: true)
        let destination = workspace.appendingPathComponent("out.zip")
        let downloader = Self.stubbedDownloader()

        let download = Task {
            try await downloader.download(
                from: URL(string: "https://github.com/a/b.zip")!,
                to: destination,
                maxBytes: 1_000_000,
                timeout: 30,
                allowedHosts: ["github.com"]
            )
        }
        try await Self.waitUntil { StubURLProtocol.requested.contains("https://github.com/a/b.zip") }
        download.cancel()

        do {
            try await download.value
            XCTFail("Expected the cancelled download to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "The partial download must be deleted"
        )
    }

    /// `timeout` is an idle timer, so a repository budget needs its own clock.
    func testDownloadRepoGivesUpOnceTheWallClockBudgetIsSpent() async {
        StubURLProtocol.replies[Self.archive("acme", "slow", "main")] = .init(hangs: true)
        StubURLProtocol.replies[Self.archive("acme", "slow", "master")] = .init(hangs: true)

        let fetcher = SkillRepoFetcher(
            downloader: Self.stubbedDownloader(),
            timeout: 30,
            maxWallTime: 0.4
        )
        let started = Date()
        do {
            _ = try await fetcher.downloadRepo(
                SkillRepoRef("acme/slow")!,
                into: workspace.appendingPathComponent("dl", isDirectory: true)
            )
            XCTFail("Expected timedOut")
        } catch let error as SkillRepoError {
            XCTAssertEqual(error, .timedOut(slug: "acme/slow", seconds: 0))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            20,
            "The budget must bound the whole repository, not each branch candidate"
        )
    }

    func testDownloadRepoIsCancellable() async {
        StubURLProtocol.replies[Self.archive("acme", "slow", "main")] = .init(hangs: true)
        let fetcher = SkillRepoFetcher(downloader: Self.stubbedDownloader())
        let directory = workspace.appendingPathComponent("dl", isDirectory: true)

        let download = Task { try await fetcher.downloadRepo(SkillRepoRef("acme/slow@main")!, into: directory) }
        try? await Self.waitUntil { !StubURLProtocol.requested.isEmpty }
        download.cancel()

        do {
            _ = try await download.value
            XCTFail("Expected the cancelled fetch to throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }
    }

    func testDownloaderWritesTheBodyItWasGiven() async throws {
        let payload = Data(repeating: 0x5A, count: 12_345)
        StubURLProtocol.replies["https://github.com/a/b.zip"] = .init(body: payload)
        let destination = workspace.appendingPathComponent("nested/out.zip")

        try await Self.stubbedDownloader().download(
            from: URL(string: "https://github.com/a/b.zip")!,
            to: destination,
            maxBytes: 1_000_000,
            timeout: 5,
            allowedHosts: ["github.com"]
        )

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    // MARK: - Helpers

    /// Polls until `condition` holds, so a cancellation test cancels something
    /// that is actually in flight rather than a task that has not started.
    private static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw MCPTestError("Timed out waiting for the condition") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func stubbedDownloader() -> BoundedDownloader {
        BoundedDownloader {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return configuration
        }
    }

    private static func archive(_ owner: String, _ repo: String, _ branch: String) -> String {
        SkillRepoFetcher.archiveURL(owner: owner, repo: repo, branch: branch)!.absoluteString
    }

    /// A zipball shaped the way GitHub ships one: everything under a single
    /// `<repo>-<branch>` directory.
    private static func repositoryZip(branch: String = "master") -> Data {
        var builder = RawZipBuilder()
        builder.entries = [
            .directory("myskills-\(branch)"),
            .file("myskills-\(branch)/README.md", "# myskills"),
            .file("myskills-\(branch)/skills/alpha/SKILL.md", "---\nname: Alpha\n---\n# Alpha\n"),
            .file("myskills-\(branch)/skills/alpha/ref.md", "reference")
        ]
        return builder.build()
    }

    private func makeSkill(at url: URL, name: String? = nil, description: String? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var frontmatter = "---\nname: \(name ?? url.lastPathComponent)\n"
        if let description { frontmatter += "description: \(description)\n" }
        frontmatter += "---\n\n# \(url.lastPathComponent)\n"
        try write(frontmatter, to: url.appendingPathComponent("SKILL.md"))
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Serves canned replies keyed by absolute URL, including real redirects — the
/// only way to drive `URLSession`'s redirect delegate from a test.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var statusCode = 200
        var body: Data?
        var redirectTo: URL?
        var includeContentLength = true
        /// Accepts the request and never answers, standing in for the server
        /// that made "Scan repos" spin for twenty seconds.
        var hangs = false
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requested: [String] = []

    static func reset() {
        replies = [:]
        requested = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requested.append(url.absoluteString)
        let reply = Self.replies[url.absoluteString] ?? Reply(statusCode: 404)

        if reply.hangs { return }

        if let redirect = reply.redirectTo {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect.absoluteString]
            )!
            var followUp = URLRequest(url: redirect)
            followUp.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            return
        }

        var headers: [String: String] = [:]
        if reply.includeContentLength {
            headers["Content-Length"] = String(reply.body?.count ?? 0)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = reply.body, reply.statusCode == 200 {
            // Delivered in slices so the streaming byte cap has something to
            // count rather than one all-or-nothing chunk.
            var offset = 0
            while offset < body.count {
                let end = min(offset + 32_768, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
