import Foundation

public enum MockDataProvider {
    public static func sampleAccounts() -> [AccountIdentity] {
        [
            AccountIdentity(
                id: "demo-codex",
                tool: .codex,
                email: "codex-demo@example.invalid",
                alias: "OpenAI Demo",
                plan: "demo",
                accountId: "acct_demo_codex",
                source: .cliDetected
            ),
            AccountIdentity(
                id: "demo-claude",
                tool: .claude,
                email: "claude-demo@example.invalid",
                alias: "Claude Demo",
                plan: "demo",
                source: .cliDetected
            )
        ]
    }

    public static func sampleCostHistory(for tool: ToolType, timeframe: CostTimeframe, now: Date = Date()) -> CostHistory {
        guard tool.supportsTokenCost else { return CostHistory(tool: tool, days: [], updatedAt: now) }
        let days: Int
        switch timeframe {
        case .today: days = 1
        case .week:  days = 7
        case .month: days = 30
        case .all:   days = 120
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let baseCost: Double = (tool == .codex) ? 0.7 : 1.1
        var points: [DailyCostPoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let weekendDip = (weekday == 1 || weekday == 7) ? 0.45 : 1.0
            let oscillation = 0.6 + 0.5 * Double((offset * 7) % 13) / 13.0
            let cost = baseCost * weekendDip * oscillation
            let tokens = Int(cost * 80_000)
            points.append(DailyCostPoint(date: day, costUSD: cost, totalTokens: tokens))
        }
        return CostHistory(tool: tool, days: points, updatedAt: now)
    }

    public static func sampleCostSnapshot(for tool: ToolType, now: Date = Date()) -> CostSnapshot? {
        guard tool.supportsTokenCost else { return nil }
        let history = sampleCostHistory(for: tool, timeframe: .all, now: now)
        var weekCost = 0.0, weekTokens = 0
        var monthCost = 0.0, monthTokens = 0
        var allCost = 0.0, allTokens = 0
        var todayCost = 0.0, todayTokens = 0
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekCutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let monthCutoff = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        for point in history.days {
            allCost += point.costUSD
            allTokens += point.totalTokens
            if point.date >= today { todayCost += point.costUSD; todayTokens += point.totalTokens }
            if point.date >= weekCutoff { weekCost += point.costUSD; weekTokens += point.totalTokens }
            if point.date >= monthCutoff { monthCost += point.costUSD; monthTokens += point.totalTokens }
        }
        let currentHour = calendar.component(.hour, from: now)
        let hourWeights: [(Date, Double)] = (0...max(0, currentHour)).compactMap { offset in
            guard let hour = calendar.date(byAdding: .hour, value: offset, to: today) else { return nil }
            let hourOfDay = calendar.component(.hour, from: hour)
            let workdayPulse = hourOfDay >= 9 && hourOfDay <= 21
            let lunchDip = hourOfDay == 12 ? 0.45 : 1.0
            let eveningLift = hourOfDay >= 17 && hourOfDay <= 20 ? 1.35 : 1.0
            let weight = workdayPulse ? lunchDip * eveningLift * (0.7 + Double((hourOfDay * 5) % 7) / 10.0) : 0
            return (hour, weight)
        }
        let totalHourWeight = hourWeights.map(\.1).reduce(0, +)
        let hourlyToday: [HourlyCostPoint] = hourWeights.map { hour, weight in
            let share = totalHourWeight > 0 ? weight / totalHourWeight : 0
            return HourlyCostPoint(
                date: hour,
                costUSD: todayCost * share,
                totalTokens: Int(Double(todayTokens) * share)
            )
        }
        // Synthetic heatmap with a clear "weekday afternoon" peak.
        var cells: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for wd in 0..<7 {
            for hr in 0..<24 {
                let weekendDip = (wd == 0 || wd == 6) ? 0.3 : 1.0
                let isAfternoon = hr >= 13 && hr <= 18
                let intensity = isAfternoon ? 1.0 : (hr >= 9 && hr <= 22 ? 0.5 : 0.1)
                cells[wd][hr] = Int(weekendDip * intensity * 18_000)
            }
        }
        let allTimeBreakdowns: [CostSnapshot.ModelBreakdown] = (tool == .codex) ? [
            .init(modelName: "gpt-5.2-codex", costUSD: allCost * 0.7, totalTokens: Int(Double(allTokens) * 0.6)),
            .init(modelName: "gpt-5-mini",    costUSD: allCost * 0.2, totalTokens: Int(Double(allTokens) * 0.3)),
            .init(modelName: "gpt-5.3-codex-spark", costUSD: allCost * 0.1, totalTokens: Int(Double(allTokens) * 0.1))
        ] : [
            .init(modelName: "claude-sonnet-4-5", costUSD: allCost * 0.75, totalTokens: Int(Double(allTokens) * 0.75)),
            .init(modelName: "claude-opus-4-1",   costUSD: allCost * 0.25, totalTokens: Int(Double(allTokens) * 0.25))
        ]
        let weekBreakdowns: [CostSnapshot.ModelBreakdown] = (tool == .codex) ? [
            .init(modelName: "gpt-5.3-codex-spark", costUSD: weekCost * 0.55, totalTokens: Int(Double(weekTokens) * 0.45)),
            .init(modelName: "gpt-5.2-codex", costUSD: weekCost * 0.35, totalTokens: Int(Double(weekTokens) * 0.4)),
            .init(modelName: "gpt-5-mini", costUSD: weekCost * 0.10, totalTokens: Int(Double(weekTokens) * 0.15))
        ] : [
            .init(modelName: "claude-sonnet-4-5", costUSD: weekCost * 0.82, totalTokens: Int(Double(weekTokens) * 0.8)),
            .init(modelName: "claude-opus-4-1", costUSD: weekCost * 0.18, totalTokens: Int(Double(weekTokens) * 0.2))
        ]
        // Synthetic per-day model breakdown so the chart tooltip has something
        // to show in mock mode. Splits each day's cost roughly 70/30 between
        // the two top models.
        var perDayModels: [Date: [CostSnapshot.ModelBreakdown]] = [:]
        for point in history.days where point.costUSD > 0 {
            let topName = allTimeBreakdowns.first?.modelName ?? "model"
            let secondaryName = allTimeBreakdowns.dropFirst().first?.modelName
            var entries: [CostSnapshot.ModelBreakdown] = [
                .init(modelName: topName, costUSD: point.costUSD * 0.7, totalTokens: Int(Double(point.totalTokens) * 0.7))
            ]
            if let secondaryName {
                entries.append(.init(modelName: secondaryName, costUSD: point.costUSD * 0.3, totalTokens: Int(Double(point.totalTokens) * 0.3)))
            }
            perDayModels[Calendar.current.startOfDay(for: point.date)] = entries
        }
        return CostSnapshot(
            tool: tool,
            todayCostUSD: todayCost,
            last7DaysCostUSD: weekCost,
            last30DaysCostUSD: monthCost,
            allTimeCostUSD: allCost,
            todayTokens: todayTokens,
            last7DaysTokens: weekTokens,
            last30DaysTokens: monthTokens,
            allTimeTokens: allTokens,
            dailyHistory: history.days,
            todayHourlyHistory: hourlyToday,
            heatmap: UsageHeatmap(tool: tool, cells: cells, totalTokens: cells.flatMap { $0 }.reduce(0, +)),
            modelBreakdowns: allTimeBreakdowns,
            last7DaysModelBreakdowns: weekBreakdowns,
            dailyModelBreakdown: perDayModels,
            jsonlFilesFound: 27,
            updatedAt: now
        )
    }

    public static func sampleExtras(for tool: ToolType, now: Date = Date()) -> ProviderExtras? {
        // Extras (credits / overage) UI was removed; mock kept around for any
        // future re-enable but it's no longer rendered.
        switch tool {
        case .codex:
            return ProviderExtras(
                tool: .codex,
                creditsRemainingUSD: 18.42,
                creditsTopupURL: URL(string: "https://platform.openai.com/settings/organization/billing/overview"),
                extraUsageSpendUSD: nil,
                extraUsageLimitUSD: nil,
                extraUsageEnabled: false,
                updatedAt: now
            )
        case .claude:
            return ProviderExtras(
                tool: .claude,
                creditsRemainingUSD: nil,
                creditsTopupURL: nil,
                extraUsageSpendUSD: 4.27,
                extraUsageLimitUSD: 25.00,
                extraUsageEnabled: true,
                updatedAt: now
            )
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine, .openCodeGo, .kilo, .kiro, .ollama, .openRouter:
            // Misc providers don't carry credits / overage extras in the
            // mock. The Cursor card surfaces on-demand budget through a
            // different field on `AccountQuota`, not `ProviderExtras`.
            return nil
        }
    }

    public static func sampleQuota(for account: AccountIdentity, now: Date = Date()) -> AccountQuota {
        let fiveHourReset = now.addingTimeInterval(3 * 3600 + 16 * 60)
        let weeklyReset = now.addingTimeInterval(5 * 24 * 3600)

        let buckets: [QuotaBucket]
        switch account.tool {
        case .codex:
            // Match the spec example: 56% used / 13% used.
            buckets = [
                QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h",
                            usedPercent: 56, resetAt: fiveHourReset, rawWindowSeconds: 18_000),
                QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "wk",
                            usedPercent: 13, resetAt: weeklyReset, rawWindowSeconds: 604_800),
                QuotaBucket(id: "gpt_5_3_codex_spark_five_hour", title: "5 Hours", shortLabel: "Spark 5h",
                            usedPercent: 0, resetAt: fiveHourReset, rawWindowSeconds: 18_000, groupTitle: "GPT-5.3 Codex Spark"),
                QuotaBucket(id: "gpt_5_3_codex_spark_weekly", title: "Weekly", shortLabel: "Spark wk",
                            usedPercent: 0, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "GPT-5.3 Codex Spark")
            ]
        case .claude:
            // Mock matches the live OAuth response: each model dimension lives
            // in its own group so the popover renders one section per model.
            let dayReset = now.addingTimeInterval(20 * 3600 + 12 * 60)
            buckets = [
                QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5h",
                            usedPercent: 22, resetAt: fiveHourReset, rawWindowSeconds: 18_000),
                QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "All wk",
                            usedPercent: 35, resetAt: weeklyReset, rawWindowSeconds: 604_800),
                QuotaBucket(id: "weekly_sonnet", title: "Weekly", shortLabel: "Sonnet wk",
                            usedPercent: 27, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Sonnet"),
                QuotaBucket(id: "weekly_design", title: "Weekly", shortLabel: "Designs",
                            usedPercent: 12, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Designs"),
                QuotaBucket(id: "daily_routines", title: "Today", shortLabel: "Routines",
                            usedPercent: 47, resetAt: dayReset, rawWindowSeconds: 86_400, groupTitle: "Daily Routines"),
                QuotaBucket(id: "weekly_opus", title: "Weekly", shortLabel: "Opus wk",
                            usedPercent: 18, resetAt: weeklyReset, rawWindowSeconds: 604_800, groupTitle: "Opus")
            ]
        case .alibaba, .gemini, .antigravity, .copilot, .zai, .minimax, .kimi, .cursor, .mimo, .iflytek, .tencentHunyuan, .volcengine, .openCodeGo, .kilo, .kiro, .ollama, .openRouter:
            // Misc providers' mock data lands in subsequent phases as
            // each adapter is wired up. For now return a single
            // illustrative bucket so the card renders something during
            // mock mode.
            buckets = [
                QuotaBucket(
                    id: "primary",
                    title: account.tool.subtitle,
                    shortLabel: "Used",
                    usedPercent: 25,
                    resetAt: weeklyReset,
                    rawWindowSeconds: 604_800
                )
            ]
        }

        return AccountQuota(
            accountId: account.id,
            tool: account.tool,
            buckets: buckets,
            plan: account.plan,
            email: account.email,
            queriedAt: now,
            error: nil
        )
    }
}
