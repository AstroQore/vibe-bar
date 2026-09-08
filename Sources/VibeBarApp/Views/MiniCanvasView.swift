import SwiftUI
import VibeBarCore

extension MiniCanvasElement.Kind {
    var title: String {
        switch self {
        case .ring: return L10n.Settings.MiniCanvas.ring
        case .horizontalBar: return L10n.Settings.MiniCanvas.horizontalBar
        case .verticalBar: return L10n.Settings.MiniCanvas.verticalBar
        case .sector: return L10n.Settings.MiniCanvas.sector
        case .text: return L10n.MenuBar.Composer.Block.text
        case .quotaRing, .quotaBar, .ledger, .strip, .tile, .focus, .rail:
            return presetMode?.label ?? L10n.Settings.MiniCanvas.unavailable
        }
    }
    var symbol: String {
        switch self {
        case .ring: return "circle.dashed.inset.filled"
        case .horizontalBar: return "rectangle.lefthalf.filled"
        case .verticalBar: return "rectangle.bottomhalf.filled"
        case .sector: return "chart.pie"
        case .text: return "textformat"
        case .quotaRing: return "gauge.with.dots.needle.67percent"
        case .quotaBar: return "chart.bar.fill"
        case .ledger: return "list.bullet.rectangle"
        case .strip: return "rectangle.split.3x1"
        case .tile: return "square.grid.2x2"
        case .focus: return "scope"
        case .rail: return "calendar.badge.clock"
        }
    }
}

/// The same live content in the panel and Studio. Editing ornaments belong
/// to MiniCanvasStage, never to the renderer or the stored layout.
struct MiniCanvasView: View {
    let layout: MiniCanvasLayout
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    var body: some View {
        let layout = layout.normalized()
        TimelineView(QuotaClockSchedule(
            isActive: layout.elements.contains { $0.kind.presetMode != nil || ($0.kind == .text && ($0.textContent == .countdown || $0.textContent == .pace)) },
            interval: 30
        )) { clock in
            ZStack(alignment: .topLeading) {
                Color.clear
                if layout.elements.isEmpty {
                    Text(L10n.Settings.MiniCanvas.empty)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
                ForEach(layout.elements) { element in
                    elementView(element, now: clock.date)
                        .frame(width: element.width, height: element.height)
                        .clipped()
                        .offset(x: element.x, y: element.y)
                }
            }
            .frame(width: layout.width, height: layout.height)
            .clipped()
        }
    }

    private func elementView(_ element: MiniCanvasElement, now: Date) -> some View {
        let field = element.fieldID.flatMap { MenuBarFieldCatalog.field(id: $0, registry: quotaService.fieldRegistry) }
        let bucket = field.flatMap { environment.quota(for: $0.tool)?.bucket(id: $0.bucketId) }
        let percent = field.flatMap { field in
            bucket.flatMap { $0.hasPercentage ? $0.displayPercent(settingsStore.settings.displayMode, tool: field.tool) : nil }
        }
        let fraction = percent.map { min(1, max(0, $0 / 100)) } ?? 0
        let color = elementColor(element, field: field, percent: percent)
        let stroke = min(element.thickness, min(element.width, element.height) / 4)
        let label = field.map(MenuBarTokenNaming.fieldTitle) ?? L10n.Settings.MiniCanvas.unavailable
        return Group {
            switch element.kind {
            case .text:
                Text(Self.resolvedText(element, label: label, percent: percent, bucket: bucket, now: now))
                    .font(.system(size: element.fontSize, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(element.textContent == .percent || element.textContent == .countdown ? 1 : nil)
                    .minimumScaleFactor(0.45)
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .ring:
                ZStack {
                    Circle().stroke(color.opacity(0.15), lineWidth: stroke)
                    if percent != nil {
                        Circle().trim(from: 0, to: fraction)
                            .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .padding(stroke / 2)
            case .horizontalBar, .verticalBar:
                GeometryReader { geometry in
                    let vertical = element.kind == .verticalBar
                    ZStack(alignment: vertical ? .bottom : .leading) {
                        Capsule().fill(color.opacity(0.15))
                        if percent != nil {
                            Capsule().fill(color)
                                .frame(width: vertical ? geometry.size.width : geometry.size.width * fraction,
                                       height: vertical ? geometry.size.height * fraction : geometry.size.height)
                        }
                    }
                }
            case .quotaRing, .quotaBar, .ledger, .strip, .tile, .focus, .rail:
                if let field, let bucket {
                    let entry = MiniEntry(
                        tool: field.tool, field: field, bucket: bucket,
                        subProviderName: field.tool.quotaSubProviderName(bucketID: field.bucketId),
                        subProviderDisplayName: field.tool.quotaSubProviderName(bucketID: field.bucketId),
                        companyName: field.tool.vendorName, groupLabel: bucket.groupTitle,
                        customLabel: element.text.isEmpty ? nil : element.text
                    )
                    MiniCanvasPresetWidget(kind: element.kind, entry: entry, now: now)
                } else {
                    Text(L10n.Settings.MiniCanvas.unavailable).font(.caption).foregroundStyle(.secondary)
                }
            case .sector:
                ZStack {
                    Circle().fill(color.opacity(0.15))
                    if percent != nil { MiniCanvasSector(fraction: fraction).fill(color) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(element.kind == .text
                            ? Self.resolvedText(element, label: label, percent: percent, bucket: bucket, now: now)
                            : "\(element.kind.title) · \(label)")
        .accessibilityValue(percent.map { L10n.Common.percent(value: Int($0.rounded())) } ?? L10n.Settings.MiniCanvas.unavailable)
        .help(label)
    }

    static func resolvedText(_ element: MiniCanvasElement, label: String, percent: Double?, bucket: QuotaBucket?, now: Date) -> String {
        switch element.textContent {
        case .custom: return element.text
        case .label: return label
        case .percent: return percent.map { L10n.Common.percent(value: Int($0.rounded())) } ?? "—"
        case .countdown: return ResetCountdownFormatter.string(from: bucket?.resetAt, now: now) ?? "—"
        case .pace: return bucket.flatMap { UsagePace.compute(bucket: $0, now: now, allowsPostResetGrace: true) }?.stageSummary ?? "—"
        }
    }

    private func elementColor(_ element: MiniCanvasElement, field: MenuBarFieldOption?, percent: Double?) -> Color {
        switch element.colour {
        case .primary: return .primary
        case .provider: return field.map { Theme.providerAccent(for: $0.tool) } ?? .secondary
        case .quota:
            return percent.map { Theme.barColor(percent: $0, mode: settingsStore.settings.displayMode) } ?? .secondary
        case .custom:
            guard let rgb = MenuBarHexColor.components(element.hexColour) else { return .primary }
            return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: rgb.a)
        }
    }
}

private struct MiniCanvasSector: Shape {
    var fraction: Double
    func path(in rect: CGRect) -> Path {
        Path { path in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: center)
            path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
            path.closeSubpath()
        }
    }
}
