import Foundation

/// Everything the E-ink layouts can draw, already reduced to display values.
///
/// Assembled once per refresh by `EInkDataAssembler` and then treated as
/// immutable: the presets are pure layout over this struct, which is what
/// makes every preset × orientation combination testable without a ledger,
/// a network, or a device.
public struct EInkDataSnapshot: Sendable, Equatable {
    public var generatedAt: Date
    /// `MM-dd HH:mm` in the user's local time, as printed in every header.
    public var generatedAtLabel: String
    public var generatedAtISO: String
    /// Quota buckets in display priority; the slide picks a prefix of these.
    public var quota: [EInkQuotaRow]
    public var usage: EInkUsageSet
    /// Seven daily points, oldest first.
    public var trend: [EInkTrendPoint]
    /// `HH:mm` at assembly time, for a header or footer bound to the clock.
    public var clockLabel: String
    /// `MM-dd` at assembly time.
    public var dateLabel: String
    /// The 7 × 24 activity grid, summed over every provider.
    public var heatmap: EInkHeatmap
    /// Today's heaviest models by spend, heaviest first.
    public var topModels: [EInkModelRow]
    /// One line about provider health: "Anthropic: degraded" or
    /// "All providers operational". Empty when nothing was read.
    public var providerStatusLine: String
    /// `data:image/png;base64,…` marks, keyed by `EInkLogo.key(fieldID:size:)`.
    ///
    /// Rasterized once per refresh rather than per slide: a carousel draws the
    /// same five buckets on every panel it owns, and the threshold pass is the
    /// expensive part. A slot whose mark is missing draws its name in words,
    /// so a snapshot assembled without a logo provider is a panel that reads
    /// exactly as it did before the marks existed.
    public var logos: [String: String]

    public init(
        generatedAt: Date,
        generatedAtLabel: String,
        generatedAtISO: String,
        quota: [EInkQuotaRow],
        usage: EInkUsageSet,
        trend: [EInkTrendPoint],
        clockLabel: String = "",
        dateLabel: String = "",
        heatmap: EInkHeatmap = .empty,
        topModels: [EInkModelRow] = [],
        providerStatusLine: String = "",
        logos: [String: String] = [:]
    ) {
        self.generatedAt = generatedAt
        self.generatedAtLabel = generatedAtLabel
        self.generatedAtISO = generatedAtISO
        self.quota = quota
        self.usage = usage
        self.trend = trend
        self.clockLabel = clockLabel
        self.dateLabel = dateLabel
        self.heatmap = heatmap
        self.topModels = topModels
        self.providerStatusLine = providerStatusLine
        self.logos = logos
    }

    /// The mark this slot draws at this size, if there is one.
    public func logo(fieldID: String, size: Int) -> String? {
        logos[EInkLogo.key(fieldID: fieldID, size: size)]
    }

    public func quotaRows(fieldIDs: [String], limit: Int) -> [EInkQuotaRow] {
        let selected: [EInkQuotaRow]
        if fieldIDs.isEmpty {
            selected = quota
        } else {
            let byField = Dictionary(quota.map { ($0.fieldID, $0) }, uniquingKeysWith: { first, _ in first })
            selected = fieldIDs.compactMap { byField[$0] }
        }
        return Array(selected.prefix(max(0, limit)))
    }
}

/// One quota bucket, already reduced to what the panel prints.
public struct EInkQuotaRow: Sendable, Equatable {
    /// `MenuBarFieldCatalog.fieldId(tool:bucketId:)`, e.g. `claude.weekly`.
    public var fieldID: String
    /// Company-axis name: "Codex", "Claude", "Grok", "AntiGravity", …
    public var providerDisplayName: String
    /// The bucket's window title, written in full ("5 Hours", "Weekly").
    public var windowTitle: String
    /// 0…100, rounded. The panel shows quota *left*, not used.
    public var remainingPercent: Int
    public var resetAt: Date?
    /// `EInkFormat.countdown(resetAt, now)`, e.g. "5d 23h".
    public var countdown: String
    public var plan: String
    /// What the pace model says about this bucket, when there is enough
    /// history for one.
    public var forecast: EInkQuotaForecast?

