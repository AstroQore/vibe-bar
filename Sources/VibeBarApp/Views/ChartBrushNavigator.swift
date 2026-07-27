import SwiftUI
import VibeBarCore

/// Projection helper handed to a brush's mini-content builder.
///
/// The brush owns the domain → pixel mapping because its overlay already needs
/// it; exposing the same projection lets a caller draw whatever representation
/// suits its data — a thin line for quota remaining, bars for cost — without
/// re-deriving the geometry and drifting a pixel out of alignment.
struct ChartBrushGeometry {
    let size: CGSize
    let domainStart: Date
    let domainEnd: Date

    var domainSpan: TimeInterval { max(0, domainEnd.timeIntervalSince(domainStart)) }

    /// Seconds of domain covered by one point of width — the conversion every
    /// drag translation needs.
    var secondsPerPoint: TimeInterval {
        size.width > 0 ? domainSpan / TimeInterval(size.width) : 0
    }

    func x(for date: Date) -> CGFloat {
        guard domainSpan > 0 else { return 0 }
        let fraction = date.timeIntervalSince(domainStart) / domainSpan
        return CGFloat(min(1, max(0, fraction))) * size.width
    }

    func date(atX x: CGFloat) -> Date {
        guard size.width > 0 else { return domainStart }
        let fraction = min(1, max(0, Double(x / size.width)))
        return domainStart.addingTimeInterval(fraction * domainSpan)
    }

    /// `fraction` 0 is the bottom edge and 1 the top, inset so a full-scale
    /// value is not clipped by its own stroke width.
    func y(forFraction fraction: Double) -> CGFloat {
        let inset: CGFloat = 2
        let usable = max(0, size.height - inset * 2)
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return inset + usable * CGFloat(1 - clamped)
    }
}

/// Compact scrubber strip drawn under a navigable chart.
///
/// The strip always shows the *whole* domain; the highlighted rectangle is the
/// range the main chart is currently scaled to. Every gesture routes through
/// `ChartTimeWindow`, so the minimum span and the domain edges are enforced in
/// one tested place instead of once per chart.
///
/// Generic over the mini content so the same navigator serves a line-based
/// quota history and a future bar-based cost history: the caller receives a
/// `ChartBrushGeometry` and returns any view drawn in that coordinate space.
struct ChartBrushNavigator<Mini: View>: View {
    @Binding var window: ChartTimeWindow
    var accent: Color = .accentColor
    var height: CGFloat = 42
    /// Half-width of the grab zone around each window edge. Generous on
    /// purpose — the visible handle is a hairline, but a 10pt reach makes it
    /// catchable with a trackpad.
    var handleHitWidth: CGFloat = 10
    var accessibilityDescription: String = "Chart range navigator"
    @ViewBuilder var mini: (ChartBrushGeometry) -> Mini

    /// Which edge (if any) the in-flight drag grabbed. Classified once at the
    /// start of the gesture so a fast drag past the opposite edge does not flip
    /// the interpretation mid-stroke.
    private enum DragMode {
        case pan
        case resizeStart
        case resizeEnd
    }

    @State private var dragMode: DragMode?
    @State private var dragBase: ChartTimeWindow?

    var body: some View {
        GeometryReader { geo in
            let geometry = ChartBrushGeometry(
                size: geo.size,
                domainStart: window.domainStart,
                domainEnd: window.domainEnd
            )
            let startX = geometry.x(for: window.visibleStart)
            let endX = max(startX + 2, geometry.x(for: window.visibleEnd))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                mini(geometry)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // Everything outside the visible window reads as context, not
                // content: dim it rather than hiding it, so the user keeps the
                // shape of the full history while scrubbing.
                dimmed(from: 0, to: startX, height: geo.size.height)
                dimmed(from: endX, to: geo.size.width, height: geo.size.height)

                windowOverlay(startX: startX, endX: endX, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(drag(in: geometry))
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Overlay pieces

    @ViewBuilder
    private func dimmed(from: CGFloat, to: CGFloat, height: CGFloat) -> some View {
        let width = max(0, to - from)
        if width > 0 {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: width, height: height)
                .offset(x: from)
                .allowsHitTesting(false)
        }
    }

    private func windowOverlay(startX: CGFloat, endX: CGFloat, height: CGFloat) -> some View {
        let width = max(2, endX - startX)
        let handleHeight = max(8, height * 0.52)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(accent.opacity(0.85), lineWidth: 1.2)
                )
                .frame(width: width, height: height)

            handle(height: handleHeight)
                .offset(x: -1.5)
            handle(height: handleHeight)
                .offset(x: width - 1.5)
        }
        .frame(width: width, height: height, alignment: .leading)
        .offset(x: startX)
        .allowsHitTesting(false)
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(accent.opacity(0.95))
            .frame(width: 3, height: height)
    }

