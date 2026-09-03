import Foundation

public extension UsageHeatmap {
    /// Token totals collapsed across the 7 weekdays, indexed by hour 0..23.
    var hourTotals: [Int] {
        (0..<24).map { hour in
            cells.reduce(0) { $0 + $1[hour] }
        }
    }

    /// Hour of day with the highest aggregate token count across all weekdays,
    /// or nil if the heatmap is empty. Earliest hour wins on tie.
    var peakHour: Int? {
        let totals = hourTotals
        guard let max = totals.max(), max > 0 else { return nil }
        return totals.firstIndex(of: max)
    }

    /// The single (weekday, hour) cell with the highest token count, or nil
    /// if the heatmap is empty. Scan order is weekday 0..7 then hour 0..24,
    /// so the first-seen maximum wins on tie.
    var peakCell: (weekday: Int, hour: Int)? {
        var best: (value: Int, weekday: Int, hour: Int) = (0, 0, 0)
        for (d, row) in cells.enumerated() {
            for (h, v) in row.enumerated() where v > best.value {
                best = (v, d, h)
            }
        }
        return best.value > 0 ? (best.weekday, best.hour) : nil
    }

    /// Fixed reference zone for the hour-only formatter below.
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .current

    /// A 0..23 hour index as the app's language writes a clock hour —
    /// "3 PM" in English, "15时" in Chinese. Used in peak labels, axis ticks
    /// and cell tooltips, so the merged activity card never mixes styles.
    static func formatHourLabel(_ hour: Int) -> String {
        // A wall-clock hour with no date behind it, spelled the way the
        // app's language spells one: "3 PM" in English, "15时" in Chinese.
        // The reference day is fixed and UTC so only the hour survives.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let components = DateComponents(
            year: 2_000, month: 1, day: 1, hour: max(0, min(23, hour))
        )
        guard let date = calendar.date(from: components) else { return "" }
        return AppLocale.dateFormatter(template: "j", timeZone: Self.utc)
            .string(from: date)
    }
}
