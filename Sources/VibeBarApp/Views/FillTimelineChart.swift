import SwiftUI
import VibeBarCore

/// One independently resettable quota shown in Fill History. The account id
/// is part of the identity because the Gemini page combines Gemini Web and
/// AntiGravity, whose bucket ids can otherwise overlap.
struct FillTimelineSeries: Identifiable {
    let tool: ToolType
    let accountId: String
    let bucket: QuotaBucket

    var id: String { "\(tool.rawValue):\(accountId):\(bucket.id)" }
}

/// Reset-cycle utilization history. Each bar is one subscription cycle and
/// answers the useful question: how much quota was still unused when the
/// provider refilled it? The final outlined bar is the active cycle.
struct FillTimelineChart: View {
    let series: FillTimelineSeries
    let mode: DisplayMode
    let density: Theme.Density
    let targetPercent: Double?

    @EnvironmentObject var quotaService: QuotaService
    @State private var hoveredIndex: Int?

    /// The visible window memoized on the samples it was built from. Hovering
    /// the strip writes `hoveredIndex`, which re-runs `body`, which used to
    /// re-sort the bucket's whole retained history on every mouse move. A
    /// reference box on purpose: filling it during `body` must not dirty view
    /// state.
    private final class CycleCache {
        var key: SubscriptionHistoryKey?
        var samples: [SubscriptionWindowSample] = []
        var limit = 0
        var visible: [SubscriptionWindowSample] = []
    }

    @State private var cycleCache = CycleCache()
    /// Strip width, updated only when it changes. The number of cycles worth
    /// drawing is a function of it.
    @State private var stripWidth: CGFloat = 0

    /// Most cycles the strip will draw, however wide it gets.
    ///
    /// A legibility budget, not a storage one — `SubscriptionHistoryStore`
    /// keeps every cycle it ever recorded, and the busiest lane on a real Mac
    /// holds a couple of hundred. Past this many the strip stops being a shape
    /// you can read and becomes texture.
    private static let maximumCycles = 60

    /// Bar width the count is derived from. `cycleStrip` never draws narrower
    /// than the geometry allows, so deriving from a slightly generous figure is
    /// what keeps a little air between bars at the wide end.
    private static let preferredBarWidth: CGFloat = 6

    /// Until the strip has been measured. Small enough to look deliberate for
    /// the one frame before the real width arrives.
    private static let unmeasuredCycles = 12

