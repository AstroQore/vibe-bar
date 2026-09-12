import Foundation
@testable import VibeBarCore

/// Synthetic numbers only — no real spend, account, or device data anywhere in
/// the E-ink test suite.
enum EInkFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func quotaRows(count: Int) -> [EInkQuotaRow] {
        let seeds: [(String, String, String, Int, Int)] = [
            ("claude.five_hour", "Claude", "5 Hours", 62, 3 * 3600),
            ("claude.weekly", "Claude", "Weekly", 41, 4 * 86_400),
            ("codex.weekly", "Codex", "Weekly", 88, 2 * 86_400),
            ("grok.weekly", "Grok", "Weekly", 17, 30 * 60),
            ("antigravity.claude_gpt_weekly", "AntiGravity", "Weekly", 73, 5 * 86_400),
            ("gemini.weekly", "Gemini", "Weekly", 95, 6 * 86_400),
            ("cursor.models", "Cursor", "Models", 8, 12 * 3600)
        ]
        return seeds.prefix(count).map { seed in
            let resetAt = referenceDate.addingTimeInterval(TimeInterval(seed.4))
            return EInkQuotaRow(
                fieldID: seed.0,
                providerDisplayName: seed.1,
                windowTitle: seed.2,
                remainingPercent: seed.3,
                resetAt: resetAt,
                countdown: EInkFormat.countdown(resetAt, now: referenceDate),
                plan: "Test Plan"
            )
        }
    }

    static func harnessRows(count: Int) -> [EInkHarnessRow] {
        let labels = ["Claude Code", "Codex CLI", "AntiGravity", "Grok Build", "Cursor", "Gemini CLI"]
        return (0..<count).map { index -> EInkHarnessRow in
            let cost: Double = Double(1_234 - index * 197) / 7
            let tokens: Int64 = Int64(4_841_587_557) / Int64(index + 1)
            return EInkHarnessRow(
                label: labels[index % labels.count],
                costUSD: cost,
                tokens: tokens,
                requests: 9_123 / (index + 1)
            )
        }
    }

    static func usageTotals(rowCount: Int, scale: Double) -> EInkUsageTotals {
        let cost: Double = 121_216.3 * scale
        let tokens: Double = 4_841_587_557 * scale
        let requests: Double = 987_654 * scale
        return EInkUsageTotals(
            costUSD: cost,
            tokens: Int64(tokens),
            requests: Int(requests),
            rows: harnessRows(count: rowCount)
        )
    }

    static func trendPoints() -> [EInkTrendPoint] {
        let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
        var points: [EInkTrendPoint] = []
        for index in 0..<7 {
            let cost: Double = Double(index * 37 + 4) / 3
            let tokens: Int64 = Int64(index + 1) * 41_000_000
            points.append(
                EInkTrendPoint(
                    bucketStart: referenceDate.addingTimeInterval(Double(index) * 86_400),
                    dayLabel: String(format: "%02d", index + 1),
                    weekdayLabel: weekdays[index],
                    costUSD: cost,
                    tokens: tokens
                )
            )
        }
        return points
    }

    /// A 7 × 24 grid with a clear busiest cell, so the heatmap's header has
    /// something definite to say.
    static func heatmap() -> EInkHeatmap {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for weekday in 0..<7 {
            for hour in 9..<19 {
                cells[weekday][hour] = 1_000 * (weekday + 1) + 100 * hour
            }
        }
        cells[2][21] = 9_000_000
        return EInkHeatmap(cells: cells, totalTokens: cells.flatMap { $0 }.reduce(0, +))
    }

    static func modelRows(count: Int = 6) -> [EInkModelRow] {
        let names = [
            "claude-opus-5", "gpt-5.3-codex", "gemini-3-pro",
            "claude-sonnet-4-6", "grok-4", "gpt-6-astra"
        ]
        return (0..<count).map { index in
            EInkModelRow(
                model: names[index % names.count],
                costUSD: Double(940 - index * 137) / 11,
                tokens: Int64(1_400_000_000) / Int64(index + 1),
                requests: 4_311 / (index + 1)
            )
        }
    }

    static func forecast(_ verdict: QuotaPaceForecast.Verdict, projected: Double, runsOutIn: TimeInterval?) -> EInkQuotaForecast {
        EInkQuotaForecast(
            verdict: verdict,
            projectedUsedPercent: projected,
            runOutAt: runsOutIn.map { referenceDate.addingTimeInterval($0) }
        )
    }

    static func snapshot(quotaCount: Int = 7, harnessCount: Int = 6) -> EInkDataSnapshot {
        let usage = EInkUsageSet(
            today: usageTotals(rowCount: harnessCount, scale: 0.002),
            week: usageTotals(rowCount: harnessCount, scale: 0.05),
            month: usageTotals(rowCount: harnessCount, scale: 0.2),
            allTime: usageTotals(rowCount: harnessCount, scale: 1)
        )
        let verdicts: [QuotaPaceForecast.Verdict] = [.surplus, .enough, .watch, .atRisk, .learning, .enough, .surplus]
        let quota = quotaRows(count: quotaCount).enumerated().map { index, row -> EInkQuotaRow in
            var copy = row
            copy.forecast = forecast(
                verdicts[index % verdicts.count],
                projected: Double(40 + index * 9),
                runsOutIn: index % 2 == 0 ? Double(index + 1) * 3_600 : nil
            )
            return copy
        }
        return EInkDataSnapshot(
            generatedAt: referenceDate,
            generatedAtLabel: EInkFormat.timestampLabel(referenceDate, calendar: calendar()),
            generatedAtISO: "2026-01-01T00:00:00Z",
            quota: quota,
            usage: usage,
            trend: trendPoints(),
            clockLabel: EInkFormat.clockLabel(referenceDate, calendar: calendar()),
            dateLabel: EInkFormat.dateLabel(referenceDate, calendar: calendar()),
            heatmap: heatmap(),
            topModels: modelRows(),
            providerStatusLine: "All providers operational"
        )
    }

    static func device(orientation: EInkOrientation) -> EInkDeviceConfig {
        EInkDeviceConfig(
            deviceID: "0000AAAA0000",
            alias: "Test Panel",
            profile: .quote0,
            enabled: true,
            orientation: orientation,
            playback: .single(slideID: "slide-1"),
            taskKeys: ["task-key-0001"],
            slides: []
        )
    }

    static func slide(preset: EInkPreset, fieldIDs: [String] = [], periods: [EInkUsagePeriod] = EInkUsagePeriod.allCases) -> EInkSlide {
        EInkSlide(
            id: "slide-1",
            title: preset.identifierName,
            kind: .preset(preset),
            quotaFieldIDs: fieldIDs,
            usagePeriods: periods
        )
    }
}
