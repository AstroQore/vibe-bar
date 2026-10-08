import Combine
import XCTest
@testable import VibeBarCore

/// `AccountStore.reload` runs the credential probe off the main actor, then
/// publishes once — only when an account changed, and only the newest call's
/// result. The detector is injected, so nothing here reads a real credential,
/// Keychain item or home directory.
@MainActor
final class AccountStoreReloadTests: XCTestCase {
    /// Answers each request by its Codex usage mode, stamping fresh
    /// timestamps every time exactly as real detection does. A mode can be
    /// held at a gate, so a test decides which of two probes finishes first.
    private final class ScriptedDetector: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [CodexUsageMode: [String]] = [:]
        private var gates: [CodexUsageMode: DispatchSemaphore] = [:]
        private var calls: [CodexUsageMode] = []
        private(set) var probedOffMainThread = true

        func respond(to mode: CodexUsageMode, with ids: [String], gate: DispatchSemaphore? = nil) {
            lock.lock()
            defer { lock.unlock() }
            responses[mode] = ids
            gates[mode] = gate
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls.count
        }

        var detector: AccountStore.Detector {
            { [self] request in self.detect(request) }
        }

        private func detect(_ request: AccountReloadRequest) -> [AccountIdentity] {
            let onMain = Thread.isMainThread
            lock.lock()
            calls.append(request.codexUsageMode)
            if onMain { probedOffMainThread = false }
            let ids = responses[request.codexUsageMode] ?? []
            let gate = gates[request.codexUsageMode]
            lock.unlock()
            gate?.wait()
            let now = Date()
            return ids.map {
                AccountIdentity(id: $0, tool: .codex, alias: $0, source: .oauthCLI, createdAt: now, updatedAt: now)
            }
        }
    }

    private func request(_ mode: CodexUsageMode) -> AccountReloadRequest {
        AccountReloadRequest(codexUsageMode: mode, miscProviderInstances: [])
    }

    // MARK: - Publishing only a change

    func testReloadThatFindsTheSameAccountsDoesNotPublish() async {
        let script = ScriptedDetector()
        script.respond(to: .auto, with: ["oauth-codex", "misc-cursor"])
        let store = AccountStore(accounts: [], detector: script.detector)
        var willChange = 0
        let subscription = store.objectWillChange.sink { willChange += 1 }
        defer { subscription.cancel() }

        await store.reload(request(.auto)).value
        XCTAssertEqual(store.accounts.map(\.id), ["oauth-codex", "misc-cursor"])
        XCTAssertEqual(willChange, 1)
        let firstStamp = store.accounts.first?.createdAt

        // Same accounts, newer timestamps: nothing to publish, and the live
        // values (with their original stamps) stay put.
        try? await Task.sleep(for: .milliseconds(5))
        await store.reload(request(.auto)).value
        await store.reload(request(.auto)).value
        XCTAssertEqual(willChange, 1)
        XCTAssertEqual(store.accounts.first?.createdAt, firstStamp)
        XCTAssertEqual(script.callCount, 3)
        XCTAssertTrue(script.probedOffMainThread)
    }

    func testReloadThatChangesOneAccountPublishesOnceAndKeepsTheRest() async {
        let script = ScriptedDetector()
        script.respond(to: .auto, with: ["oauth-codex", "misc-cursor"])
        script.respond(to: .cliOnly, with: ["cli-codex", "misc-cursor"])
        let store = AccountStore(accounts: [], detector: script.detector)
        await store.reload(request(.auto)).value
        let cursorBefore = store.accounts.last

        var willChange = 0
        let subscription = store.objectWillChange.sink { willChange += 1 }
        defer { subscription.cancel() }
        await store.reload(request(.cliOnly)).value

        XCTAssertEqual(willChange, 1)
        XCTAssertEqual(store.accounts.map(\.id), ["cli-codex", "misc-cursor"])
        // The unchanged account is the very value that was live before.
        XCTAssertEqual(store.accounts.last, cursorBefore)
    }

    func testSameContentIgnoresOnlyTheTimestamps() {
        let early = AccountIdentity(
            id: "oauth-codex", tool: .codex, plan: "Pro", source: .oauthCLI,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
        var later = early
        later.createdAt = Date(timeIntervalSince1970: 2)
        later.updatedAt = Date(timeIntervalSince1970: 3)
        XCTAssertNotEqual(early, later)
        XCTAssertTrue(early.hasSameContent(as: later))

        var replanned = later
        replanned.plan = "Plus"
        XCTAssertFalse(early.hasSameContent(as: replanned))
    }

    // MARK: - Overlapping reloads

    /// The older probe finishes last. It must not overwrite the newer result.
    func testOlderProbeFinishingLastNeverOverwritesTheNewerResult() async {
        let script = ScriptedDetector()
        let holdOlder = DispatchSemaphore(value: 0)
        script.respond(to: .auto, with: ["stale-codex"], gate: holdOlder)
        script.respond(to: .cliOnly, with: ["fresh-codex"])
        let store = AccountStore(accounts: [], detector: script.detector)
        var willChange = 0
        let subscription = store.objectWillChange.sink { willChange += 1 }
        defer { subscription.cancel() }

        let older = store.reload(request(.auto))
        let newer = store.reload(request(.cliOnly))
        await newer.value
        XCTAssertEqual(store.accounts.map(\.id), ["fresh-codex"])

        holdOlder.signal()
        await older.value
        XCTAssertEqual(store.accounts.map(\.id), ["fresh-codex"])
        XCTAssertEqual(willChange, 1, "only the newest result is ever published")
    }

    /// The older probe finishes first. It must not publish, and whoever
    /// awaited it must not resume until the newer result is live — that
    /// caller is about to read the accounts.
    func testSupersededReloadWaitsForTheNewestResult() async {
        let script = ScriptedDetector()
        let holdNewer = DispatchSemaphore(value: 0)
        script.respond(to: .auto, with: ["stale-codex"])
        script.respond(to: .cliOnly, with: ["fresh-codex"], gate: holdNewer)
        let store = AccountStore(accounts: [], detector: script.detector)
        var willChange = 0
        let subscription = store.objectWillChange.sink { willChange += 1 }
        defer { subscription.cancel() }

        let older = store.reload(request(.auto))
        let newer = store.reload(request(.cliOnly))
        var olderResumed = false
        let waiter = Task { @MainActor in
            await older.value
            olderResumed = true
            return store.accounts.map(\.id)
        }

        // Give the older probe ample time to finish and settle.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(olderResumed)
        XCTAssertTrue(store.accounts.isEmpty, "a superseded probe never publishes")

        holdNewer.signal()
        let seenByOlderCaller = await waiter.value
        await newer.value
        XCTAssertEqual(seenByOlderCaller, ["fresh-codex"])
        XCTAssertEqual(store.accounts.map(\.id), ["fresh-codex"])
        XCTAssertEqual(willChange, 1)
    }

    /// A burst of reloads — the Refresh button, six cookie imports finishing,
    /// a settings change — ends on the last request's result.
    func testBurstOfReloadsEndsOnTheLastRequest() async {
        let script = ScriptedDetector()
        let modes: [CodexUsageMode] = [.auto, .oauthThenCLI, .cliThenOAuth, .oauthOnly, .cliOnly]
        for mode in modes {
            script.respond(to: mode, with: ["\(mode.rawValue)-codex"])
        }
        let store = AccountStore(accounts: [], detector: script.detector)
        let reloads = modes.map { store.reload(request($0)) }
        for reload in reloads {
            await reload.value
            XCTAssertEqual(store.accounts.map(\.id), ["cliOnly-codex"])
        }
    }
}