    // MARK: - Gesture

    private func drag(in geometry: ChartBrushGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geometry.size.width > 0, geometry.domainSpan > 0 else { return }
                if dragMode == nil {
                    classify(start: value.startLocation.x, in: geometry)
                }
                guard let mode = dragMode, let base = dragBase else { return }
                let delta = TimeInterval(value.translation.width) * geometry.secondsPerPoint
                switch mode {
                case .pan:
                    window = base.panned(by: delta)
                case .resizeStart:
                    window = resized(base, startDelta: delta)
                case .resizeEnd:
                    window = resized(base, endDelta: delta)
                }
            }
            .onEnded { _ in
                dragMode = nil
                dragBase = nil
            }
    }

    private func classify(start startX: CGFloat, in geometry: ChartBrushGeometry) {
        let x0 = geometry.x(for: window.visibleStart)
        let x1 = geometry.x(for: window.visibleEnd)
        if abs(startX - x0) <= handleHitWidth {
            dragMode = .resizeStart
            dragBase = window
        } else if abs(startX - x1) <= handleHitWidth {
            dragMode = .resizeEnd
            dragBase = window
        } else if startX > x0, startX < x1 {
            dragMode = .pan
            dragBase = window
        } else {
            // Outside the window: jump the window's centre to the press and
            // keep dragging from there, so a click and a click-drag are the
            // same gesture rather than two behaviours.
            let target = geometry.date(atX: startX)
            let recentred = window.panned(by: target.timeIntervalSince(window.visibleMidpoint))
            window = recentred
            dragMode = .pan
            dragBase = recentred
        }
    }

    private func resized(_ base: ChartTimeWindow, startDelta: TimeInterval) -> ChartTimeWindow {
        let latestStart = base.visibleEnd.addingTimeInterval(-base.effectiveMinimumSpan)
        let proposed = min(base.visibleStart.addingTimeInterval(startDelta), latestStart)
        return ChartTimeWindow(
            domainStart: base.domainStart,
            domainEnd: base.domainEnd,
            minimumSpan: base.minimumSpan,
            visibleStart: max(proposed, base.domainStart),
            visibleEnd: base.visibleEnd
        )
    }

    private func resized(_ base: ChartTimeWindow, endDelta: TimeInterval) -> ChartTimeWindow {
        let earliestEnd = base.visibleStart.addingTimeInterval(base.effectiveMinimumSpan)
        let proposed = max(base.visibleEnd.addingTimeInterval(endDelta), earliestEnd)
        return ChartTimeWindow(
            domainStart: base.domainStart,
            domainEnd: base.domainEnd,
            minimumSpan: base.minimumSpan,
            visibleStart: base.visibleStart,
            visibleEnd: min(proposed, base.domainEnd)
        )
    }
}

/// One drawable point on a quota line. Segment membership travels with the
/// point as `seriesKey` so Swift Charts never joins two sides of a reset (or of
/// a stretch where Vibe Bar was not running) into one stroke.
struct QuotaChartLinePoint: Identifiable {
    let id: String
    let seriesKey: String
    let time: Date
    let value: Double
}

/// Turning segmented series into Swift Charts marks.
///
/// Shared by the per-group chart inside Subscription Utilization and the
/// all-providers chart on the Overview: both clip to the visible window, thin
/// to a mark budget, and bridge the holes between segments, and the two have to
/// agree on all three or the same history would read differently depending on
/// which surface you looked at.
enum QuotaChartMarks {
    /// Clipped and thinned marks for a series' real observations.
    static func points<Element>(
        _ segments: [[Element]],
        kind: String,
        range: ClosedRange<Date>,
        limit: Int,
        time: (Element) -> Date,
        value: (Element) -> Double
    ) -> [QuotaChartLinePoint] {
        var result: [QuotaChartLinePoint] = []
        for (index, segment) in segments.enumerated() {
            let clipped = clip(segment, time: time, to: range)
            guard !clipped.isEmpty else { continue }
            let thinned = ChartSeriesThinning.strided(clipped, limit: limit)
            let key = "\(kind)-\(index)"
            for (offset, sample) in thinned.enumerated() {
                result.append(
                    QuotaChartLinePoint(
                        id: "\(key)-\(offset)",
                        seriesKey: key,
                        time: time(sample),
                        value: value(sample)
                    )
                )
            }
        }
        return result
    }

