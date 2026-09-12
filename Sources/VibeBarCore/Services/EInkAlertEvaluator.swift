import Foundation

/// Decides when a panel should drop what it is showing and shout.
///
/// Pure, and separate from the sync engine, because it is the part that is
/// easy to get subtly wrong and impossible to eyeball on a panel across the
/// room: an alert that re-fires on every refresh is a panel that flashes all
/// day, and one that never clears is a panel stuck on yesterday's problem.
public enum EInkAlertEvaluator {
    /// The bucket this device should be alerting about, or `nil`.
    ///
    /// Only buckets the device actually *shows* can trip it. A panel that
    /// flips to an alert about a bucket it never displays is a panel telling
    /// the reader about something they did not ask it to watch.
    public static func offendingFieldID(
        device: EInkDeviceConfig,
        snapshot: EInkDataSnapshot,
        layouts: [String: EInkCanvasLayout] = [:]
    ) -> String? {
        guard device.alerts.enabled else { return nil }
        let watched = watchedFieldIDs(device, layouts: layouts)
        let candidates = snapshot.quota.filter { row in
            guard watched.map({ $0.contains(row.fieldID) }) ?? true else { return false }
            return isAlerting(row, threshold: device.alerts.thresholdPercent)
        }
        // The worst one. Two buckets in trouble is still one panel, and the
        // reader wants the one that runs out first.
        return candidates.min { $0.remainingPercent < $1.remainingPercent }?.fieldID
    }

    /// A bucket alerts when it is at or below the threshold, or when the pace
    /// model says it will not make it. The second is the one that catches a
    /// bucket at 40 % on a Monday that is going to be gone by Wednesday.
    public static func isAlerting(_ row: EInkQuotaRow, threshold: Int) -> Bool {
        if row.remainingPercent <= threshold { return true }
        return row.forecast?.verdict == .atRisk
    }

    /// Every quota bucket any of this device's slides actually *draws*, or
    /// `nil` when one of them draws whatever Vibe Bar's own order gives it.
    ///
    /// Three answers, not two, and the distinction is the whole point:
    ///
    /// - a set: alert only about these.
    /// - `nil`: a quota slide with no selection of its own draws the default
    ///   priority order, so every bucket in the snapshot is on screen.
    /// - the empty set: this device draws no quota at all, so it never alerts.
    ///   A slide keeps the buckets it had when it was switched to a usage
    ///   layout — deliberately, so switching back does not lose them — and
    ///   without this an unseen bucket could replace a Heatmap with news from
    ///   nowhere.
    public static func watchedFieldIDs(
        _ device: EInkDeviceConfig,
        layouts: [String: EInkCanvasLayout] = [:]
    ) -> Set<String>? {
        var result = Set<String>()
        for slide in device.slides {
            if let preset = slide.kind.preset {
                guard preset.isQuotaPreset else { continue }
                if slide.quotaFieldIDs.isEmpty { return nil }
                result.formUnion(slide.quotaFieldIDs)
                continue
            }
            for layout in slide.allLayouts(in: layouts) {
                for element in layout.elements {
                    result.formUnion(element.quotaFieldIDs)
                    // A quota block with no selection of its own draws the
                    // slide's buckets, and a slide with none draws the default
                    // order.
                    guard element.kind.preset?.isQuotaPreset == true, element.fieldIDs.isEmpty else { continue }
                    if slide.quotaFieldIDs.isEmpty { return nil }
                    result.formUnion(slide.quotaFieldIDs)
                }
            }
        }
        return result
    }

    /// The slide the engine pushes while the alert stands.
    ///
    /// It is built rather than configured: an alert names the bucket that just
    /// tripped, and there is nothing about that a user could have chosen in
    /// advance.
    public static func alertSlide(fieldID: String) -> EInkSlide {
        EInkSlide(
            id: alertSlideID,
            title: "Alert",
            kind: .preset(.alert),
            quotaFieldIDs: [fieldID],
            usagePeriods: [],
            // No header choice, no footer, no reordering: the alert is the
            // engine's own panel and stays the same wherever it appears.
            options: EInkSlideOptions(header: EInkBarConfig(), footer: nil)
        )
    }

    public static let alertSlideID = "vibe-bar-alert"

    /// The soonest reset ahead of `now`, which is when the numbers behind the
    /// panel will next jump on their own.
    public static func nextResetAt(_ snapshot: EInkDataSnapshot, after now: Date) -> Date? {
        snapshot.quota
            .compactMap(\.resetAt)
            .filter { $0 > now }
            .min()
    }

    /// True when a reset the last pass was waiting for has happened.
    public static func resetBoundaryPassed(recorded: Date?, now: Date) -> Bool {
        guard let recorded else { return false }
        return now >= recorded
    }
}

/// Where "Tap link → Vibe Bar remote dashboard" points.
///
/// Only when Remote is actually configured on this Mac: a panel whose tap
/// opens a dashboard nobody has joined is worse than one that does nothing.
/// The link is the control center's own origin rather than a guessed
/// per-workspace path — a tap that lands on a 404 is the one outcome a
/// glanceable surface cannot explain.
public enum EInkRemoteDashboard {
    public static let controlCenter = URL(string: "https://vibebar.aqor.io")!

    public static func current() -> URL? {
        guard (try? RemoteCoreConfigStore.load()) != nil else { return nil }
        return controlCenter
    }
}
