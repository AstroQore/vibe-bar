import SwiftUI

/// Whether any Vibe Bar popover is currently on screen.
///
/// `StatusItemController` caches one `NSPopover` — and therefore one whole
/// SwiftUI hosting tree — per menu-bar kind for the life of the process, so a
/// *closed* popover's views are still alive and still ticking. This object is
/// the one thing a hidden tree can read to stop doing work. It is deliberately
/// not a teardown switch: nothing is deallocated, the hosting controller keeps
/// its state, and the next open is still a cache hit.
///
/// It mirrors what `AppEnvironment.setPopoverVisible` already computes; the two
/// are set from the same places in `StatusItemController` so they cannot drift.
final class PopoverPresentation: ObservableObject {
    @Published var isShown: Bool

    init(isShown: Bool = false) {
        self.isShown = isShown
    }

    /// What every host that is *not* the popover sees. Mini windows, the
    /// Workbench, Settings and the onboarding assistant are on screen whenever
    /// they exist, so their clocks must never be gated — and reading this
    /// through `@Environment` (which has a default) rather than
    /// `@EnvironmentObject` (which crashes when nothing injected it) means a
    /// clock that ends up in one of those trees keeps running instead of
    /// trapping.
    static let alwaysVisible = PopoverPresentation(isShown: true)
}

private struct PopoverPresentationKey: EnvironmentKey {
    static let defaultValue = PopoverPresentation.alwaysVisible
}

extension EnvironmentValues {
    var popoverPresentation: PopoverPresentation {
        get { self[PopoverPresentationKey.self] }
        set { self[PopoverPresentationKey.self] = newValue }
    }
}

/// A periodic timeline schedule with a *fixed* phase and an on/off switch.
///
/// Two things are wrong with `TimelineView(.periodic(from: .now, by: 30))`,
/// which is what every quota surface used to write:
///
/// 1. `.now` is re-evaluated on every body pass, so each surface — and each
///    re-render of the same surface — gets its own tick phase. Downstream that
///    means every consumer hands `QuotaService.paceForecast` a slightly
///    different `now`, and the memo it keeps on that input never hits. A 30 s
///    idle sample put 7.6% of main-thread time in exactly that recomputation.
/// 2. It keeps firing inside a popover that is closed but still hosted.
///
/// The anchor here is resolved once per process and floored to a five-minute
/// boundary, so the 30 s and 60 s clocks land on the same grid and every
/// surface asks for the same instant — one forecast per bucket per tick for
/// the whole app instead of one per row.
struct QuotaClockSchedule: TimelineSchedule {
    /// While false the schedule yields exactly one entry and then ends, so the
    /// view keeps its last rendered date and starts no timer at all.
    var isActive: Bool
    var interval: TimeInterval

    /// Process-wide phase anchor. Floored to a 5-minute boundary so clocks of
    /// different intervals stay in step with each other and with the
    /// forecast's own 5-minute quantization.
    static let anchor: Date = {
        let seconds = Date().timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 300).rounded(.down) * 300)
    }()

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let step = max(1, interval)
        let anchor = Self.anchor.timeIntervalSinceReferenceDate
        let elapsed = startDate.timeIntervalSinceReferenceDate - anchor
        // First entry is the grid point at or before `startDate`, so the view
        // renders immediately and every later entry stays on the grid.
        var tick = anchor + (elapsed / step).rounded(.down) * step
        let active = isActive
        var started = false
        return AnyIterator {
            if started {
                guard active else { return nil }
                tick += step
            } else {
                started = true
            }
            return Date(timeIntervalSinceReferenceDate: tick)
        }
    }
}

/// One periodic clock for a whole page, card, or window layout. Pass its date
/// down to the leaves as plain data — a row must never own a timer.
///
/// Use this for surfaces that are visible whenever they exist: mini windows,
/// the Workbench, Settings. Popover-hosted surfaces use `PageClock`.
struct StableClock<Content: View>: View {
    var interval: TimeInterval = 30
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        TimelineView(QuotaClockSchedule(isActive: true, interval: interval)) { context in
            content(context.date)
        }
    }
}

/// `StableClock` for popover-hosted surfaces: same fixed phase, but it stops
/// ticking while the popover is hidden and re-ticks on the next show.
///
/// Outside a popover (mini windows, Workbench, Settings) the environment's
/// default `PopoverPresentation` reports "shown", so this degrades to a plain
/// `StableClock` rather than freezing or crashing.
struct PageClock<Content: View>: View {
    var interval: TimeInterval = 30
    @ViewBuilder var content: (Date) -> Content

    @Environment(\.popoverPresentation) private var presentation

    var body: some View {
        GatedClock(presentation: presentation, interval: interval, content: content)
    }
}

/// The observing half of `PageClock`. `@Environment` hands over the object
/// without subscribing to it; `@ObservedObject` here is what turns an
/// open/close into a schedule change.
private struct GatedClock<Content: View>: View {
    @ObservedObject var presentation: PopoverPresentation
    var interval: TimeInterval
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        TimelineView(
            QuotaClockSchedule(isActive: presentation.isShown, interval: interval)
        ) { context in
            content(context.date)
        }
    }
}
