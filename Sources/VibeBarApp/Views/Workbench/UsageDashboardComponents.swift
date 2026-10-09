import SwiftUI
import VibeBarCore

// MARK: - Formatting

/// Display helpers shared by the Usage page's cards. Everything a person
/// reads goes through `AppLocale` or the catalog; nothing here is stored.
enum UsageDashboardFormat {
    static func tokens(_ value: Int64) -> String { UsageFormatting.compactTokens(value) }

    static func cost(_ micros: Int64?) -> String {
        micros.map(UsageFormatting.compactUSD) ?? "—"
    }

    static func percent(_ fraction: Double?, digits: Int = 0) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return AppLocale.percent(fraction, fractionDigits: digits)
    }

    static func count(_ value: Int) -> String { AppLocale.number(value) }

    /// "<1m", "45m", "2h 5m", "3d 4h".
    static func duration(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 1 { return L10n.Common.Duration.lessThanMinute }
        if minutes < 60 { return L10n.Common.Duration.minutes(minutes: minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0
                ? L10n.Common.Duration.hours(hours: hours)
                : L10n.Common.Duration.hoursMinutes(hours: hours, minutes: rest)
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0
            ? L10n.Common.Duration.days(days: days)
            : L10n.Common.Duration.daysHours(days: days, hours: restHours)
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        // A log written a moment ahead of this clock is "now", not "in 3 min".
        return AppLocale.relativeDateTimeFormatter().localizedString(for: min(date, now), relativeTo: now)
    }

    static func day(_ date: Date) -> String { AppLocale.string(date, template: "MMMd") }

    /// Weekday names Monday first, the heatmap's row order.
    static var mondayFirstWeekdays: [String] {
        let symbols = AppLocale.shortWeekdaySymbols
        guard symbols.count == 7 else { return Array(repeating: "", count: 7) }
        return Array(symbols[1...]) + [symbols[0]]
    }

    /// "Mon 14:00" / "周一 14:00", for a Monday-first weekday and an hour.
    static func slot(weekday: Int, hour: Int) -> String {
        var components = DateComponents()
        // 2024-01-01 was a Monday in the Gregorian calendar — the page's
        // (`UsageDashboardCalendar`), not the Mac's, which may read the same
        // components as another day. Only the weekday and the hour are shown,
        // and an instant's weekday is the same in every calendar.
        components.year = 2024
        components.month = 1
        components.day = 1 + max(0, min(6, weekday))
        components.hour = max(0, min(23, hour))
        guard let date = UsageDashboardCalendar.local.date(from: components) else { return "" }
        return AppLocale.string(date, template: "EEEHHmm")
    }

    static func hour(_ hour: Int) -> String {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 1
        components.hour = max(0, min(23, hour))
        guard let date = UsageDashboardCalendar.local.date(from: components) else { return "" }
        return AppLocale.string(date, template: "HH")
    }

    static func modelName(_ raw: String) -> String { UsageModelNaming.canonicalDisplayName(raw) }
}

extension Harness {
    /// The harness's company colour: one table, `Theme.providerAccent`.
    var usageTint: Color { Theme.providerAccent(for: company) }
}

extension UsageToolCategory {
    var title: String {
        switch self {
        case .shell: L10n.Workbench.Usage.Tools.Category.shell
        case .read: L10n.Workbench.Usage.Tools.Category.read
        case .edit: L10n.Workbench.Usage.Tools.Category.edit
        case .web: L10n.Workbench.Usage.Tools.Category.web
        case .agent: L10n.Workbench.Usage.Tools.Category.agent
        case .mcp: "MCP"
        case .other: L10n.Usage.Mix.other
        }
    }

    var tint: Color {
        switch self {
        case .shell: Color(red: 78 / 255, green: 95 / 255, blue: 224 / 255)
        case .read: .teal
        case .edit: .orange
        case .web: .purple
        case .agent: .pink
        case .mcp: .green
        case .other: .gray
        }
    }
}

extension UsageDashboardSnapshot.HealthRating {
    var title: String {
        switch self {
        case .excellent: L10n.Workbench.Usage.Health.Rating.excellent
        case .good: L10n.Workbench.Usage.Health.Rating.good
        case .fair: L10n.Workbench.Usage.Health.Rating.fair
        case .poor: L10n.Workbench.Usage.Health.Rating.poor
        case .unknown: L10n.Workbench.Usage.Health.Rating.unknown
        }
    }

    var tint: Color {
        switch self {
        case .excellent: .green
        case .good: .teal
        case .fair: .orange
        case .poor: .red
        case .unknown: .secondary
        }
    }
}

// MARK: - Card chrome

/// Title row shared by every Usage card: title, optional subtitle, and a
/// trailing control (a picker, a count).
struct UsageCardHeader<Trailing: View>: View {
    let density: Theme.Density
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: max(10, density.subtitleFontSize - 1)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension UsageCardHeader where Trailing == EmptyView {
    init(density: Theme.Density, title: String, subtitle: String? = nil) {
        self.init(density: density, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small segmented control in the Workbench pill vocabulary: a fill
/// change marks the selection, never elevation.
struct UsagePillPicker<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    var accessibilityLabel: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? WorkbenchPorcelain.selectedNavigationFill(for: colorScheme) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.vibeBar(cornerRadius: 7))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(WorkbenchPorcelain.toolbarFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(WorkbenchPorcelain.hairline(for: colorScheme), lineWidth: Theme.Card.hairlineWidth)
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

/// A horizontal share bar on a track. Drawn as shapes sized by their own
/// rect — no `GeometryReader`, so a list of them adds no layout pass.
struct UsageShareBar: View, Equatable {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        ZStack {
            Capsule().fill(Theme.barTrack)
            UsageFractionShape(fraction: fraction).fill(tint)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The leading `fraction` of the rect as a capsule (or, vertical, the
/// bottom `fraction` as a rounded column).
struct UsageFractionShape: Shape {
    var fraction: Double
    var vertical = false
    var cornerRadius: CGFloat?

    func path(in rect: CGRect) -> Path {
        let share = max(0, min(1, fraction))
        guard share > 0 else { return Path() }
        if vertical {
            let height = max(2, rect.height * share)
            let bar = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
            return Path(roundedRect: bar, cornerRadius: min(cornerRadius ?? 4, bar.width / 2, bar.height / 2))
        }
        let width = max(2, rect.width * share)
        let bar = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        return Path(roundedRect: bar, cornerRadius: min(cornerRadius ?? rect.height / 2, bar.height / 2, bar.width / 2))
    }
}

/// Consecutive coloured parts in one capsule, drawn in a single `Canvas`.
struct UsageSegmentedBar: View, Equatable {
    struct Part: Equatable {
        let value: Double
        let tint: Color
    }

    let parts: [Part]
    /// The length the whole bar stands for; parts fill `total / scale`.
    var scale: Double?
    var height: CGFloat = 6

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(Theme.barTrack))
            let total = parts.reduce(0) { $0 + $1.value }
            let full = max(scale ?? total, 1)
            context.clip(to: track)
            var x: CGFloat = 0
            for part in parts where part.value > 0 {
                let width = size.width * CGFloat(part.value / full)
                context.fill(Path(CGRect(x: x, y: 0, width: max(1, width), height: size.height)), with: .color(part.tint))
                x += width + 1
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A quiet centred message inside a card.
struct UsageEmptyMessage: View {
    let density: Theme.Density
    let text: String
    var systemImage = "tray"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

/// The opaque tooltip every Usage chart overlay draws.
struct UsageTooltip<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
        }
        .font(.system(size: 10.5).monospacedDigit())
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .workbenchOverlaySurface(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }
}
