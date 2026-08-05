import Foundation

/// Builds the same `CostSnapshot` shape used by local CLI scanners from facts
/// that have already been authenticated, decrypted, and deduplicated by the
/// remote ledger. Relay and Control Plane never participate in this step.
struct RemoteCostSnapshotBuilder {
    private let tool: ToolType
    private let now: Date
    private let calendar: Calendar
    private let startOfToday: Date
    private let startOfYesterday: Date
    private let weekCutoff: Date
    private let monthCutoff: Date
    private let hourlyCutoff: Date

    private var todayCost = 0.0
    private var weekCost = 0.0
    private var monthCost = 0.0
    private var totalCost = 0.0
    private var todayTokens = 0
    private var weekTokens = 0
    private var monthTokens = 0
    private var totalTokens = 0
    private var todayRequests = 0
    private var weekRequests = 0
    private var monthRequests = 0
    private var totalRequests = 0
    private var byDay: [Date: (cost: Double, tokens: Int)] = [:]
    private var byHour: [Date: (cost: Double, tokens: Int)] = [:]
    private var hourlyDays = Set<Date>()
    private var heatmap = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    private var byModelAllTime: [String: (cost: Double, tokens: Int)] = [:]
    private var byModel7d: [String: (cost: Double, tokens: Int)] = [:]
    private var byDayModel: [Date: [String: (cost: Double, tokens: Int)]] = [:]
    private var byHourModel: [Date: [String: (cost: Double, tokens: Int)]] = [:]