    public init(
        fieldID: String,
        providerDisplayName: String,
        windowTitle: String,
        remainingPercent: Int,
        resetAt: Date? = nil,
        countdown: String = "",
        plan: String = "",
        forecast: EInkQuotaForecast? = nil
    ) {
        self.fieldID = fieldID
        self.providerDisplayName = providerDisplayName
        self.windowTitle = windowTitle
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetAt = resetAt
        self.countdown = countdown
        self.plan = plan
        self.forecast = forecast
    }

    /// The slot's label as the panel prints it: SubProvider, quota group and
    /// window, already resolved by `EInkSlotLabel`.
    ///
    /// `providerDisplayName` is the first tier only, and every preset that
    /// names a bucket should print this instead — that is the whole point of
    /// the round 2 naming change.
    public var slotLabel: String {
        windowTitle.isEmpty ? providerDisplayName : "\(providerDisplayName) · \(windowTitle)"
    }

    /// A row that is nothing but a name, for measuring a layout before there
    /// is any data behind it.
    public static func named(_ label: String) -> EInkQuotaRow {
        let parts = label.components(separatedBy: EInkSlotLabel.separator)
        return EInkQuotaRow(
            fieldID: label,
            providerDisplayName: parts.first ?? label,
            windowTitle: parts.dropFirst().joined(separator: EInkSlotLabel.separator),
            remainingPercent: 0
        )
    }

    /// This row wearing one slide's own name for it.
    ///
    /// The assembler already resolves a default (and honours the merged
    /// override map, which is what the shared snapshot can carry), but two
    /// slides may name the same bucket differently — a wide landscape ledger
    /// and a 140 px portrait rail want different lengths. The slide's own
    /// label therefore wins at draw time, split on the same separator so the
    /// two-line slots still break where the name reads.
    public func relabeled(with options: EInkSlideOptions) -> EInkQuotaRow {
        guard let label = options.customLabel(for: fieldID) else { return self }
        var copy = self
        let parts = label.components(separatedBy: EInkSlotLabel.separator)
        copy.providerDisplayName = parts.first ?? label
        copy.windowTitle = parts.dropFirst().joined(separator: EInkSlotLabel.separator)
        return copy
    }
}

/// The pace verdict for one bucket, reduced to what the panel prints.
public struct EInkQuotaForecast: Sendable, Equatable {
    public var verdict: QuotaPaceForecast.Verdict
    /// Median projected demand at reset; may exceed 100.
    public var projectedUsedPercent: Double
    public var runOutAt: Date?

    public init(verdict: QuotaPaceForecast.Verdict, projectedUsedPercent: Double, runOutAt: Date? = nil) {
        self.verdict = verdict
        self.projectedUsedPercent = projectedUsedPercent
        self.runOutAt = runOutAt
    }

    public init(_ forecast: QuotaPaceForecast) {
        self.init(
            verdict: forecast.verdict,
            projectedUsedPercent: forecast.projectedUsedPercent,
            runOutAt: forecast.runOutAt
        )
    }

    /// The verdict in English, in full. Never `Verdict.label`: that one is
    /// localized, and the panel is English by contract.
    public var word: String {
        switch verdict {
        case .surplus: "SURPLUS"
        case .enough: "ENOUGH"
        case .watch: "WATCH"
        case .atRisk: "AT RISK"
        case .learning: "LEARNING"
        }
    }

    /// Projected use at reset, clamped to a bar percentage.
    public var projectedTickPercent: Int {
        max(0, min(100, Int(projectedUsedPercent.rounded())))
    }
}

/// One model's share of today's spend.
public struct EInkModelRow: Sendable, Equatable {
    public var model: String
    public var costUSD: Double
    public var tokens: Int64
    public var requests: Int

    public init(model: String, costUSD: Double, tokens: Int64, requests: Int) {
        self.model = model
        self.costUSD = costUSD
        self.tokens = tokens
        self.requests = requests
    }
}