    /// As many cycles as fit at `preferredBarWidth`, capped.
    ///
    /// Fewer bars beats unreadable ones: the count comes down until each bar
    /// has room, rather than the bars thinning to hairlines to fit a count.
    private func maxCycles(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return Self.unmeasuredCycles }
        let slot = Self.preferredBarWidth + barSpacing
        return min(Self.maximumCycles, max(4, Int((width + barSpacing) / slot)))
    }

    /// Band above the bars holding the early-refill dots. Always reserved, so
    /// the strip does not change height when a cycle refills early.
    private var markerBand: CGFloat { 5 }

    private var barSpacing: CGFloat {
        switch density.profile {
        case .compact: 2
        case .regular: 3
        case .spacious: 4
        }
    }

    private var chartHeight: CGFloat {
        switch density.profile {
        case .compact: 40
        case .regular: 52
        case .spacious: 66
        }
    }

    var body: some View {
        let cycles = visibleCycles(series: series, limit: maxCycles(forWidth: stripWidth))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Reset history")
                    .font(.system(size: max(9, density.subtitleFontSize - 2), weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text("Each bar is one quota cycle")
                    .font(.system(size: max(7.5, density.subtitleFontSize - 4)))
                    .foregroundStyle(.quaternary)
            }
            cycleStrip(cycles, tool: series.tool, targetPercent: targetPercent)
            Text(caption(cycles))
                .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            earlyRefillNote(cycles)
            axis(cycles)
        }
        .padding(.top, 4)
    }

    private func visibleCycles(
        series: FillTimelineSeries,
        limit: Int
    ) -> [SubscriptionWindowSample] {
        let key = SubscriptionHistoryKey(accountId: series.accountId, bucketId: series.bucket.id)
        let samples = quotaService.historyByAccountBucket[key] ?? []
        // An equality check over the retained samples is far cheaper than the
        // sort plus the per-element date resolution it drives. The limit is
        // part of the key: it moves with the strip's width.
        if cycleCache.key == key, cycleCache.limit == limit, cycleCache.samples == samples {
            return cycleCache.visible
        }
        let visible = Array(samples.sorted { cycleDate($0) < cycleDate($1) }.suffix(limit))
        cycleCache.key = key
        cycleCache.samples = samples
        cycleCache.limit = limit
        cycleCache.visible = visible
        return visible
    }

    /// The strip: one bar per cycle, the early-refill dots above them and the
    /// safety target across them — all in one `Canvas`.
    ///
    /// One drawing surface because the count is now width-derived and can
    /// reach sixty (`AGENTS.md` § 11: dense status history is one drawing
    /// surface, not hundreds of views). The per-bar `ForEach` this replaces
    /// was two views per cycle plus a second `ForEach` for the dots, and a
    /// provider page draws one of these strips per bucket.
    @ViewBuilder
    private func cycleStrip(
        _ cycles: [SubscriptionWindowSample],
        tool: ToolType,
        targetPercent: Double?
    ) -> some View {
        if cycles.isEmpty {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.barTrack.opacity(0.45))
                .overlay {
                    Text("Waiting for the first quota observation")
                        .font(.system(size: max(8, density.subtitleFontSize - 3)))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: chartHeight)
        } else {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let accent = Theme.providerAccent(for: tool)
                let barWidth = Self.barWidth(in: size.width, count: cycles.count, spacing: barSpacing)
                let top = markerBand
                let plotHeight = max(1, size.height - top)
                for (index, cycle) in cycles.enumerated() {
                    let x = CGFloat(index) * (barWidth + barSpacing)
                    let isHovered = hoveredIndex == index
                    let rect = CGRect(x: x, y: top, width: barWidth, height: plotHeight)
                    let radius = min(3, barWidth / 2)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                        with: .color(Theme.barTrack.opacity(isHovered ? 0.95 : 0.62))
                    )
                    // The 4% floor keeps a spent cycle visible as a sliver
                    // rather than an empty track, exactly as the bars did when
                    // they were views and scaled themselves.
                    let percent = displayedPercent(cycle)
                    let fillHeight = max(plotHeight * 0.04, plotHeight * percent / 100)
                    context.fill(
                        Path(
                            roundedRect: CGRect(
                                x: x,
                                y: rect.maxY - fillHeight,
                                width: barWidth,
                                height: fillHeight
                            ),
                            cornerRadius: min(radius, fillHeight / 2),
                            style: .continuous
                        ),
                        with: .color(accent.opacity(isHovered ? 1 : 0.86))
                    )
                    if !cycle.isCompleted {
                        context.stroke(
                            Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
                            with: .color(accent.opacity(0.9)),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                    }
                    // Above the bar, not inside it: a cycle that spent all of
                    // its quota fills its track to the top, where a marker
                    // would be the same colour as the fill under it. Shrinks
                    // with the bar so it never overlaps its neighbour.
                    if cycle.refilledEarly {
                        let diameter = min(3, barWidth)
                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: rect.midX - diameter / 2,
                                    y: max(0, top - diameter) / 2,
                                    width: diameter,
                                    height: diameter
                                )
                            ),
                            with: .color(accent.opacity(0.8))
                        )
                    }
                }
                if let targetPercent, targetPercent > 3, targetPercent < 97 {
                    let y = top + plotHeight * (1 - targetPercent / 100)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        path,
                        with: .color(Color.primary.opacity(0.34)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                }
            }
            .frame(height: chartHeight + markerBand)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                stripWidth = width
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let barWidth = Self.barWidth(
                        in: stripWidth,
                        count: cycles.count,
                        spacing: barSpacing
                    )
                    hoveredIndex = min(
                        max(0, Int(location.x / (barWidth + barSpacing))),
                        cycles.count - 1
                    )
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
    }

    /// One bar's width. Shared by the draw and the hit test so the caption can
    /// never describe a cycle the cursor is not over.
    ///
    /// No lower floor: the count is chosen so the natural width clears
    /// `preferredBarWidth`, and flooring it instead would push the last bars
    /// off the end of the strip during the frame after a resize.
    private static func barWidth(in width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(1, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
    }

    @ViewBuilder
    private func earlyRefillNote(_ cycles: [SubscriptionWindowSample]) -> some View {
        let early = cycles.filter(\.refilledEarly).count
        if early > 0 {
            Text(
                early == 1
                    ? "1 cycle refilled before the window was up"
                    : "\(early) cycles refilled before the window was up"
            )
            .font(.system(size: max(7.5, density.subtitleFontSize - 4), design: .rounded))
            .foregroundStyle(.quaternary)
        }
    }

    /// What the provider did to the clock, when it did anything unusual. The
    /// two early shapes mean opposite things, so the caption says which.
    private func resetDescription(_ cycle: SubscriptionWindowSample) -> String {
        switch cycle.resetKind {
        case .earlyClockRestarted: " · refilled early, next window restarted"
        case .earlyClockUnchanged: " · refilled early, next reset unchanged"
        case .earlyUnclear: " · refilled early, onto a different schedule"
        case .onSchedule, .unobserved, nil: ""
        }
    }

    private func caption(_ cycles: [SubscriptionWindowSample]) -> String {
        guard !cycles.isEmpty else {
            return "A cycle is recorded when the quota refills"
        }
        let index = hoveredIndex.map { min(max(0, $0), cycles.count - 1) } ?? cycles.count - 1
        let cycle = cycles[index]
        let used = Int(cycle.peakUsedPercent.rounded())
        let left = Int(cycle.remainingPercentAtReset.rounded())
        if let completedAt = cycle.completedAt {
            let samplingGap = completedAt.timeIntervalSince(cycle.lastSeenAt)
            let gapText: String
            if samplingGap >= 60,
               let duration = ResetCountdownFormatter.string(from: completedAt, now: cycle.lastSeenAt) {
                gapText = " · last seen \(duration) before reset"
            } else {
                gapText = ""
            }
            return "\(Self.timestampFormatter.string(from: completedAt)) reset · \(used)% used · \(left)% left\(resetDescription(cycle))\(gapText)"
        }
        return "Current cycle · \(used)% used so far · \(left)% left"
    }

    @ViewBuilder
    private func axis(_ cycles: [SubscriptionWindowSample]) -> some View {
        if !cycles.isEmpty {
            HStack {
                Text(axisLabel(cycles[0]))
                Spacer()
                if cycles.count > 2 {
                    Text(axisLabel(cycles[cycles.count / 2]))
                    Spacer()
                }
                Text(cycles.last?.isCompleted == false ? "Current" : axisLabel(cycles[cycles.count - 1]))
            }
            .font(.system(size: max(7.5, density.subtitleFontSize - 4), design: .rounded))
            .foregroundStyle(.tertiary)
        }
    }

    private func displayedPercent(_ cycle: SubscriptionWindowSample) -> Double {
        switch mode {
        case .used: cycle.peakUsedPercent
        case .remaining: cycle.remainingPercentAtReset
        }
    }

    private func cycleDate(_ cycle: SubscriptionWindowSample) -> Date {
        cycle.completedAt ?? cycle.lastSeenAt
    }

    private func axisLabel(_ cycle: SubscriptionWindowSample) -> String {
        Self.dayFormatter.string(from: cycleDate(cycle))
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var timestampFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMdHHmm")
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var dayFormatter: DateFormatter {
        AppLocale.dateFormatter(template: "MMMd")
    }
}
