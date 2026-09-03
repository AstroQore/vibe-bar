import SwiftUI
import VibeBarCore

enum WorkbenchPage: String, CaseIterable, Identifiable {
    case usageStats
    case sessionManager
    case resets
    case skillsManager
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usageStats: L10n.Workbench.pageUsageStatsTitle
        case .sessionManager: L10n.Workbench.pageSessionsTitle
        case .resets: L10n.Workbench.pageResetsTitle
        case .skillsManager: L10n.Workbench.pageSkillsTitle
        case .settings: L10n.Workbench.pageSettingsTitle
        }
    }

    var systemImage: String {
        switch self {
        case .usageStats: "chart.xyaxis.line"
        case .sessionManager: "bubble.left.and.text.bubble.right"
        case .resets: "clock.arrow.circlepath"
        case .skillsManager: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }

    var isPrimary: Bool { self != .settings }

    var subtitle: String {
        switch self {
        case .usageStats: L10n.Workbench.pageUsageStatsSubtitle
        case .sessionManager: L10n.Workbench.pageSessionsSubtitle
        case .resets: L10n.Workbench.pageResetsSubtitle
        case .skillsManager: L10n.Workbench.pageSkillsSubtitle
        case .settings: L10n.Workbench.pageSettingsSubtitle
        }
    }
}

/// A window-owned navigation source. `showWorkbench(page:)` can update it
/// after SwiftUI has created the Workbench, which keeps all entry points in
/// the one window instead of relying on an initial-view-only selection.
@MainActor
final class WorkbenchNavigation: ObservableObject {
    @Published private(set) var selectedPage: WorkbenchPage?
    /// A Settings section requested from outside the window (demo mode's
    /// `settings:<section>` surface). Consumed once by the root view, which
    /// owns the live selection.
    @Published private(set) var requestedSettingsDestination: SettingsDestination?

    func select(_ page: WorkbenchPage?) {
        selectedPage = page
    }

    func selectSettings(_ destination: SettingsDestination) {
        requestedSettingsDestination = destination
        selectedPage = .settings
    }

    func consumeRequestedSettingsDestination() -> SettingsDestination? {
        defer { requestedSettingsDestination = nil }
        return requestedSettingsDestination
    }
}

/// Top-level content for the standalone Workbench window.
///
/// The selected page lives in `UserDefaults` rather than `AppSettings`: it is
/// window state, not a preference, and writing it through the settings store
/// would fan a page switch out to the menu bar renderer and every popover
/// subscriber.
struct WorkbenchRootView: View {
    let initialPage: WorkbenchPage?

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var workbench: WorkbenchServices
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("workbench.selectedPage") private var storedPage: String = WorkbenchPage.usageStats.rawValue
    @ObservedObject private var navigation: WorkbenchNavigation
    @State private var appearanceOverride: ColorScheme?
    /// Which Settings section is open. Window state, and owned here rather
    /// than inside `SettingsView` so the page header can name it and so
    /// leaving Settings and coming back does not silently reset it.
    @State private var settingsDestination: SettingsDestination = .page(.system)

    init(initialPage: WorkbenchPage?, navigation: WorkbenchNavigation) {
        self.initialPage = initialPage
        _navigation = ObservedObject(wrappedValue: navigation)
    }

    private var page: WorkbenchPage {
        if let selected = navigation.selectedPage { return selected }
        if let initialPage { return initialPage }
        let stored = WorkbenchPage(rawValue: storedPage)
        return stored?.isPrimary == true ? stored! : .usageStats
    }

