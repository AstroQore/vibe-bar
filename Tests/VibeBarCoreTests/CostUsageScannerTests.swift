import XCTest
@testable import VibeBarCore

final class CostUsageScannerTests: XCTestCase {
    func testCodexModelBreakdownsSplitSevenDayTopFromAllTimeRanking() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageScannerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        let recentDate = now.addingTimeInterval(-86_400)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: oldDate, model: "gpt-5", input: 8_000_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: recentDate, model: "gpt-5-mini", input: 8_200_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.modelBreakdowns.map(\.modelName), ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(snapshot?.last7DaysModelBreakdowns.map(\.modelName), ["gpt-5-mini"])
        XCTAssertGreaterThan(snapshot?.modelBreakdowns.first?.costUSD ?? 0, snapshot?.last7DaysModelBreakdowns.first?.costUSD ?? .infinity)
    }

    func testCodexScanHonorsRetentionWindow() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageRetentionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let oldDate = now.addingTimeInterval(-20 * 86_400)
        let recentDate = now.addingTimeInterval(-2 * 86_400)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: oldDate, model: "gpt-5", input: 8_000_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: recentDate, model: "gpt-5-mini", input: 8_200_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(
            tool: .codex,
            homeDirectory: home.path,
            now: now,
            retentionDays: 7
        )

        XCTAssertEqual(snapshot?.dailyHistory.count, 1)
        XCTAssertEqual(snapshot?.dailyHistory.first?.totalTokens, 200_000)
        XCTAssertEqual(snapshot?.allTimeTokens, 200_000)
        XCTAssertEqual(snapshot?.modelBreakdowns.map(\.modelName), ["gpt-5-mini"])
    }

    func testCodexScanBuildsTodayHourlyHistory() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageHourlyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 6, hour: 20)))
        let today = calendar.startOfDay(for: now)
        let morning = try XCTUnwrap(calendar.date(byAdding: .hour, value: 9, to: today))
        let afternoon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 15, to: today))
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let lines = [
            codexTokenCountLine(timestamp: morning, model: "gpt-5", input: 100_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: afternoon, model: "gpt-5", input: 300_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)
        let byHour = Dictionary(uniqueKeysWithValues: snapshot.todayHourlyHistory.map {
            (calendar.component(.hour, from: $0.date), $0.totalTokens)
        })

        XCTAssertEqual(snapshot.todayHourlyHistory.count, 21)
        XCTAssertEqual(byHour[9], 100_000)
        XCTAssertEqual(byHour[15], 200_000)
        XCTAssertEqual(snapshot.todayHourlyHistory.reduce(0) { $0 + $1.totalTokens }, 300_000)
    }

    /// The reason Auto's new Hour step is reachable at all: hourly buckets now
    /// span the whole retention window, not just yesterday and today.
    func testCodexScanKeepsHourlyBucketsAcrossTheRetentionWindow() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageRecentHourly-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 20)))
        let today = calendar.startOfDay(for: now)
        // Four days back is inside the window and well past yesterday; twenty
        // days back is outside it.
        let inWindow = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 10, to: calendar.date(byAdding: .day, value: -4, to: today)!)
        )
        let outOfWindow = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 10, to: calendar.date(byAdding: .day, value: -20, to: today)!)
        )
        let lines = [
            codexTokenCountLine(timestamp: outOfWindow, model: "gpt-5", input: 100_000, cached: 0, output: 0),
            codexTokenCountLine(timestamp: inWindow, model: "gpt-5", input: 300_000, cached: 0, output: 0)
        ]
        try lines.joined(separator: "\n").write(
            to: sessions.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)

        XCTAssertEqual(
            snapshot.hourlyCoverageStart,
            CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar)
        )
        let recentByHour = Dictionary(
            uniqueKeysWithValues: snapshot.recentHourlyHistory.map { ($0.date, $0.totalTokens) }
        )
        XCTAssertEqual(recentByHour[inWindow], 200_000)
        XCTAssertNil(recentByHour[outOfWindow], "a bucket outside the window must not be retained")
        // Days with spend are zero-filled whole, so the line dips between
        // sessions instead of cutting a diagonal across the idle hours.
        XCTAssertEqual(
            snapshot.recentHourlyHistory.filter { calendar.isDate($0.date, inSameDayAs: inWindow) }.count,
            24
        )
        // Model detail follows the buckets, or the inspector would go blank for
        // every hour older than yesterday.
        XCTAssertEqual(snapshot.topModels(forHour: inWindow, limit: .max).count, 1)
        XCTAssertTrue(snapshot.topModels(forHour: outOfWindow, limit: .max).isEmpty)
    }

    /// Idle days inside the window carry no buckets — `hourlyCoverageStart` is
    /// what says they were scanned — but today and yesterday are always drawn,
    /// so a chart opened on a quiet morning still reads as covered.
    func testCodexScanAlwaysEmitsTodayAndYesterdayHourlyLanes() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageIdleHourly-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 6)))
        let today = calendar.startOfDay(for: now)
        let threeDaysBack = try XCTUnwrap(
            calendar.date(byAdding: .hour, value: 10, to: calendar.date(byAdding: .day, value: -3, to: today)!)
        )
        try codexTokenCountLine(timestamp: threeDaysBack, model: "gpt-5", input: 100_000, cached: 0, output: 0)
            .write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)

        let days = Set(snapshot.recentHourlyHistory.map { calendar.startOfDay(for: $0.date) })
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertTrue(days.contains(today))
        XCTAssertTrue(days.contains(yesterday))
        XCTAssertFalse(
            days.contains(try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))),
            "an idle day carries no buckets"
        )
        // Today stops at the hour in progress rather than drawing the rest of
        // the day as zeros.
        XCTAssertEqual(snapshot.recentHourlyHistory.filter { $0.date >= today }.count, 7)
        XCTAssertEqual(snapshot.recentHourlyHistory.filter { $0.date >= today }, snapshot.todayHourlyHistory)
        XCTAssertEqual(
            snapshot.recentHourlyHistory.filter { calendar.isDate($0.date, inSameDayAs: yesterday) },
            snapshot.yesterdayHourlyHistory
        )
    }

    /// `recentHourlyHistory` is a superset of the two day lanes, so it must
    /// never repeat an hour — a duplicate would both double the total and give
    /// two chart marks the same identity.
    func testRecentHourlyHistoryHasNoDuplicateHours() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageHourlyDupes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        var calendar = Calendar.current
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // The day after a spring-forward: the window contains a 23-hour day, so
        // fixed 24-offset arithmetic would spill one bucket into the next day.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 20)))
        var lines: [String] = []
        for dayOffset in 1...6 {
            let day = try XCTUnwrap(
                calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now))
            )
            let stamp = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: day))
            lines.append(
                codexTokenCountLine(
                    timestamp: stamp,
                    model: "gpt-5",
                    input: 100_000 * (dayOffset + 1),
                    cached: 0,
                    output: 0
                )
            )
        }
        try lines.joined(separator: "\n").write(
            to: sessions.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)
        let dates = snapshot.recentHourlyHistory.map(\.date)

        XCTAssertEqual(Set(dates).count, dates.count, "hourly buckets must be unique")
        XCTAssertEqual(dates, dates.sorted(), "hourly buckets must be ordered oldest first")
        // The 23-hour day really is short, and the 24-hour ones really are not.
        let shortDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        XCTAssertEqual(dates.filter { calendar.isDate($0, inSameDayAs: shortDay) }.count, 23)
        let normalDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)))
        XCTAssertEqual(dates.filter { calendar.isDate($0, inSameDayAs: normalDay) }.count, 24)
    }

    func testCodexScanKeepsEveryPerHourAndPerDayModel() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageAllModels-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let hour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: day))
        let now = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: hour))
        let lines = (0..<24).map { index in
            codexTokenCountLine(
                timestamp: hour.addingTimeInterval(Double(index)),
                model: "gpt-model-\(index)",
                input: (index + 1) * 1_000,
                cached: 0,
                output: 0
            )
        }
        try lines.joined(separator: "\n").write(
            to: sessions.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let scanned = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
        let snapshot = try XCTUnwrap(scanned)

        XCTAssertEqual(snapshot.topModels(forHour: hour, limit: .max).count, 24)
        XCTAssertEqual(snapshot.topModels(for: day, limit: .max).count, 24)
    }

    func testCodexScanUsesLastTokenUsageWhenTotalsAreMissing() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCostUsageLastTokenTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessions = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = sessions.appendingPathComponent("session.jsonl")
        let timestamp = Self.isoFormatter.string(from: now)
        let lines = [
            #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"info":{"model":"gpt-5.4"}}}"#,
            #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50}}}}"#
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.allTimeTokens, 1_050)
        XCTAssertEqual(snapshot?.modelBreakdowns.first?.modelName, "gpt-5.4")
    }

    func testClaudeScanKeepsLastStreamingChunkAcrossCache() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarClaudeStreamingCostTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let projects = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let logURL = projects.appendingPathComponent("session.jsonl")
        let lines = [
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-stream",
                messageId: "msg-stream",
                requestId: "req-stream",
                model: "claude-haiku-4-5",
                input: 100,
                cacheRead: 0,
                cacheCreation: 0,
                output: 10
            ),
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-stream",
                messageId: "msg-stream",
                requestId: "req-stream",
                model: "claude-haiku-4-5",
                input: 150,
                cacheRead: 20,
                cacheCreation: 30,
                output: 15
            )
        ]
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let first = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)
        let second = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)

        XCTAssertEqual(first?.allTimeTokens, 215)
        XCTAssertEqual(second?.allTimeTokens, 215)
        XCTAssertEqual(first?.jsonlFilesFound, 1)
    }

    func testClaudeScanDeduplicatesCrossFileSubagentRows() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarClaudeCrossFileCostTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }

        let sessionRoot = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
            .appendingPathComponent("session-cross-file", isDirectory: true)
        let subagents = sessionRoot.appendingPathComponent("subagents", isDirectory: true)
        try fileManager.createDirectory(at: subagents, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_762_339_200)
        let parentURL = sessionRoot.appendingPathComponent("parent.jsonl")
        let subagentURL = subagents.appendingPathComponent("agent.jsonl")
        try claudeAssistantLine(
            timestamp: now,
            sessionId: "session-cross-file",
            messageId: "msg-overlap",
            requestId: "req-overlap",
            model: "claude-haiku-4-5",
            input: 100,
            cacheRead: 0,
            cacheCreation: 0,
            output: 11
        ).write(to: parentURL, atomically: true, encoding: .utf8)
        let subagentLines = [
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-cross-file",
                messageId: "msg-overlap",
                requestId: "req-overlap",
                model: "claude-haiku-4-5",
                input: 900,
                cacheRead: 0,
                cacheCreation: 0,
                output: 99,
                isSidechain: true
            ),
            claudeAssistantLine(
                timestamp: now,
                sessionId: "session-cross-file",
                messageId: "msg-unique",
                requestId: "req-unique",
                model: "claude-haiku-4-5",
                input: 5,
                cacheRead: 0,
                cacheCreation: 0,
                output: 2,
                isSidechain: true
            )
        ]
        try subagentLines.joined(separator: "\n").write(to: subagentURL, atomically: true, encoding: .utf8)

        let snapshot = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)

        XCTAssertEqual(snapshot?.allTimeTokens, 118)
        XCTAssertEqual(snapshot?.jsonlFilesFound, 2)
    }

    // MARK: - Fast / priority service tier

    func testCodexFastServiceTierParsesConfigToml() throws {
        let fileManager = FileManager.default
        func tierIsFast(_ toml: String) throws -> Bool {
            let home = fileManager.temporaryDirectory
                .appendingPathComponent("VibeBarCodexTier-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: home) }
            let codex = home.appendingPathComponent(".codex", isDirectory: true)
            try fileManager.createDirectory(at: codex, withIntermediateDirectories: true)
            try toml.write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            return CostUsageScanner.codexFastServiceTier(homeDirectory: home.path)
        }

        XCTAssertTrue(try tierIsFast(#"service_tier = "fast""#))
        XCTAssertTrue(try tierIsFast(#"service_tier = 'priority'  # higher tier"#))
        XCTAssertFalse(try tierIsFast(#"service_tier = "standard""#))
        XCTAssertFalse(try tierIsFast(##"# service_tier = "fast""##))
        XCTAssertFalse(try tierIsFast("model = \"gpt-5.5\"\n"))
    }

    func testCodexFastServiceTierMissingConfigIsStandard() {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("VibeBarCodexNoTier-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        XCTAssertFalse(CostUsageScanner.codexFastServiceTier(homeDirectory: home.path))
    }

    func testCodexScanAppliesConfiguredFastTierMultiplier() async throws {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_762_339_200)

        func scanCost(fast: Bool) async throws -> Double {
            let home = fileManager.temporaryDirectory
                .appendingPathComponent("VibeBarCodexFastScan-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: home) }
            let codex = home.appendingPathComponent(".codex", isDirectory: true)
            let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
            try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
            if fast {
                try #"service_tier = "fast""#
                    .write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
            try codexTokenCountLine(timestamp: now, model: "gpt-5.5", input: 1_000_000, cached: 0, output: 100_000)
                .write(to: sessions.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
            let snapshot = await CostUsageScanner.scan(tool: .codex, homeDirectory: home.path, now: now)
            return try XCTUnwrap(snapshot?.modelBreakdowns.first?.costUSD)
        }

        // gpt-5.5: 1M input + 100k output = 8.0 base; fast tier ×2.5 = 20.0.
        let standard = try await scanCost(fast: false)
        let fast = try await scanCost(fast: true)
        XCTAssertEqual(standard, 8.0, accuracy: 0.001)
        XCTAssertEqual(fast, 20.0, accuracy: 0.001)
    }

    func testClaudeScanAppliesPerMessageFastSpeedMultiplier() async throws {
        PricingResolver.testOverride = PricingHardcoded.fallback
        defer { PricingResolver.testOverride = nil }
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_762_339_200)

        func scanCost(speed: String) async throws -> Double {
            let home = fileManager.temporaryDirectory
                .appendingPathComponent("VibeBarClaudeFastScan-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: home) }
            let projects = home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent("project-a", isDirectory: true)
            try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
            try claudeAssistantLine(
                timestamp: now, sessionId: "s", messageId: "m", requestId: "r",
                model: "claude-opus-4-7", input: 1_000_000, cacheRead: 0, cacheCreation: 0,
                output: 100_000, speed: speed
            ).write(to: projects.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
            let snapshot = await CostUsageScanner.scan(tool: .claude, homeDirectory: home.path, now: now)
            return try XCTUnwrap(snapshot?.modelBreakdowns.first?.costUSD)
        }

        // opus-4-7: 1M input + 100k output = 7.5 base; fast speed ×6 = 45.0.
        let standard = try await scanCost(speed: "standard")
        let fast = try await scanCost(speed: "fast")
        XCTAssertEqual(standard, 7.5, accuracy: 0.001)
        XCTAssertEqual(fast, 45.0, accuracy: 0.001)
    }

    private func codexTokenCountLine(
        timestamp: Date,
        model: String,
        input: Int,
        cached: Int,
        output: Int
    ) -> String {
        let timestampString = Self.isoFormatter.string(from: timestamp)
        return """
        {"timestamp":"\(timestampString)","type":"event_msg","payload":{"type":"token_count","model":"\(model)","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}}}}
        """
    }

    private func claudeAssistantLine(
        timestamp: Date,
        sessionId: String,
        messageId: String,
        requestId: String,
        model: String,
        input: Int,
        cacheRead: Int,
        cacheCreation: Int,
        output: Int,
        isSidechain: Bool = false,
        speed: String? = nil
    ) -> String {
        let timestampString = Self.isoFormatter.string(from: timestamp)
        let speedField = speed.map { ",\"speed\":\"\($0)\"" } ?? ""
        return """
        {"timestamp":"\(timestampString)","type":"assistant","sessionId":"\(sessionId)","requestId":"\(requestId)","isSidechain":\(isSidechain),"message":{"id":"\(messageId)","model":"\(model)","usage":{"input_tokens":\(input),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"output_tokens":\(output)\(speedField)}}}
        """
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
