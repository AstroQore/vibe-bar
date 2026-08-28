import XCTest
@testable import VibeBarCore

final class CostHistoryStoreTests: XCTestCase {
    func testAuthoritativeReplacementAllowsCursorHistoryToDecreaseAndRemoveDays() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryCursorReplacement-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let store = CostHistoryStore(
            fileURL: directory.appendingPathComponent("cost_history.json"),
            timeZone: utc
        )
        let original = CostSnapshot(
            tool: .cursor,
            todayCostUSD: 9,
            last7DaysCostUSD: 13,
            last30DaysCostUSD: 13,
            allTimeCostUSD: 13,
            todayTokens: 900,
            last7DaysTokens: 1_300,
            last30DaysTokens: 1_300,
            allTimeTokens: 1_300,
            dailyHistory: [
                DailyCostPoint(date: yesterday, costUSD: 4, totalTokens: 400),
                DailyCostPoint(date: today, costUSD: 9, totalTokens: 900)
            ],
            heatmap: .empty(tool: .cursor),
            modelBreakdowns: [],
            jsonlFilesFound: 2,
            updatedAt: now
        )
        _ = await store.replaceAndAugment(
            original,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        await store.mergeSeries(
            [DailyCostPoint(date: yesterday, costUSD: 2, totalTokens: 200)],
            tool: .codex,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        let corrected = CostSnapshot(
            tool: .cursor,
            todayCostUSD: 3,
            last7DaysCostUSD: 3,
            last30DaysCostUSD: 3,
            allTimeCostUSD: 3,
            todayTokens: 300,
            last7DaysTokens: 300,
            last30DaysTokens: 300,
            allTimeTokens: 300,
            dailyHistory: [
                DailyCostPoint(date: today, costUSD: 3, totalTokens: 300)
            ],
            heatmap: .empty(tool: .cursor),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: now
        )
        let replaced = await store.replaceAndAugment(
            corrected,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(replaced.dailyHistory.count, 1)
        XCTAssertEqual(replaced.todayCostUSD, 3, accuracy: 0.001)
        XCTAssertEqual(replaced.todayTokens, 300)
        XCTAssertEqual(replaced.allTimeCostUSD, 3, accuracy: 0.001)
        XCTAssertEqual(replaced.allTimeTokens, 300)
        let codex = await store.history(
            for: .codex,
            days: nil,
            now: now,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertEqual(codex.days.first?.costUSD, 2)
        XCTAssertEqual(codex.days.first?.totalTokens, 200)
    }

    func testMergeAndAugmentPreservesHourlyHistoryAndModelDetails() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryHourlyDetails-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let todayHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 10, to: today))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let yesterdayHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 17, to: yesterday))
        let olderDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))
        let olderHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 11, to: olderDay))
        let todayModels = [
            CostSnapshot.ModelBreakdown(modelName: "gpt-today", costUSD: 1.5, totalTokens: 1_500)
        ]
        let yesterdayModels = [
            CostSnapshot.ModelBreakdown(modelName: "gpt-yesterday", costUSD: 2.5, totalTokens: 2_500)
        ]
        let snapshot = CostSnapshot(
            tool: .codex,
            todayCostUSD: 1.5,
            last7DaysCostUSD: 4,
            last30DaysCostUSD: 4,
            allTimeCostUSD: 4,
            todayTokens: 1_500,
            last7DaysTokens: 4_000,
            last30DaysTokens: 4_000,
            allTimeTokens: 4_000,
            dailyHistory: [
                DailyCostPoint(date: yesterday, costUSD: 2.5, totalTokens: 2_500),
                DailyCostPoint(date: today, costUSD: 1.5, totalTokens: 1_500)
            ],
            todayHourlyHistory: [
                HourlyCostPoint(date: todayHour, costUSD: 1.5, totalTokens: 1_500)
            ],
            yesterdayHourlyHistory: [
                HourlyCostPoint(date: yesterdayHour, costUSD: 2.5, totalTokens: 2_500)
            ],
            recentHourlyHistory: [
                HourlyCostPoint(date: olderHour, costUSD: 3.5, totalTokens: 3_500),
                HourlyCostPoint(date: yesterdayHour, costUSD: 2.5, totalTokens: 2_500),
                HourlyCostPoint(date: todayHour, costUSD: 1.5, totalTokens: 1_500)
            ],
            hourlyCoverageStart: CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar),
            heatmap: .empty(tool: .codex),
            modelBreakdowns: todayModels + yesterdayModels,
            dailyModelBreakdown: [today: todayModels, yesterday: yesterdayModels],
            hourlyModelBreakdown: [todayHour: todayModels, yesterdayHour: yesterdayModels],
            jsonlFilesFound: 1,
            updatedAt: now
        )
        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))

        let merged = await store.mergeAndAugment(
            snapshot,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(merged.todayHourlyHistory, snapshot.todayHourlyHistory)
        XCTAssertEqual(merged.yesterdayHourlyHistory, snapshot.yesterdayHourlyHistory)
        // The merge rebuilds the daily series from the store but must carry the
        // hourly window through untouched — it is live-scan-only data the store
        // never sees, and dropping it here would strand the chart on two days
        // no matter how far back the scanner reached.
        XCTAssertEqual(merged.recentHourlyHistory, snapshot.recentHourlyHistory)
        XCTAssertEqual(merged.hourlyCoverageStart, snapshot.hourlyCoverageStart)
        XCTAssertEqual(merged.topModels(forHour: todayHour, limit: .max), todayModels)
        XCTAssertEqual(merged.topModels(forHour: yesterdayHour, limit: .max), yesterdayModels)
    }

    func testMergeAndAugmentKeepsLocalTodayWhenTimeZoneIsAheadOfUTC() async throws {
        let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryLocalTodayTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = shanghai
        components.year = 2026
        components.month = 5
        components.day = 6
        components.hour = 2
        components.minute = 15
        let now = try XCTUnwrap(components.date)
        let today = calendar.startOfDay(for: now)
        let store = CostHistoryStore(
            fileURL: directory.appendingPathComponent("cost_history.json"),
            timeZone: shanghai
        )
        let snapshot = CostSnapshot(
            tool: .codex,
            todayCostUSD: 7,
            last7DaysCostUSD: 7,
            last30DaysCostUSD: 7,
            allTimeCostUSD: 7,
            todayTokens: 700,
            last7DaysTokens: 700,
            last30DaysTokens: 700,
            allTimeTokens: 700,
            dailyHistory: [DailyCostPoint(date: today, costUSD: 7, totalTokens: 700)],
            heatmap: .empty(tool: .codex),
            modelBreakdowns: [],
            last7DaysModelBreakdowns: [],
            dailyModelBreakdown: [:],
            jsonlFilesFound: 1,
            updatedAt: now
        )

        let merged = await store.mergeAndAugment(snapshot, retentionDays: CostDataSettings.unlimitedRetentionDays)

        XCTAssertEqual(merged.todayCostUSD, 7, accuracy: 0.001)
        XCTAssertEqual(merged.todayTokens, 700)
        XCTAssertEqual(merged.dailyHistory.map { calendar.component(.day, from: $0.date) }, [6])
    }

    func testLegacyUTCDateKeysMigrateToLocalDay() async throws {
        let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDateMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("cost_history.json")
        let legacyJSON = """
        {"entries":[{"tool":"codex","date":"2026-05-05","costUSD":7,"totalTokens":700}]}
        """
        try legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = shanghai
        components.year = 2026
        components.month = 5
        components.day = 6
        components.hour = 2
        let now = try XCTUnwrap(components.date)
        let store = CostHistoryStore(fileURL: url, timeZone: shanghai)

        let history = await store.history(
            for: .codex,
            days: nil,
            now: now,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(history.days.map { calendar.component(.day, from: $0.date) }, [6])
        XCTAssertEqual(history.days.first?.totalTokens, 700)
    }

    func testSecondCorrectionDropsVersionOneAntigravityHistoryButKeepsOtherTools() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryAntigravityCorrection-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        // A v1-corrected file still carries cost priced from the coarse
        // `gemini-default` alias. `calculationVersion` matches the current
        // value so the calc-version wipe doesn't fire and confound the
        // targeted v2 assertion.
        let url = directory.appendingPathComponent("cost_history.json")
        let json = """
        {"schemaVersion":2,"calculationVersion":\(CostUsagePricing.calculationVersion),"historyCorrectionVersion":1,"entries":[\
        {"tool":"antigravity","date":"2026-05-28","costUSD":45.36,"totalTokens":395000000},\
        {"tool":"codex","date":"2026-05-28","costUSD":1.5,"totalTokens":1000}]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let store = CostHistoryStore(fileURL: url)
        let antigravity = await store.history(
            for: .antigravity, days: nil, retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let codex = await store.history(
            for: .codex, days: nil, retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertTrue(antigravity.days.isEmpty, "stuck antigravity history should be cleared once")
        XCTAssertEqual(codex.days.count, 1, "other tools' history must be preserved")
        XCTAssertEqual(codex.days.first?.totalTokens, 1000)
    }

    func testRetentionPrunesOldHistory() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        let recent = now.addingTimeInterval(-3 * 86_400)

        await store.mergeSeries(
            [
                DailyCostPoint(date: old, costUSD: 12, totalTokens: 1200),
                DailyCostPoint(date: recent, costUSD: 3, totalTokens: 300)
            ],
            tool: .codex,
            retentionDays: 30
        )
        await store.flushPendingWrites()

        let history = await store.history(for: .codex, days: nil, now: now, retentionDays: 30)
        XCTAssertEqual(history.days.count, 1)
        XCTAssertFalse(history.days.contains { $0.costUSD == 12 })
        XCTAssertTrue(history.days.contains { $0.costUSD == 3 })
    }

    func testMergeAndAugmentRebuildsCurrentSchemaHistoryWithoutCalculationVersion() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryCalculationVersionTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let utc = TimeZone(secondsFromGMT: 0)!

        let url = directory.appendingPathComponent("cost_history.json")
        let legacyCurrentSchemaJSON = """
        {"schemaVersion":2,"entries":[{"tool":"claude","date":"2026-05-06","costUSD":999,"totalTokens":999999}]}
        """
        try legacyCurrentSchemaJSON.write(to: url, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let store = CostHistoryStore(fileURL: url, timeZone: utc)
        let fresh = CostSnapshot(
            tool: .claude,
            todayCostUSD: 1,
            last7DaysCostUSD: 1,
            last30DaysCostUSD: 1,
            allTimeCostUSD: 1,
            todayTokens: 100,
            last7DaysTokens: 100,
            last30DaysTokens: 100,
            allTimeTokens: 100,
            dailyHistory: [DailyCostPoint(date: today, costUSD: 1, totalTokens: 100)],
            heatmap: .empty(tool: .claude),
            modelBreakdowns: [],
            last7DaysModelBreakdowns: [],
            dailyModelBreakdown: [:],
            jsonlFilesFound: 1,
            updatedAt: now
        )

        let merged = await store.mergeAndAugment(fresh, retentionDays: CostDataSettings.unlimitedRetentionDays)

        XCTAssertEqual(merged.todayCostUSD, 1, accuracy: 0.001)
        XCTAssertEqual(merged.todayTokens, 100)
    }

    func testUnlimitedRetentionKeepsAllStoredHistory() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryForeverTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))
        let now = Date()
        let old = now.addingTimeInterval(-800 * 86_400)
        let recent = now.addingTimeInterval(-3 * 86_400)

        await store.mergeSeries(
            [
                DailyCostPoint(date: old, costUSD: 12, totalTokens: 1200),
                DailyCostPoint(date: recent, costUSD: 3, totalTokens: 300)
            ],
            tool: .codex,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        await store.flushPendingWrites()

        let history = await store.history(
            for: .codex,
            days: nil,
            now: now,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertEqual(history.days.map(\.costUSD), [12, 3])
    }

    func testEraseAllDeletesPersistedHistory() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryEraseTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("cost_history.json")
        let store = CostHistoryStore(fileURL: url)

        await store.mergeSeries(
            [DailyCostPoint(date: Date(), costUSD: 1, totalTokens: 100)],
            tool: .claude,
            retentionDays: 30
        )
        await store.flushPendingWrites()
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))

        await store.eraseAll()

        XCTAssertFalse(fileManager.fileExists(atPath: url.path))
        let history = await store.history(for: .claude, days: nil, retentionDays: 30)
        XCTAssertTrue(history.days.isEmpty)
    }

    // MARK: - Per-day model persistence

    private func snapshot(
        tool: ToolType,
        dailyHistory: [DailyCostPoint],
        dailyModels: [Date: [CostSnapshot.ModelBreakdown]],
        now: Date
    ) -> CostSnapshot {
        let cost = dailyHistory.reduce(0) { $0 + $1.costUSD }
        let tokens = dailyHistory.reduce(0) { $0 + $1.totalTokens }
        return CostSnapshot(
            tool: tool,
            todayCostUSD: dailyHistory.last?.costUSD ?? 0,
            last7DaysCostUSD: cost,
            last30DaysCostUSD: cost,
            allTimeCostUSD: cost,
            todayTokens: dailyHistory.last?.totalTokens ?? 0,
            last7DaysTokens: tokens,
            last30DaysTokens: tokens,
            allTimeTokens: tokens,
            dailyHistory: dailyHistory,
            heatmap: .empty(tool: tool),
            modelBreakdowns: [],
            dailyModelBreakdown: dailyModels,
            jsonlFilesFound: 1,
            updatedAt: now
        )
    }

    func testPersistedDayModelsBackfillDaysTheLiveScanNoLongerSees() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDayModels-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let yesterdayModels = [
            CostSnapshot.ModelBreakdown(modelName: "Gemini 3.7 Flash (High)", costUSD: 2.5, totalTokens: 2_500)
        ]
        let todayModels = [
            CostSnapshot.ModelBreakdown(modelName: "Gemini 3.7 Pro", costUSD: 1.5, totalTokens: 1_500)
        ]
        let url = directory.appendingPathComponent("cost_history.json")
        let store = CostHistoryStore(fileURL: url)

        _ = await store.mergeAndAugment(
            snapshot(
                tool: .antigravity,
                dailyHistory: [
                    DailyCostPoint(date: yesterday, costUSD: 2.5, totalTokens: 2_500),
                    DailyCostPoint(date: today, costUSD: 1.5, totalTokens: 1_500)
                ],
                dailyModels: [yesterday: yesterdayModels, today: todayModels],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        await store.flushPendingWrites()

        // Second launch: the source logs for yesterday rotated away, so the
        // live scan only knows about today. A fresh store instance forces the
        // models through the encode/decode round trip.
        let reopened = CostHistoryStore(fileURL: url)
        let merged = await reopened.mergeAndAugment(
            snapshot(
                tool: .antigravity,
                dailyHistory: [DailyCostPoint(date: today, costUSD: 1.6, totalTokens: 1_600)],
                dailyModels: [today: [
                    CostSnapshot.ModelBreakdown(modelName: "Gemini 3.7 Pro", costUSD: 1.6, totalTokens: 1_600)
                ]],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(merged.topModels(for: yesterday, limit: .max), yesterdayModels)
        XCTAssertEqual(merged.topModels(for: today, limit: .max).first?.costUSD ?? 0, 1.6, accuracy: 0.001)
    }

    func testDayModelsFollowWhicheverScanWinsTheTokenMax() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDayModelsMax-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))
        let fullView = [
            CostSnapshot.ModelBreakdown(modelName: "model-full", costUSD: 3, totalTokens: 3_000)
        ]

        _ = await store.mergeAndAugment(
            snapshot(
                tool: .antigravity,
                dailyHistory: [DailyCostPoint(date: today, costUSD: 3, totalTokens: 3_000)],
                dailyModels: [today: fullView],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        // A later partial scan (some files already rotated) loses the token
        // max, so its thinner model mix must not overwrite the stored one.
        let afterPartial = await store.mergeAndAugment(
            snapshot(
                tool: .antigravity,
                dailyHistory: [DailyCostPoint(date: today, costUSD: 1, totalTokens: 1_000)],
                dailyModels: [today: [
                    CostSnapshot.ModelBreakdown(modelName: "model-partial", costUSD: 1, totalTokens: 1_000)
                ]],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(afterPartial.topModels(for: today, limit: .max).map(\.modelName), ["model-partial"])
        // The augmented snapshot keeps the live scan's view for days it saw;
        // the persisted entry is what must still hold the full mix.
        let reopened = await store.mergeAndAugment(
            snapshot(tool: .antigravity, dailyHistory: [], dailyModels: [:], now: now),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertEqual(reopened.topModels(for: today, limit: .max), fullView)
    }

    func testReplaceSeriesCarriesDayModelsAndCapsThem() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDayModelsCap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let manyModels = (0..<12).map {
            CostSnapshot.ModelBreakdown(modelName: "model-\($0)", costUSD: Double(12 - $0), totalTokens: 100)
        }
        let url = directory.appendingPathComponent("cost_history.json")
        let store = CostHistoryStore(fileURL: url)

        _ = await store.replaceAndAugment(
            snapshot(
                tool: .cursor,
                dailyHistory: [DailyCostPoint(date: today, costUSD: 78, totalTokens: 1_200)],
                dailyModels: [today: manyModels],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        await store.flushPendingWrites()

        let reopened = CostHistoryStore(fileURL: url)
        let augmented = await reopened.mergeAndAugment(
            snapshot(tool: .cursor, dailyHistory: [], dailyModels: [:], now: now),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let models = augmented.topModels(for: today, limit: .max)
        XCTAssertEqual(models.count, 8, "persisted per-day models should be capped")
        XCTAssertEqual(models.map(\.modelName), (0..<8).map { "model-\($0)" }, "cap keeps the top models by cost")
    }

    func testBackfillFillsOnlyDaysWithoutModels() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDayModelsBackfill-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let bareDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -20, to: today))
        let scannedModels = [
            CostSnapshot.ModelBreakdown(modelName: "model-scanned", costUSD: 1.5, totalTokens: 1_500)
        ]
        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))

        // One day with a scanned mix, one recorded before models existed.
        _ = await store.mergeAndAugment(
            snapshot(
                tool: .antigravity,
                dailyHistory: [
                    DailyCostPoint(date: bareDay, costUSD: 4, totalTokens: 4_000),
                    DailyCostPoint(date: today, costUSD: 1.5, totalTokens: 1_500)
                ],
                dailyModels: [today: scannedModels],
                now: now
            ),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let bareKey = formatter.string(from: bareDay)
        let todayKey = formatter.string(from: today)

        let missing = await store.daysMissingModels(tool: .antigravity)
        XCTAssertEqual(missing, [bareKey], "only the pre-models day should report as missing")

        await store.backfillDayModels(tool: .antigravity, modelsByDay: [
            bareKey: [CostSnapshot.ModelBreakdown(modelName: "model-ledger", costUSD: 4, totalTokens: 4_000)],
            todayKey: [CostSnapshot.ModelBreakdown(modelName: "model-wrong", costUSD: 9, totalTokens: 9_000)]
        ])

        let augmented = await store.mergeAndAugment(
            snapshot(tool: .antigravity, dailyHistory: [], dailyModels: [:], now: now),
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        XCTAssertEqual(
            augmented.topModels(for: bareDay, limit: .max).map(\.modelName),
            ["model-ledger"]
        )
        XCTAssertEqual(
            augmented.topModels(for: today, limit: .max), scannedModels,
            "backfill must never overwrite a scanned mix"
        )
        let stillMissing = await store.daysMissingModels(tool: .antigravity)
        XCTAssertTrue(stillMissing.isEmpty)
    }

    func testEntriesWithoutModelsStillDecode() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostHistoryDayModelsLegacy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let url = directory.appendingPathComponent("cost_history.json")
        let json = """
        {"schemaVersion":2,"calculationVersion":\(CostUsagePricing.calculationVersion),"historyCorrectionVersion":2,"entries":[\
        {"tool":"codex","date":"2026-05-28","costUSD":1.5,"totalTokens":1000}]}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let store = CostHistoryStore(fileURL: url)
        let history = await store.history(
            for: .codex, days: nil, retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(history.days.count, 1)
        XCTAssertEqual(history.days.first?.totalTokens, 1000)
    }
}