/// The 7 × 24 activity grid the heatmap preset draws, summed over providers.
public struct EInkHeatmap: Sendable, Equatable {
    /// `[weekday 0 = Sunday][hour 0...23]` token counts.
    public var cells: [[Int]]
    public var totalTokens: Int

    public init(cells: [[Int]], totalTokens: Int) {
        let normalized = (0..<7).map { row -> [Int] in
            let source = row < cells.count ? cells[row] : []
            return (0..<24).map { column in column < source.count ? max(0, source[column]) : 0 }
        }
        self.cells = normalized
        self.totalTokens = max(0, totalTokens)
    }

    public static let empty = EInkHeatmap(cells: [], totalTokens: 0)

    public var isEmpty: Bool { totalTokens == 0 || cells.allSatisfy { $0.allSatisfy { $0 == 0 } } }

    /// Sum of every provider's grid, so the panel shows when *this Mac* works
    /// rather than when one vendor does.
    public static func summing(_ maps: [UsageHeatmap]) -> EInkHeatmap {
        var cells = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var total = 0
        for map in maps {
            for (row, hours) in map.cells.enumerated() where row < 7 {
                for (hour, value) in hours.enumerated() where hour < 24 {
                    cells[row][hour] += max(0, value)
                    total += max(0, value)
                }
            }
        }
        return EInkHeatmap(cells: cells, totalTokens: total)
    }

    /// `(weekday, hour)` of the heaviest cell, or `nil` when the grid is flat
    /// empty — a busiest hour claimed over no data is a lie on a panel.
    public var busiest: (weekday: Int, hour: Int)? {
        var best: (weekday: Int, hour: Int, value: Int)?
        for (row, hours) in cells.enumerated() {
            for (hour, value) in hours.enumerated() where value > 0 {
                if best == nil || value > best!.value { best = (row, hour, value) }
            }
        }
        guard let best else { return nil }
        return (best.weekday, best.hour)
    }

    /// "busiest Tue 21:00", written out. Empty when there is no busiest hour.
    public var busiestLabel: String {
        guard let busiest else { return "" }
        return "busiest \(Self.weekdayNames[busiest.weekday]) \(String(format: "%02d:00", busiest.hour))"
    }

    /// Sunday first, matching `UsageHeatmap.cells`.
    public static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

public struct EInkUsageTotals: Sendable, Equatable {
    public var costUSD: Double
    public var tokens: Int64
    public var requests: Int
    /// Per-harness rows, heaviest spend first.
    public var rows: [EInkHarnessRow]

    public init(costUSD: Double = 0, tokens: Int64 = 0, requests: Int = 0, rows: [EInkHarnessRow] = []) {
        self.costUSD = costUSD
        self.tokens = tokens
        self.requests = requests
        self.rows = rows
    }

    public static let empty = EInkUsageTotals()
}

public struct EInkHarnessRow: Sendable, Equatable {
    /// Usage-axis name — the CLI or app, e.g. "Claude Code".
    public var label: String
    public var costUSD: Double
    public var tokens: Int64
    public var requests: Int

    public init(label: String, costUSD: Double, tokens: Int64, requests: Int) {
        self.label = label
        self.costUSD = costUSD
        self.tokens = tokens
        self.requests = requests
    }
}

/// The four windows, addressable by `EInkUsagePeriod`.
public struct EInkUsageSet: Sendable, Equatable {
    public var today: EInkUsageTotals
    public var week: EInkUsageTotals
    public var month: EInkUsageTotals
    public var allTime: EInkUsageTotals

    public init(
        today: EInkUsageTotals = .empty,
        week: EInkUsageTotals = .empty,
        month: EInkUsageTotals = .empty,
        allTime: EInkUsageTotals = .empty
    ) {
        self.today = today
        self.week = week
        self.month = month
        self.allTime = allTime
    }

    public subscript(period: EInkUsagePeriod) -> EInkUsageTotals {
        switch period {
        case .today: today
        case .week: week
        case .month: month
        case .allTime: allTime
        }
    }
}

public struct EInkTrendPoint: Sendable, Equatable {
    public var bucketStart: Date
    /// Day of month, zero padded: "07".
    public var dayLabel: String
    /// Abbreviated local weekday: "Fri".
    public var weekdayLabel: String
    public var costUSD: Double
    public var tokens: Int64

