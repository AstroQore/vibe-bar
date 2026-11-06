import XCTest
@testable import VibeBarCore

final class OllamaQuotaAdapterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let account = AccountIdentity(id: "ollama-fixture", tool: .ollama, source: .browserCookie)
    private let firstSlot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondSlot = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // Shapes from CodexBar's public settings fixtures. Values are synthetic.
    private let wallet = """
    <section>
      <div>
        <h2>Usage credits<span>pro</span></h2>
        <span>$12.34</span>
        <p>Refills to $70 in 3 weeks</p>
      </div>
      <div><span>Monthly credits used</span><span>$5.67</span></div>
    </section>
    """

    func testMonthlyIncludedCreditsUseReportedDenominatorAndReset() throws {
        let html = """
        <h2><span>Included usage</span><span>pro</span
        ></h2>
        <div><span>Monthly usage</span><span>$1,250 of $5,000 used</span></div>
        <div data-usage-meter><div style="width: 23%;"></div></div>
        <div class="local-time" data-time="2026-11-30T15:14:29Z">Resets in 3 weeks</div>
        <section><span>Weekly usage</span><span>80% used</span></section>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.planName, "pro")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.monthly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 25)
        XCTAssertEqual(snapshot.buckets[0].resetAt, ISO8601DateFormatter().date(from: "2026-11-30T15:14:29Z"))
    }

    func testFreeMonthlyMeterPreservesFractionAndLeavesResetMissing() throws {
        let html = """
        <h2><span>Included usage</span><span>Free</span></h2>
        <p>Free usage credits can be used for these models.</p>
        <div><span>Free usage</span><span>0.5% used</span></div>
        <div data-time="2026-11-30T13:00:00Z">Payment received</div>
        <h2>Billing</h2>
        <time data-time="2026-11-30T15:14:29Z"></time>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.monthly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 0.5)
        XCTAssertNil(snapshot.buckets[0].resetAt)
    }

    func testMonthlyZeroAllowanceCanUseReportedMeter() throws {
        let html = """
        <span>Monthly usage</span><span>$0 of $0 used</span>
        <div data-usage-meter><div style="width: 2.5%;"></div></div>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.monthly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 2.5)
    }

    func testMalformedMonthlyAndMissingSessionDoNotBorrowWeeklyMeter() throws {
        let html = """
        <div><span>Monthly usage</span><span>$1,25 of $60 used</span></div>
        <div><span>Session usage</span></div>
        <div><span>Weekly usage</span><div aria-valuenow="64"></div></div>
        <time data-time="2026-11-30T15:14:29Z"></time>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.weekly"])
        XCTAssertEqual(snapshot.buckets[0].usedPercent, 64)
    }

    func testLegacySessionWithoutResetDoesNotBorrowWeeklyDate() throws {
        let html = """
        <span>Cloud Usage</span><span>Max</span>
        <span>Session usage</span><span>0.1% used</span>
        <span>Weekly usage</span><span>72% used</span>
        <time data-time="2026-11-30T15:14:29Z"></time>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.planName, "Max")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.fiveHour", "ollama.weekly"])
        XCTAssertEqual(snapshot.buckets.map(\.usedPercent), [0.1, 72])
        XCTAssertNil(snapshot.buckets[0].resetAt)
        XCTAssertEqual(snapshot.buckets[1].resetAt, ISO8601DateFormatter().date(from: "2026-11-30T15:14:29Z"))
    }

    func testWalletDoesNotInventPercentageOrExactResetFromRefill() throws {
        let snapshot = try OllamaResponseParser.parse(html: wallet, now: now)

        XCTAssertEqual(snapshot.planName, "pro")
        XCTAssertEqual(snapshot.credits?.balanceUSD, 12.34)
        XCTAssertEqual(snapshot.credits?.monthlyUsedUSD, 5.67)
        XCTAssertEqual(snapshot.credits?.refillText, "Refills to $70 in 3 weeks")
        XCTAssertTrue(snapshot.buckets.isEmpty)
    }

    func testMixedSlotsChooseOneCompleteAccountInSavedOrder() throws {
        let legacy = try quota(for: legacyHTML(percent: 25))
        let wallet = try quota(for: self.wallet + #"<div id="header-email">wallet@example.com</div>"#)
        let results: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: firstSlot, sourceLabel: "Saved first", outcome: .success(legacy)),
            .init(slotID: secondSlot, sourceLabel: "Saved second", outcome: .success(wallet)),
        ]

        for completions in [results, Array(results.reversed())] {
            XCTAssertEqual(resolve(completions, slotOrder: [firstSlot, secondSlot]), legacy)
            XCTAssertEqual(resolve(completions, slotOrder: [secondSlot, firstSlot]), wallet)
        }
    }

    func testTwoWalletsAreStableForSavedAndNewlyImportedSlots() throws {
        let first = try quota(for: wallet)
        let second = try quota(for: wallet.replacingOccurrences(of: "$12.34", with: "$75.00"))
        let results: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: firstSlot, sourceLabel: "First browser", outcome: .success(first)),
            .init(slotID: secondSlot, sourceLabel: "Second browser", outcome: .success(second)),
        ]

        for completions in [results, Array(results.reversed())] {
            XCTAssertEqual(resolve(completions, slotOrder: [secondSlot, firstSlot]), second)
            XCTAssertEqual(resolve(completions, slotOrder: []), first)
        }
    }

    func testFailedPreferredSlotFallsBackToWalletAndPreservesItThroughCacheAndMCP() throws {
        let wallet = try quota(for: self.wallet + #"<div id="header-email">wallet@example.com</div>"#)
        let results: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: secondSlot, sourceLabel: "Saved second", outcome: .success(wallet)),
            .init(slotID: firstSlot, sourceLabel: "Saved first", outcome: .failure(.needsLogin)),
        ]
        let selected = resolve(results, slotOrder: [firstSlot, secondSlot])
        XCTAssertEqual(selected, wallet)
        XCTAssertEqual(selected.email, "wallet@example.com")

        let data = try JSONEncoder().encode(QuotaCacheStore.StoredQuota(selected))
        let cached = try JSONDecoder().decode(QuotaCacheStore.StoredQuota.self, from: data).quota(accountId: account.id)
        let dto = MCPQuotaAccountDTO(quota: cached, lastUpdated: now, lastAttempted: now, inFlight: false, error: nil)
        let wire = try JSONDecoder().decode(MCPQuotaAccountDTO.self, from: JSONEncoder().encode(dto))

        XCTAssertTrue(cached.hasUsageData)
        XCTAssertNil(cached.email)
        XCTAssertEqual(wire.plan, "pro")
        XCTAssertTrue(wire.buckets.isEmpty)
        XCTAssertEqual(wire.ollamaCredits?.balanceUSD, 12.34)
        XCTAssertEqual(wire.ollamaCredits?.monthlyUsedUSD, 5.67)
        XCTAssertEqual(wire.ollamaCredits?.refillText, "Refills to $70 in 3 weeks")
    }

    func testLegacyOnlySlotsStillAverageMatchingWindows() throws {
        let first = try quota(for: legacyHTML(percent: 20))
        let second = try quota(for: legacyHTML(percent: 80))
        let results: [MiscQuotaAggregator.SlotResult] = [
            .init(slotID: secondSlot, sourceLabel: "Saved second", outcome: .success(second)),
            .init(slotID: firstSlot, sourceLabel: "Saved first", outcome: .success(first)),
        ]

        let selected = resolve(results, slotOrder: [firstSlot, secondSlot])

        XCTAssertNil(selected.ollamaCredits)
        XCTAssertEqual(selected.buckets.map(\.id), ["ollama.fiveHour"])
        XCTAssertEqual(selected.buckets.map(\.usedPercent), [50])
    }

    func testZeroBalanceCanCoexistWithMonthlyQuota() throws {
        let html = wallet.replacingOccurrences(of: "$12.34", with: "$0.00") + """
        <section><span>Monthly usage</span><span>$5.67 of $10.00 used</span></section>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertEqual(snapshot.credits?.balanceUSD, 0)
        XCTAssertEqual(snapshot.buckets.map(\.id), ["ollama.monthly"])
        XCTAssertEqual(try XCTUnwrap(snapshot.buckets.first).usedPercent, 56.7, accuracy: 0.0001)
    }

    func testWalletDoesNotBorrowBalanceFromMonthlySpendOrAdjacentSection() throws {
        let html = """
        <section>
          <h2>Usage credits<span>pro</span></h2>
          <span>Monthly credits used</span><span>$5.67</span>
        </section>
        <section><span>$99.00</span><p>Refills to $99 in 3 weeks.</p></section>
        """

        let snapshot = try OllamaResponseParser.parse(html: html, now: now)

        XCTAssertNil(snapshot.credits?.balanceUSD)
        XCTAssertEqual(snapshot.credits?.monthlyUsedUSD, 5.67)
        XCTAssertNil(snapshot.credits?.refillText)
        XCTAssertTrue(snapshot.buckets.isEmpty)
    }

    func testRefillWithoutBalanceOrUsageDoesNotCreateQuota() {
        let html = """
        <section><h2>Usage credits<span>pro</span></h2><p>Refills to $70 in 3 weeks.</p></section>
        """
        XCTAssertThrowsError(try OllamaResponseParser.parse(html: html, now: now)) {
            guard case QuotaError.parseFailure = $0 else { return XCTFail("Expected a parse failure") }
        }
    }

    func testSignedOutClassificationIgnoresNavigationLinkOnSettingsPage() throws {
        let html = #"<a href="/signin">Sign in</a>"# + wallet
        XCTAssertEqual(try OllamaResponseParser.parse(html: html, now: now).credits?.balanceUSD, 12.34)

        XCTAssertThrowsError(try OllamaResponseParser.parse(html: "<h1>Sign in to Ollama</h1>", now: now)) {
            XCTAssertEqual($0 as? QuotaError, .needsLogin)
        }
    }

    func testRecognizesWorkOSAndLegacyCookiesAndLoginDestinations() {
        XCTAssertTrue(OllamaQuotaAdapter.hasRecognizedSessionCookie("wos-session=fixture; other=x"))
        XCTAssertTrue(OllamaQuotaAdapter.hasRecognizedSessionCookie("__Secure-session=fixture"))
        XCTAssertTrue(OllamaQuotaAdapter.hasRecognizedSessionCookie("next-auth.session-token.1=fixture"))
        XCTAssertFalse(OllamaQuotaAdapter.hasRecognizedSessionCookie("wos-session-backup=fixture"))
        XCTAssertFalse(OllamaQuotaAdapter.hasRecognizedSessionCookie("wos-session=; other=x"))

        for url in [
            "https://ollama.com/signin",
            "https://signin.ollama.com/",
            "https://api.workos.com/user_management/authorize",
        ] {
            XCTAssertTrue(OllamaQuotaAdapter.isSignInURL(URL(string: url)))
        }
        XCTAssertFalse(OllamaQuotaAdapter.isSignInURL(URL(string: "https://ollama.com/settings")))
        XCTAssertFalse(OllamaQuotaAdapter.isSignInURL(URL(string: "https://api.workos.com.example.com/user_management/authorize")))
    }
    private func legacyHTML(percent: Int) -> String {
        """
        <div id="header-email">legacy@example.com</div>
        <span>Cloud Usage</span><span>Max</span>
        <span>Session usage</span><span>\(percent)% used</span>
        """
    }

    private func quota(for html: String) throws -> AccountQuota {
        let snapshot = try OllamaResponseParser.parse(html: html, now: now)
        return AccountQuota(
            accountId: account.id,
            tool: .ollama,
            buckets: snapshot.buckets,
            plan: snapshot.planName,
            email: snapshot.email,
            queriedAt: now,
            providerExtras: snapshot.credits.map {
                ProviderExtras(tool: .ollama, updatedAt: now, ollamaCredits: $0)
            }
        )
    }

    private func resolve(_ results: [MiscQuotaAggregator.SlotResult], slotOrder: [UUID]) -> AccountQuota {
        OllamaQuotaAdapter.resolveSlotResults(results, slotOrder: slotOrder, account: account, queriedAt: now)
    }
}
