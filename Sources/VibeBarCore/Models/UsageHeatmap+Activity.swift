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

    /// 12-hour formatter for a 0..23 hour index — "12am", "3am", "12pm", "3pm".
    /// Used in peak labels, axis ticks, and cell tooltips so the merged
    /// activity card never mixes 12h and 24h styles.
    static func formatHourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12am"
        case 12: return "12pm"
        default: return hour < 12 ? "\(hour)am" : "\(hour - 12)pm"
        }
    }
}