    public init(bucketStart: Date, dayLabel: String, weekdayLabel: String, costUSD: Double, tokens: Int64) {
        self.bucketStart = bucketStart
        self.dayLabel = dayLabel
        self.weekdayLabel = weekdayLabel
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

// MARK: - Formatting

/// Number formatting for the panel, ported byte-for-byte from the verified
/// demo's `data.py`.
///
/// The rules exist because the panel is 296 px wide and 1-bit: money is
/// written in full dollars with separators wherever it fits (`$121,216`),
/// cents appear only below $100, and the compact form is reserved for the
/// portrait table's 34 px column.
public enum EInkFormat {
    /// Fixed, locale-independent grouping: the panel's look must not change
    /// with the user's region, and the strings are asserted in tests.
    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfEven
        return formatter
    }()

    private static func grouped(_ value: Double) -> String {
        grouping.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    /// Full dollars with thousands separators; cents only under $100.
    public static func money(_ usd: Double) -> String {
        guard usd.isFinite else { return "$0.00" }
        if usd >= 100 { return "$" + grouped(usd) }
        if usd >= 10 { return "$" + String(format: "%.1f", usd) }
        return "$" + String(format: "%.2f", usd)
    }

    /// For columns too narrow for the full figure (the portrait table).
    public static func moneyCompact(_ usd: Double) -> String {
        guard usd.isFinite else { return "$0.00" }
        if usd >= 10_000 { return "$" + String(format: "%.0f", usd / 1000) + "k" }
        if usd >= 1000 { return "$" + String(format: "%.1f", usd / 1000) + "k" }
        return money(usd)
    }

    public static func tokens(_ count: Int64) -> String {
        tokens(Double(count))
    }

    public static func tokens(_ count: Double) -> String {
        guard count.isFinite else { return "0" }
        if count >= 1e9 { return String(format: "%.1f", count / 1e9) + "B" }
        if count >= 1e6 { return String(format: "%.0f", count / 1e6) + "M" }
        if count >= 1e3 { return String(format: "%.0f", count / 1e3) + "K" }
        return String(Int(count))
    }

    public static func int(_ value: Int) -> String { grouped(Double(value)) }

    public static func int(_ value: Int64) -> String { grouped(Double(value)) }

    /// `"5d 23h"` / `"3h 07m"` / `"42m"`, matching the demo exactly. An
    /// absent or elapsed deadline prints nothing / `0m`.
    public static func countdown(_ resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "" }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(String(format: "%02d", hours))h" }
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    /// `HH:mm` in the given calendar's time zone.
    public static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        formatted(date, calendar: calendar, format: "HH:mm")
    }

    /// `MM-dd` in the given calendar's time zone.
    public static func dateLabel(_ date: Date, calendar: Calendar) -> String {
        formatted(date, calendar: calendar, format: "MM-dd")
    }

    static func formatted(_ date: Date, calendar: Calendar, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// `MM-dd HH:mm` in the given calendar's time zone.
    public static func timestampLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}


/// The one-line provider health summary a header can carry.
///
/// English and unabbreviated like everything else the panel prints, and
/// deliberately *not* `StatusIndicator.summaryDescription`, which is copy and
/// is translated. The worst provider is named because that is the one the
/// reader can do something about; a clean board says so in one phrase.
public enum EInkProviderStatusLine {
    public static func compose(_ snapshots: [ServiceStatusSnapshot]) -> String {
        guard !snapshots.isEmpty else { return "" }
        let worst = snapshots
            .filter { $0.effectiveIndicator != .none }
            .max { $0.effectiveIndicator.severity < $1.effectiveIndicator.severity }
        guard let worst else { return "All providers operational" }
        return "\(worst.tool.vendorName): \(word(for: worst.effectiveIndicator))"
    }

    static func word(for indicator: StatusIndicator) -> String {
        switch indicator {
        case .none: "operational"
        case .maintenance: "under maintenance"
        case .minor: "degraded"
        case .major: "partial outage"
        case .critical: "major outage"
        }
    }
}
