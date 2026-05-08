import XCTest
@testable import VibeBarCore

final class CostHistoryStoreTests: XCTestCase {
    func testMergeAndAugmentKeepsLocalTodayWhenTimeZoneIsAheadOfUTC() async throws {
        let previousTimeZone = NSTimeZone.default
        let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!
        NSTimeZone.default = shanghai
        defer { NSTimeZone.default = previousTimeZone }

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
        let store = CostHistoryStore(fileURL: directory.appendingPathComponent("cost_history.json"))
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
        let previousTimeZone = NSTimeZone.default
        let shanghai = TimeZone(secondsFromGMT: 8 * 3600)!
        NSTimeZone.default = shanghai
        defer { NSTimeZone.default = previousTimeZone }

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
        let store = CostHistoryStore(fileURL: url)

        let history = await store.history(
            for: .codex,
            days: nil,
            now: now,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(history.days.map { calendar.component(.day, from: $0.date) }, [6])
        XCTAssertEqual(history.days.first?.totalTokens, 700)
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

        let previousTimeZone = NSTimeZone.default
        let utc = TimeZone(secondsFromGMT: 0)!
        NSTimeZone.default = utc
        defer { NSTimeZone.default = previousTimeZone }

        let url = directory.appendingPathComponent("cost_history.json")
        let legacyCurrentSchemaJSON = """
        {"schemaVersion":2,"entries":[{"tool":"claude","date":"2026-05-06","costUSD":999,"totalTokens":999999}]}
        """
        try legacyCurrentSchemaJSON.write(to: url, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let store = CostHistoryStore(fileURL: url)
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
}
