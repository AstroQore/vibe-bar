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

    public init(
        generatedAt: Date,
        generatedAtLabel: String,
        generatedAtISO: String,
        quota: [EInkQuotaRow],
        usage: EInkUsageSet,
        trend: [EInkTrendPoint]
    ) {
        self.generatedAt = generatedAt
        self.generatedAtLabel = generatedAtLabel
        self.generatedAtISO = generatedAtISO
        self.quota = quota
        self.usage = usage
        self.trend = trend
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

    public init(
        fieldID: String,
        providerDisplayName: String,
        windowTitle: String,
        remainingPercent: Int,
        resetAt: Date? = nil,
        countdown: String = "",
        plan: String = ""
    ) {
        self.fieldID = fieldID
        self.providerDisplayName = providerDisplayName
        self.windowTitle = windowTitle
        self.remainingPercent = max(0, min(100, remainingPercent))
        self.resetAt = resetAt
        self.countdown = countdown
        self.plan = plan
    }
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