    var body: some View {
        // One density for the whole window, resolved once: pages share the
        // popover's card metrics so a card looks the same in both surfaces.
        let density = Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
        HStack(spacing: 0) {
            WorkbenchSidebar(selection: selectionBinding)
                .frame(width: 206)
            Rectangle()
                .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                .frame(width: 1)
            VStack(spacing: 0) {
                WorkbenchPageHeader(
                    page: page,
                    status: pageStatus,
                    appearanceIsDark: (appearanceOverride ?? colorScheme) == .dark,
                    onToggleAppearance: toggleAppearance,
                    onRefresh: page == .settings ? nil : refreshCurrentPage
                )
                detail(for: page, density: density)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkbenchPorcelain.windowFill(for: colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkbenchPorcelain.windowFill(for: colorScheme))
        .workbenchPorcelain()
        // The whole window is hand-drawn controls; the system focus ring is
        // switched off here, once, and every custom button style draws its
        // own accent hairline instead. Regions made of native controls —
        // Settings' toggles and fields, the form sheets and popovers — put
        // the system effect back locally with `vibeBarSystemControlFocus()`.
        .vibeBarControlFocus()
        .preferredColorScheme(appearanceOverride)
        .onAppear {
            if navigation.selectedPage == nil {
                let stored = WorkbenchPage(rawValue: storedPage)
                navigation.select(initialPage ?? (stored?.isPrimary == true ? stored : nil) ?? .usageStats)
            }
            if let requested = navigation.consumeRequestedSettingsDestination() {
                settingsDestination = requested
            }
        }
        .onChange(of: navigation.requestedSettingsDestination) { _, requested in
            guard requested != nil, let requested = navigation.consumeRequestedSettingsDestination() else { return }
            settingsDestination = requested
        }
        .onChange(of: navigation.selectedPage) { _, newValue in
            guard let newValue, newValue.isPrimary else { return }
            storedPage = newValue.rawValue
        }
    }

    private var pageStatus: String? {
        switch page {
        case .usageStats:
            guard let updated = workbench.usageStats.lastUpdatedAt else {
                return L10n.Workbench.statusLocalLedger
            }
            return L10n.Workbench.statusUpdated(
                time: AppLocale.string(updated, dateStyle: .none, timeStyle: .medium)
            )
        case .sessionManager:
            let count = workbench.sessions.totalSessionCount
            return count == 0
                ? L10n.Workbench.statusLocalIndex
                : L10n.Workbench.statusIndexed(count: count)
        case .resets:
            let next = UpcomingResets.events(environment: environment, now: Date(), horizonDays: 7).first
            guard let next,
                  let countdown = ResetCountdownFormatter.string(from: next.resetAt, now: Date())
            else { return L10n.Workbench.statusCachedQuotas }
            return L10n.Workbench.statusNextRefill(countdown: countdown)
        case .skillsManager:
            let count = workbench.skills.skills.count
            return count == 0
                ? L10n.Workbench.statusSharedLibrary
                : L10n.Workbench.statusInstalled(count: count)
        case .settings:
            return settingsDestination.title(settings: settingsStore.settings)
        }
    }

    private func toggleAppearance() {
        appearanceOverride = (appearanceOverride ?? colorScheme) == .dark ? .light : .dark
    }

    private func refreshCurrentPage() {
        switch page {
        case .usageStats: workbench.usageStats.refresh()
        case .sessionManager: workbench.sessions.refreshIndex()
        case .resets: environment.refreshAll()
        case .skillsManager: workbench.skills.refresh()
        case .settings: break
        }
    }

    private var selectionBinding: Binding<WorkbenchPage?> {
        Binding(
            get: { navigation.selectedPage },
            set: { navigation.select($0) }
        )
    }

    @ViewBuilder
    private func detail(for page: WorkbenchPage, density: Theme.Density) -> some View {
        switch page {
        case .usageStats:
            UsageStatsPage(density: density, model: workbench.usageStats)
        case .sessionManager:
            SessionManagerPage(density: density, model: workbench.sessions)
        case .resets:
            ResetsPage(density: density)
        case .skillsManager:
            SkillsManagerPage(density: density, model: workbench.skills)
        case .settings:
            SettingsView(density: density, selection: $settingsDestination)
        }
    }
}

private struct WorkbenchSidebar: View {
    @Binding var selection: WorkbenchPage?
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredPage: WorkbenchPage?
    private let primaryPages: [WorkbenchPage] = [.usageStats, .sessionManager, .resets, .skillsManager]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(primaryPages) { page in
                    row(for: page)
                }
            }

            Spacer(minLength: 12)

            Divider()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            row(for: .settings, secondary: true)
            Text(versionLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
    }

    @ViewBuilder
    private func row(for page: WorkbenchPage, secondary: Bool = false) -> some View {
        Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pageTint(page).opacity(selection == page ? 0.16 : 0.11))
                    Image(systemName: page.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pageTint(page))
                }
                .frame(width: 20, height: 20)
                Text(page.title)
                    .font(.system(size: 13, weight: secondary ? .medium : .semibold))
                Spacer(minLength: 0)
            }
                .foregroundStyle(selection == page ? WorkbenchPorcelain.accent : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 8)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(WorkbenchSidebarRowStyle(
            isSelected: selection == page,
            isHovered: hoveredPage == page
        ))
        .onHover { hovering in
            hoveredPage = hovering ? page : (hoveredPage == page ? nil : hoveredPage)
        }
        .accessibilityAddTraits(selection == page ? [.isSelected] : [])
    }

    private func pageTint(_ page: WorkbenchPage) -> Color {
        switch page {
        case .usageStats: WorkbenchPorcelain.accent
        case .sessionManager: Color(red: 20 / 255, green: 169 / 255, blue: 124 / 255)
        case .resets: Color(red: 88 / 255, green: 134 / 255, blue: 220 / 255)
        case .skillsManager: Color(red: 217 / 255, green: 137 / 255, blue: 11 / 255)
        case .settings: .secondary
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Vibe Bar · " + (version ?? "Workbench")
    }
}

