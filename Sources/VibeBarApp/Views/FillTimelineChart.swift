import SwiftUI
import VibeBarCore

/// CodexBar-style fill history: a Session | Weekly segmented control, a
/// strip of thin per-slot bars (light track, accent fill proportional to
/// used%), date ticks along the bottom, and a caption line that follows the
/// hovered bar ("Jul 2 at 16:23: 24% used").
///
/// Data comes from `QuotaService.fillTimelineByAccountBucket` — hourly
/// point-in-time samples recorded on every quota refresh. The chart shows
/// the last 7 days; slots without a sample render as an empty track, which
/// is also how a fresh install looks until history accumulates.
struct FillTimelineChart: View {
    let tool: ToolType
    /// Headline buckets of the account (groupTitle == nil), in display order.
    let buckets: [QuotaBucket]
    let accountId: String
    let mode: DisplayMode
    let density: Theme.Density
    let now: Date

    @EnvironmentObject var quotaService: QuotaService
    @State private var selectedBucketId: String?
    /// Resolved at hover time inside the strip, where the live slot grid is
    /// in scope — keeps the caption pinned to the exact bar under the cursor
    /// regardless of the rendered width.
    @State private var hovered: HoveredSlot?

    private struct HoveredSlot: Equatable {
        let index: Int
        let start: Date
        let point: FillTimelinePoint?
    }

    private static let spanDays: Double = 7
    private static let barSpacing: CGFloat = 2
    private static let minBarWidth: CGFloat = 2.5
    private static let maxSlots = 84   // 2h slots over 7 days
    private static let chartHeight: CGFloat = 40

    var body: some View {
        let tabs = availableTabs
        if tabs.isEmpty {
            EmptyView()
        } else {
            let activeBucketId = selectedBucketId.flatMap { id in
                tabs.contains(where: { $0.bucketId == id }) ? id : nil
            } ?? tabs.first!.bucketId
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Fill history")
                        .font(.system(size: max(9, density.subtitleFontSize - 2)))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if tabs.count > 1 {
                        Picker("", selection: Binding(
                            get: { activeBucketId },
                            set: { selectedBucketId = $0; hovered = nil }
                        )) {
                            ForEach(tabs, id: \.bucketId) { tab in
                                Text(tab.label).tag(tab.bucketId)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                strip(bucketId: activeBucketId)
                caption(bucketId: activeBucketId)
                axisLabels
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Tabs

    private var availableTabs: [(bucketId: String, label: String)] {
        buckets.map { bucket in
            (bucketId: bucket.id, label: Self.tabLabel(for: bucket))
        }
    }

    private static func tabLabel(for bucket: QuotaBucket) -> String {
        switch bucket.id {
        case "five_hour": return "Session"
        case "weekly":    return "Weekly"
        case "monthly":   return "Monthly"
        default:          return bucket.title
        }
    }

    // MARK: - Slots

    private struct Slot: Identifiable {
        let index: Int
        let start: Date
        let point: FillTimelinePoint?
        var id: Int { index }
    }

    private func slots(bucketId: String, count: Int) -> [Slot] {
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucketId)
        let points = quotaService.fillTimelineByAccountBucket[key] ?? []
        let spanSeconds = Self.spanDays * 86_400
        let slotSeconds = spanSeconds / Double(count)
        let windowStart = now.addingTimeInterval(-spanSeconds)
        var slots: [Slot] = []
        for index in 0..<count {
            let start = windowStart.addingTimeInterval(Double(index) * slotSeconds)
            let end = start.addingTimeInterval(slotSeconds)
            // Latest sample inside the slot wins — matches the store's
            // last-in-hour-wins semantics at coarser granularity.
            let point = points.last { $0.sampledAt >= start && $0.sampledAt < end }
            slots.append(Slot(index: index, start: start, point: point))
        }
        return slots
    }

    private func slotCount(for width: CGFloat) -> Int {
        let per = Self.minBarWidth + Self.barSpacing
        guard width > per else { return 1 }
        return max(12, min(Self.maxSlots, Int(width / per)))
    }

    @ViewBuilder
    private func strip(bucketId: String) -> some View {
        GeometryReader { geo in
            let count = slotCount(for: geo.size.width)
            let slots = slots(bucketId: bucketId, count: count)
            let barWidth = max(
                Self.minBarWidth,
                (geo.size.width - CGFloat(count - 1) * Self.barSpacing) / CGFloat(count)
            )
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(slots) { slot in
                    slotBar(slot: slot, width: barWidth, height: geo.size.height)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let index = min(max(0, Int(location.x / (barWidth + Self.barSpacing))), count - 1)
                    let slot = slots[index]
                    hovered = HoveredSlot(index: index, start: slot.start, point: slot.point)
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
    }

    @ViewBuilder
    private func slotBar(slot: Slot, width: CGFloat, height: CGFloat) -> some View {
        let isHovered = hovered?.index == slot.index
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                .fill(Theme.barTrack)
                .opacity(isHovered ? 0.9 : 0.55)
            if let point = slot.point {
                let percent = displayPercent(point.usedPercent)
                RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                    .fill(Self.accent(for: tool))
                    .opacity(isHovered ? 1.0 : 0.85)
                    .frame(height: max(2, height * CGFloat(percent / 100)))
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: - Caption & axis

    private func caption(bucketId: String) -> some View {
        Text(captionString(bucketId: bucketId))
            .font(.system(size: max(8, density.subtitleFontSize - 3), design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func captionString(bucketId: String) -> String {
        if let hovered {
            if let point = hovered.point {
                return Self.captionText(point: point, mode: mode)
            }
            return Self.dayFormatter.string(from: hovered.start) + ": no data"
        }
        let key = SubscriptionHistoryKey(accountId: accountId, bucketId: bucketId)
        let points = quotaService.fillTimelineByAccountBucket[key] ?? []
        if let latest = points.max(by: { $0.sampledAt < $1.sampledAt }) {
            return Self.captionText(point: latest, mode: mode)
        }
        return "No samples yet — fills in as Vibe Bar refreshes"
    }

    private var axisLabels: some View {
        HStack {
            ForEach(0..<4, id: \.self) { index in
                if index > 0 { Spacer(minLength: 4) }
                Text(Self.dayFormatter.string(
                    from: now.addingTimeInterval((-Self.spanDays + Double(index) * Self.spanDays / 3) * 86_400)
                ))
                .font(.system(size: max(7.5, density.subtitleFontSize - 4), design: .rounded))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func displayPercent(_ used: Double) -> Double {
        switch mode {
        case .used:      return used
        case .remaining: return max(0, 100 - used)
        }
    }

    private static func captionText(point: FillTimelinePoint, mode: DisplayMode) -> String {
        let stamp = timestampFormatter.string(from: point.sampledAt)
        switch mode {
        case .used:
            return "\(stamp): \(Int(point.usedPercent.rounded()))% used"
        case .remaining:
            return "\(stamp): \(Int((100 - point.usedPercent).rounded()))% left"
        }
    }

    private static func accent(for tool: ToolType) -> Color {
        switch tool {
        case .codex:  return Color(red: 0.30, green: 0.78, blue: 0.74)
        case .claude: return Color(red: 0.93, green: 0.40, blue: 0.40)
        case .gemini: return Color(red: 0.34, green: 0.62, blue: 0.96)
        case .grok:   return Color(red: 0.45, green: 0.45, blue: 0.50)
        default:      return Color(red: 0.45, green: 0.55, blue: 0.65)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d 'at' HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}