    init(tool: ToolType, now: Date, calendar: Calendar = .current) {
        self.tool = tool
        self.now = now
        self.calendar = calendar
        self.startOfToday = calendar.startOfDay(for: now)
        self.startOfYesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        self.weekCutoff = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        self.monthCutoff = calendar.date(
            byAdding: .day,
            value: -29,
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        self.hourlyCutoff = CostChartWindowPolicy.hourlyRetentionStart(
            now: now,
            calendar: calendar
        )
    }

    mutating func add(
        occurredAt date: Date,
        model: String?,
        tokens: Int,
        costUSD: Double,
        requestCount: Int
    ) {
        guard date <= now else { return }
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Unknown"
        let requests = max(0, requestCount)
        let day = calendar.startOfDay(for: date)

        totalCost += costUSD
        totalTokens = saturatedAdd(totalTokens, tokens)
        totalRequests = saturatedAdd(totalRequests, requests)
        if day == startOfToday {
            todayCost += costUSD
            todayTokens = saturatedAdd(todayTokens, tokens)
            todayRequests = saturatedAdd(todayRequests, requests)
        }
        if day >= weekCutoff {
            weekCost += costUSD
            weekTokens = saturatedAdd(weekTokens, tokens)
            weekRequests = saturatedAdd(weekRequests, requests)
        }
        if day >= monthCutoff {
            monthCost += costUSD
            monthTokens = saturatedAdd(monthTokens, tokens)
            monthRequests = saturatedAdd(monthRequests, requests)
        }

        var dayValue = byDay[day] ?? (0, 0)
        dayValue.cost += costUSD
        dayValue.tokens = saturatedAdd(dayValue.tokens, tokens)
        byDay[day] = dayValue

        let weekday = calendar.component(.weekday, from: date) - 1
        let hour = calendar.component(.hour, from: date)
        if heatmap.indices.contains(weekday), heatmap[weekday].indices.contains(hour) {
            heatmap[weekday][hour] = saturatedAdd(heatmap[weekday][hour], tokens)
        }

        accumulate(model: model, cost: costUSD, tokens: tokens, in: &byModelAllTime)
        if day >= weekCutoff {
            accumulate(model: model, cost: costUSD, tokens: tokens, in: &byModel7d)
        }
        var dayModels = byDayModel[day] ?? [:]
        accumulate(model: model, cost: costUSD, tokens: tokens, in: &dayModels)
        byDayModel[day] = dayModels

        if date >= hourlyCutoff, day <= startOfToday,
           let hourStart = calendar.dateInterval(of: .hour, for: date)?.start {
            var hourValue = byHour[hourStart] ?? (0, 0)
            hourValue.cost += costUSD
            hourValue.tokens = saturatedAdd(hourValue.tokens, tokens)
            byHour[hourStart] = hourValue
            hourlyDays.insert(day)
            var hourModels = byHourModel[hourStart] ?? [:]
            accumulate(model: model, cost: costUSD, tokens: tokens, in: &hourModels)
            byHourModel[hourStart] = hourModels
        }
    }

    func snapshot(sourceCount: Int) -> CostSnapshot {
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? startOfToday
        let recentDays = hourlyDays
            .union([startOfToday, startOfYesterday])
            .filter { $0 >= hourlyCutoff && $0 <= startOfToday }
            .sorted()
        return CostSnapshot(
            tool: tool,
            todayCostUSD: todayCost,
            last7DaysCostUSD: weekCost,
            last30DaysCostUSD: monthCost,
            allTimeCostUSD: totalCost,
            todayTokens: todayTokens,
            last7DaysTokens: weekTokens,
            last30DaysTokens: monthTokens,
            allTimeTokens: totalTokens,
            todayRequests: todayRequests,
            last7DaysRequests: weekRequests,
            last30DaysRequests: monthRequests,
            allTimeRequests: totalRequests,
            dailyHistory: byDay.sorted { $0.key < $1.key }.map {
                DailyCostPoint(date: $0.key, costUSD: $0.value.cost, totalTokens: $0.value.tokens)
            },
            todayHourlyHistory: hourlyPoints(forDayStarting: startOfToday, notAfter: currentHour),
            yesterdayHourlyHistory: hourlyPoints(forDayStarting: startOfYesterday, notAfter: nil),
            recentHourlyHistory: recentDays.flatMap {
                hourlyPoints(forDayStarting: $0, notAfter: $0 == startOfToday ? currentHour : nil)
            },
            hourlyCoverageStart: hourlyCutoff,
            heatmap: UsageHeatmap(tool: tool, cells: heatmap, totalTokens: totalTokens),
            modelBreakdowns: breakdowns(byModelAllTime),
            last7DaysModelBreakdowns: breakdowns(byModel7d),
            dailyModelBreakdown: byDayModel.mapValues(breakdowns),
            hourlyModelBreakdown: byHourModel.mapValues(breakdowns),
            // This field predates non-file sources and is used as the product's
            // "has cost data" sentinel. Count contributing remote machines so
            // selected remote-only providers render without inventing files.
            jsonlFilesFound: max(0, sourceCount),
            updatedAt: now
        )
    }

    private func hourlyPoints(forDayStarting day: Date, notAfter limit: Date?) -> [HourlyCostPoint] {
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        var result: [HourlyCostPoint] = []
        var hour = day
        while hour < end {
            if let limit, hour > limit { break }
            let value = byHour[hour] ?? (0, 0)
            result.append(HourlyCostPoint(date: hour, costUSD: value.cost, totalTokens: value.tokens))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else {
                break
            }
            hour = next
        }
        return result
    }

    private func breakdowns(
        _ values: [String: (cost: Double, tokens: Int)]
    ) -> [CostSnapshot.ModelBreakdown] {
        values.sorted {
            if $0.value.cost == $1.value.cost { return $0.value.tokens > $1.value.tokens }
            return $0.value.cost > $1.value.cost
        }.prefix(20).map {
            CostSnapshot.ModelBreakdown(
                modelName: $0.key,
                costUSD: $0.value.cost,
                totalTokens: $0.value.tokens
            )
        }
    }

    private func accumulate(
        model: String,
        cost: Double,
        tokens: Int,
        in values: inout [String: (cost: Double, tokens: Int)]
    ) {
        var value = values[model] ?? (0, 0)
        value.cost += cost
        value.tokens = saturatedAdd(value.tokens, tokens)
        values[model] = value
    }

    private func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