private struct WorkbenchSidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(isSelected: isSelected, isHovered: isHovered) { configuration.label }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    /// A nested view rather than the style itself, because `isFocused` is an
    /// environment value and a `ButtonStyle` has no body to read it from.
    /// The focused hairline replaces the system focus ring the window
    /// switches off; it sits over the row's selected/hovered fill, and being
    /// the app accent rather than the porcelain hairline it stays legible on
    /// a selected row.
    private struct Row<Label: View>: View {
        let isSelected: Bool
        let isHovered: Bool
        @ViewBuilder let label: Label

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(backgroundFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? Color.accentColor
                                : (isSelected ? WorkbenchPorcelain.hairline(for: colorScheme) : Color.clear),
                            lineWidth: isFocused ? 1 : Theme.Card.hairlineWidth
                        )
                )
        }

        private var backgroundFill: Color {
            if isSelected { return WorkbenchPorcelain.selectedNavigationFill(for: colorScheme) }
            if isHovered { return WorkbenchPorcelain.hoverFill(for: colorScheme) }
            return .clear
        }
    }
}

private struct WorkbenchPageHeader: View {
    let page: WorkbenchPage
    let status: String?
    let appearanceIsDark: Bool
    let onToggleAppearance: () -> Void
    let onRefresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.35)
                Text(page.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let status {
                Text(status)
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            WorkbenchHeaderIconButton(
                systemImage: appearanceIsDark ? "sun.max" : "moon",
                help: appearanceIsDark
                    ? L10n.Workbench.appearanceUseLight
                    : L10n.Workbench.appearanceUseDark,
                action: onToggleAppearance
            )
            if let onRefresh {
                WorkbenchHeaderIconButton(
                    systemImage: "arrow.clockwise",
                    help: L10n.Workbench.headerRefreshPage(page: page.title),
                    action: onRefresh
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkbenchHeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        isHovering
                            ? WorkbenchPorcelain.selectedNavigationFill(for: colorScheme)
                            : WorkbenchPorcelain.toolbarFill(for: colorScheme)
                    )
                )
                .overlay(
                    Circle().stroke(
                        WorkbenchPorcelain.hairline(for: colorScheme),
                        lineWidth: Theme.Card.hairlineWidth
                    )
                )
        }
        // 14 pt on the 28 pt circle keeps the focus hairline circular.
        .buttonStyle(.vibeBar(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