    /// Straight connectors across the holes between consecutive segments.
    ///
    /// A hole is real information — coverage stopped, or the window refilled —
    /// but a plot full of orphaned stubs reads as broken rather than as honest,
    /// so the shape is carried across it. The connector is deliberately not
    /// drawn like data (hairline, dashed, faint), it is never thinned, and the
    /// hover readout still reports nothing over a bridged span, because nothing
    /// was observed there.
    static func bridges<Element>(
        _ segments: [[Element]],
        kind: String,
        range: ClosedRange<Date>,
        time: (Element) -> Date,
        value: (Element) -> Double
    ) -> [QuotaChartLinePoint] {
        guard segments.count > 1 else { return [] }
        var result: [QuotaChartLinePoint] = []
        for index in 0..<(segments.count - 1) {
            guard let tail = segments[index].last,
                  let head = segments[index + 1].first
            else { continue }
            let start = time(tail)
            let end = time(head)
            // Overlap, not containment: a bridge that spans the whole visible
            // window has both endpoints outside it and still has to draw.
            guard end >= range.lowerBound, start <= range.upperBound else { continue }
            let key = "\(kind)-bridge-\(index)"
            result.append(
                QuotaChartLinePoint(id: "\(key)-0", seriesKey: key, time: start, value: value(tail))
            )
            result.append(
                QuotaChartLinePoint(id: "\(key)-1", seriesKey: key, time: end, value: value(head))
            )
        }
        return result
    }

    /// Keep one sample beyond each edge so a line entering the window starts at
    /// the frame border instead of at its first visible observation.
    static func clip<Element>(
        _ segment: [Element],
        time: (Element) -> Date,
        to range: ClosedRange<Date>
    ) -> [Element] {
        guard !segment.isEmpty else { return [] }
        var first: Int?
        var last: Int?
        for (index, element) in segment.enumerated() {
            let stamp = time(element)
            if stamp >= range.lowerBound, stamp <= range.upperBound {
                if first == nil { first = index }
                last = index
            }
        }
        guard let first, let last else { return [] }
        let lower = max(0, first - 1)
        let upper = min(segment.count - 1, last + 1)
        return Array(segment[lower...upper])
    }

    /// How a bridge is stroked, everywhere one is drawn.
    static let bridgeStroke = StrokeStyle(lineWidth: 1, dash: [2, 3])
    static let bridgeOpacity: Double = 0.35
}

/// Preset-span selector for a navigable chart: "6h · 24h · 3d · 7d · All".
///
/// Only spans the recorded domain can actually show are offered, and the
/// current one is highlighted by comparing against the live window rather than
/// by remembering which pill was last tapped — so a pan or a pinch quietly
/// deselects instead of leaving a lie on screen.
struct ChartRangePills: View {
    @Binding var window: ChartTimeWindow
    var fontSize: CGFloat = 10
    /// Called after a pill changes the window, so a chart can drop a stale
    /// hover crosshair.
    var onSelect: () -> Void = {}

    private struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let span: TimeInterval?
        let isSelected: Bool
    }

    private static let spans: [(String, TimeInterval)] = [
        ("6h", 6 * 3_600),
        ("24h", 24 * 3_600),
        ("3d", 3 * 86_400),
        ("7d", 7 * 86_400)
    ]

    private var options: [Option] {
        guard window.domainSpan > 0 else { return [] }
        var result = Self.spans
            .filter { $0.1 < window.domainSpan }
            .map { label, span in
                Option(
                    id: label,
                    label: label,
                    span: span,
                    isSelected: !window.coversDomain
                        && window.isAtDomainEnd
                        && abs(window.visibleSpan - span) <= span * 0.03
                )
            }
        result.append(Option(id: "all", label: "All", span: nil, isSelected: window.coversDomain))
        return result
    }

    var isEmpty: Bool { options.isEmpty }

    var body: some View {
        let options = self.options
        if !options.isEmpty {
            HStack(spacing: 1) {
                ForEach(options) { option in
                    Button {
                        window.jump(toSpan: option.span ?? window.domainSpan)
                        onSelect()
                    } label: {
                        Text(option.label)
                            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(option.isSelected ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .background {
                        if option.isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                        }
                    }
                    .accessibilityLabel(option.label)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Uniform-stride thinning for brush minis and zoomed-out main charts.
///
/// Purely a drawing concern — the series itself keeps every observation, this
/// only decides how many of them are worth turning into marks at the current
/// scale.
enum ChartSeriesThinning {
    static func strided<Element>(_ elements: [Element], limit: Int) -> [Element] {
        guard limit > 1, elements.count > limit else { return elements }
        let step = Double(elements.count - 1) / Double(limit - 1)
        var result: [Element] = []
        result.reserveCapacity(limit)
        var lastIndex = -1
        for slot in 0..<limit {
            let index = min(elements.count - 1, Int((Double(slot) * step).rounded()))
            if index != lastIndex {
                result.append(elements[index])
                lastIndex = index
            }
        }
        // The newest sample carries the "where are we now" reading, so never
        // let rounding drop it.
        if lastIndex != elements.count - 1 {
            result.append(elements[elements.count - 1])
        }
        return result
    }
}
