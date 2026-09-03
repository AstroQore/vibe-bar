import XCTest
@testable import VibeBarCore

/// Covers the gating and retry-merge logic of the opt-in silent
/// re-import. The browser read itself (`MiscCookieResolver.silentReimport`)
/// needs a real cookie store and Keychain, so it's injected here — what
/// matters for correctness is *whether* and *how often* it runs.
final class MiscCookieAutoImporterTests: XCTestCase {
    private let account = AccountIdentity(
        id: "misc-kimi",
        tool: .kimi,
        email: "user@example.com",
        source: .browserCookie
    )

    private let spec = MiscCookieResolver.Spec(
        tool: .kimi,
        domains: ["www.kimi.com"],
        requiredNames: ["kimi-auth"]
    )

    private let queriedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func quota() -> AccountQuota {
        AccountQuota(
            accountId: account.id,
            tool: .kimi,
            buckets: [
                QuotaBucket(
                    id: "kimi.weekly",
                    title: "Weekly",
                    shortLabel: "Wk",
                    usedPercent: 42,
                    resetAt: nil,
                    rawWindowSeconds: 7 * 86_400
                )
            ],
            plan: nil
        )
    }

    /// The whole point of the default-off setting: a stale jar must not
    /// trigger any browser or Keychain work until the user opts in.
    func testDisabledSettingSkipsReimportEntirely() async {
        let slotID = UUID()
        let reimportCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { false },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in
                XCTFail("resolve must not run when the setting is off")
                return []
            }
        )

        let results = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
        ) { _ in
            throw QuotaError.needsLogin
        }

        XCTAssertEqual(reimportCalls.value, 0)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.outcome.failureError, .needsLogin)
    }

    /// A healthy fetch must not pay for a settings read, a browser walk,
    /// or a second network round-trip.
    func testSuccessfulFetchNeverReimports() async {
        let reimportCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: {
                XCTFail("the setting should not even be consulted when nothing is stale")
                return true
            },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in [] }
        )

        let results = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: UUID(), header: "kimi-auth=good", sourceLabel: "Chrome")]
        ) { _ in
            self.quota()
        }

        XCTAssertEqual(reimportCalls.value, 0)
        XCTAssertNil(results.first?.outcome.failureError)
    }

    func testEnabledSettingReimportsOnceAndRetriesWithTheFreshHeader() async {
        let slotID = UUID()
        let reimportCalls = Counter()
        let seenHeaders = HeaderLog()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in
                [.init(slotID: slotID, header: "kimi-auth=fresh", sourceLabel: "Chrome")]
            }
        )

        let results = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
        ) { resolution in
            seenHeaders.append(resolution.header)
            guard resolution.header == "kimi-auth=fresh" else { throw QuotaError.needsLogin }
            return self.quota()
        }

        XCTAssertEqual(reimportCalls.value, 1, "exactly one re-import, no loop")
        XCTAssertEqual(seenHeaders.values, ["kimi-auth=stale", "kimi-auth=fresh"])
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first?.outcome.failureError, "the retry's success should replace the failure")
    }

    /// A second `needsLogin` surfaces as `needsLogin`, and the retry does
    /// not itself trigger another re-import.
    func testRetryFailureStillSurfacesTheCredentialError() async {
        let slotID = UUID()
        let reimportCalls = Counter()
        let fetchCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in
                [.init(slotID: slotID, header: "kimi-auth=also-stale", sourceLabel: "Chrome")]
            }
        )

        let results = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
        ) { _ in
            fetchCalls.increment()
            throw QuotaError.needsLogin
        }

        XCTAssertEqual(reimportCalls.value, 1)
        XCTAssertEqual(fetchCalls.value, 2, "one original attempt plus exactly one retry")
        XCTAssertEqual(results.first?.outcome.failureError, .needsLogin)
    }

    /// A re-import that produced the same header means the browser had
    /// nothing newer — spending another request on it is pointless.
    func testUnchangedHeaderSkipsTheRetry() async {
        let slotID = UUID()
        let fetchCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in true },
            resolve: { _, _ in
                [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
            }
        )

        _ = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
        ) { _ in
            fetchCalls.increment()
            throw QuotaError.needsLogin
        }

        XCTAssertEqual(fetchCalls.value, 1)
    }

    /// A slot that resolves fresh but was never in the adapter's own
    /// resolution list (Ollama filters out slots with no recognised
    /// session cookie) must stay out of the retry.
    func testRetryIsLimitedToSlotsTheAdapterActuallyTried() async {
        let triedSlot = UUID()
        let filteredOutSlot = UUID()
        let fetchedSlotIDs = SlotIDLog()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in true },
            resolve: { _, _ in
                [
                    .init(slotID: triedSlot, header: "kimi-auth=fresh", sourceLabel: "Chrome"),
                    .init(slotID: filteredOutSlot, header: "kimi-auth=other", sourceLabel: "Safari")
                ]
            }
        )

        _ = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: triedSlot, header: "kimi-auth=stale", sourceLabel: "Chrome")]
        ) { resolution in
            fetchedSlotIDs.append(resolution.slotID)
            throw QuotaError.needsLogin
        }

        XCTAssertEqual(fetchedSlotIDs.values, [triedSlot, triedSlot])
        XCTAssertFalse(fetchedSlotIDs.values.contains(filteredOutSlot))
    }

    /// Non-credential errors are not a stale cookie; a flaky network must
    /// not be answered by rewriting the user's Keychain slot.
    func testNetworkErrorDoesNotTriggerReimport() async {
        let reimportCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in [] }
        )

        let results = await importer.gatherSlotResults(
            spec: spec,
            account: account,
            resolutions: [.init(slotID: UUID(), header: "kimi-auth=good", sourceLabel: "Chrome")]
        ) { _ in
            throw QuotaError.network("timeout")
        }

        XCTAssertEqual(reimportCalls.value, 0)
        XCTAssertEqual(results.first?.outcome.failureError, .network("timeout"))
    }

    /// A slot that is genuinely signed out stays in a credential-error state
    /// forever. Without a cooldown, every quota refresh paid for another full
    /// browser + Keychain walk that could not possibly help.
    func testSecondStaleFetchInsideTheCooldownDoesNotReimportAgain() async {
        let slotID = UUID()
        let reimportCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in
                [.init(slotID: slotID, header: "kimi-auth=also-stale", sourceLabel: "Chrome")]
            }
        )

        for _ in 0..<3 {
            _ = await importer.gatherSlotResults(
                spec: spec,
                account: account,
                resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
            ) { _ in
                throw QuotaError.needsLogin
            }
        }

        XCTAssertEqual(reimportCalls.value, 1, "one browser walk per cooldown window, not one per refresh")
    }

    /// The cooldown is per importer instance, and it is a *cooldown*, not a
    /// one-shot: once the window passes the next stale fetch tries again.
    func testReimportRunsAgainAfterTheCooldownWindow() async {
        let slotID = UUID()
        let reimportCalls = Counter()
        let importer = MiscCookieAutoImporter(
            isEnabled: { true },
            reimport: { _, _ in
                reimportCalls.increment()
                return true
            },
            resolve: { _, _ in
                [.init(slotID: slotID, header: "kimi-auth=also-stale", sourceLabel: "Chrome")]
            },
            reimportCooldown: 0
        )

        for _ in 0..<2 {
            _ = await importer.gatherSlotResults(
                spec: spec,
                account: account,
                resolutions: [.init(slotID: slotID, header: "kimi-auth=stale", sourceLabel: "Chrome")]
            ) { _ in
                throw QuotaError.needsLogin
            }
        }

        XCTAssertEqual(reimportCalls.value, 2)
    }

    func testMergeKeepsOrderAndUntouchedSlots() {
        let slotA = UUID()
        let slotB = UUID()
        let original: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: slotA, sourceLabel: "Chrome", outcome: .failure(.needsLogin)),
            .init(slotID: slotB, sourceLabel: "Safari", outcome: .failure(.rateLimited))
        ]
        let retried: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: slotA, sourceLabel: "Chrome", outcome: .success(quota()))
        ]

        let merged = MiscCookieAutoImporter.merge(original: original, retried: retried)

        XCTAssertEqual(merged.map(\.slotID), [slotA, slotB])
        XCTAssertNil(merged[0].outcome.failureError)
        XCTAssertEqual(merged[1].outcome.failureError, .rateLimited)
    }
}

// MARK: - Test helpers

/// `@Sendable` closures can't capture a mutating local, and the fetch
/// closures run inside a task group, so counters need a lock.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class HeaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [String] = []

    func append(_ header: String) {
        lock.lock()
        headers.append(header)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return headers
    }
}

private final class SlotIDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID] = []

    func append(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    var values: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

private extension Result where Success == AccountQuota, Failure == QuotaError {
    var failureError: QuotaError? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
