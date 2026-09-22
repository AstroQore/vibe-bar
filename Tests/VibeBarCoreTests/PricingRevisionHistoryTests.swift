import XCTest
@testable import VibeBarCore

/// A price correction has to reach costs already recorded, not only new
/// requests: the usage ledger reprices its detail rows in place, and the
/// per-day deltas it reports lower the max-merged cost history that a
/// re-scan alone can never lower. Synthetic rates and paths throughout.
final class PricingRevisionHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_121_600)

    override func tearDown() {
        PricingResolver.testOverride = nil
        super.tearDown()
    }

    /// Portkey's standalone `codex-auto-review` card: no cache-read rate, so
    /// every cached token bills at the full input rate.
    private let portkeyCard = PricingDataSet.CodexEntry(
        input: 2.5e-6, output: 15e-6, cacheRead: nil
    )
    private let lunaCard = PricingDataSet.CodexEntry(
        input: 0.2e-6, output: 1.2e-6, cacheRead: 0.02e-6, cacheCreation: 0.25e-6,
        thresholdTokens: 272_000,
        inputAboveThreshold: 0.4e-6, outputAboveThreshold: 1.8e-6,
        cacheReadAboveThreshold: 0.04e-6, cacheCreationAboveThreshold: 0.5e-6,
        fastMultiplier: 2
    )

    private func table(autoReview: PricingDataSet.CodexEntry) -> PricingDataSet {
        let base = PricingHardcoded.fallback
        var codex = base.providers.codex.models
        codex["gpt-5.6-luna"] = lunaCard
        codex["codex-auto-review"] = autoReview
        return PricingDataSet(
            schemaVersion: base.schemaVersion,
            updatedAt: "test-auto-review",
            calculationVersion: base.calculationVersion,
            providers: .init(
                codex: .init(displayName: "OpenAI", models: codex),
                claude: base.providers.claude,
                gemini: base.providers.gemini,
                grok: base.providers.grok,
                antigravity: base.providers.antigravity
            )
        )
    }

    func testCorrectedAutoReviewPriceRepricesLedgerRowsAndLowersStoredHistory() async throws {
        let (ledger, directory) = try UsageLedgerFixtures.makeLedger("AutoReviewRepricing")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Recorded while Portkey's card was in force.
        PricingResolver.testOverride = table(autoReview: portkeyCard)
        let initial = try await ledger.repriceForPricingRevision("portkey-card")
        XCTAssertEqual(initial, [])

        let requestDate = now.addingTimeInterval(-2 * 86_400)
        let events = (0..<2).map { index in
            UsageLedgerFixtures.event(
                date: requestDate.addingTimeInterval(Double(index) * 60),
                model: "codex-auto-review",
                input: 100_000, output: 10_000, cache: 200_000,
                requestId: "auto-review-\(index)"
            )
        }
        let lunaEvent = UsageLedgerFixtures.event(
            date: requestDate.addingTimeInterval(600),
            model: "gpt-5.6-luna",
            input: 100_000, output: 10_000, cache: 200_000,
            requestId: "luna-0"
        )
        // Every input token at $2.50/M, cached or not: 300k × $2.50/M +
        // 10k × $15/M = $0.90 per request.
        let oldAutoReviewCost = 0.90
        // 100k × $0.20/M + 200k × $0.02/M + 10k × $1.20/M = $0.036, all
        // below the 272k long-context threshold.
        let lunaCost = 0.036
        try await ledger.ingest(UsageLedgerFixtures.batch(
            path: "/Users/example/.codex/sessions/auto-review.jsonl",
            events: events.map { UsageLedgerFixtures.priced($0, costUSD: oldAutoReviewCost) }
                + [UsageLedgerFixtures.priced(lunaEvent, costUSD: lunaCost)]
        ))

        let filter = UsageLedgerFixtures.wideFilter(around: now, models: ["codex-auto-review"])
        let before = try await ledger.summary(filter)
        XCTAssertEqual(before.costMicros, 1_800_000)

        // The day as the cost cards hold it after max-merging the scans.
        let history = CostHistoryStore(
            fileURL: directory.appendingPathComponent("cost_history.json")
        )
        let day = Calendar.current.startOfDay(for: requestDate)
        let dayTokens = 3 * 310_000
        await history.mergeSeries(
            [DailyCostPoint(date: day, costUSD: 2 * oldAutoReviewCost + lunaCost, totalTokens: dayTokens)],
            tool: .codex,
            retentionDays: CostDataSettings.unlimitedRetentionDays,
            dailyModels: [day: [
                .init(modelName: "codex-auto-review", costUSD: 2 * oldAutoReviewCost, totalTokens: 620_000),
                .init(modelName: "gpt-5.6-luna", costUSD: lunaCost, totalTokens: 310_000),
            ]]
        )

        // The supplement's correction lands: Auto Review now bills as Luna.
        PricingResolver.testOverride = table(autoReview: lunaCard)
        let changes = try await ledger.repriceForPricingRevision("luna-card")
        let change = try XCTUnwrap(changes?.first)
        XCTAssertEqual(changes?.count, 1, "the unchanged Luna row reports nothing")
        XCTAssertEqual(change.tool, .codex)
        XCTAssertEqual(change.model, "codex-auto-review")
        XCTAssertEqual(change.deltaUSD, 2 * (lunaCost - oldAutoReviewCost), accuracy: 1e-9)

        let after = try await ledger.summary(filter)
        XCTAssertEqual(after.costMicros, 72_000)
        let repeated = try await ledger.repriceForPricingRevision("luna-card")
        XCTAssertNil(repeated, "an unchanged revision is a no-op")

        let changed = await history.applyPricingRevision(try XCTUnwrap(changes))
        XCTAssertTrue(changed)
        // A later scan at the corrected price max-merges without undoing it.
        await history.mergeSeries(
            [DailyCostPoint(date: day, costUSD: 3 * lunaCost, totalTokens: dayTokens)],
            tool: .codex,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let stored = await history.history(
            for: .codex, now: now, retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let point = try XCTUnwrap(stored.days.first { $0.date == day })
        XCTAssertEqual(point.costUSD, 3 * lunaCost, accuracy: 1e-9)

        let snapshot = await history.mergeAndAugment(
            CostSnapshot(
                tool: .codex,
                todayCostUSD: 0, last7DaysCostUSD: 0, last30DaysCostUSD: 0, allTimeCostUSD: 0,
                todayTokens: 0, last7DaysTokens: 0, last30DaysTokens: 0, allTimeTokens: 0,
                dailyHistory: [],
                heatmap: .empty(tool: .codex),
                modelBreakdowns: [],
                jsonlFilesFound: 0,
                updatedAt: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let models = try XCTUnwrap(snapshot.dailyModelBreakdown[day])
        XCTAssertEqual(
            models.first { $0.modelName == "codex-auto-review" }?.costUSD ?? -1,
            2 * lunaCost, accuracy: 1e-9
        )
    }

    func testHistoryIgnoresDaysItDoesNotHoldAndNeverGoesNegative() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarRepricingHistory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let history = CostHistoryStore(
            fileURL: directory.appendingPathComponent("cost_history.json"), timeZone: utc
        )
        let day = calendar.startOfDay(for: now)
        await history.mergeSeries(
            [DailyCostPoint(date: day, costUSD: 1, totalTokens: 10)],
            tool: .codex,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: day)

        let changed = await history.applyPricingRevision([
            .init(tool: .codex, day: key, model: "codex-auto-review", deltaUSD: -5),
            .init(tool: .claude, day: key, model: "claude-x", deltaUSD: -1),
            .init(tool: .codex, day: "2000-01-01", model: "codex-auto-review", deltaUSD: 3),
        ])
        XCTAssertTrue(changed)
        let codex = await history.history(
            for: .codex, now: now, retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertEqual(codex.days.map(\.costUSD), [0])
        let claude = await history.history(
            for: .claude, now: now, retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertTrue(claude.days.isEmpty)
        let noOp = await history.applyPricingRevision([])
        XCTAssertFalse(noOp)
    }
}
