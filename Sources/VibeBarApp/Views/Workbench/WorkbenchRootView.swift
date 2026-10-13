import SwiftUI
import VibeBarCore

enum WorkbenchPage: String, CaseIterable, Identifiable {
    case usageStats
    case sessionManager
    case resets
    /// Skills keeps its original raw value, so a stored or requested
    /// `skillsManager` page — from before the Library was split into three
    /// sidebar rows — still opens Skills.
    case skillsManager
    case libraryMCP
    case libraryInstructions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usageStats: L10n.Workbench.Page.UsageStats.title
        case .sessionManager: L10n.Workbench.Page.Sessions.title
        case .resets: L10n.Workbench.Page.Resets.title
        case .skillsManager: L10n.Workbench.Page.Skills.title
        case .libraryMCP: L10n.Workbench.Library.mcp
        case .libraryInstructions: L10n.Workbench.Library.instructions
        case .settings: L10n.Popover.Header.settings
        }
    }

    var systemImage: String {
        switch self {
        case .usageStats: "chart.xyaxis.line"
        case .sessionManager: "bubble.left.and.text.bubble.right"
        case .resets: "clock.arrow.circlepath"
        case .skillsManager: "puzzlepiece.extension"
        case .libraryMCP: "server.rack"
        case .libraryInstructions: "doc.text"
        case .settings: "gearshape"
        }
    }

    var isPrimary: Bool { self != .settings }

    var subtitle: String {
        switch self {
        case .usageStats: L10n.Workbench.Page.UsageStats.subtitle
        case .sessionManager: L10n.Workbench.Page.Sessions.subtitle
        case .resets: L10n.Workbench.Page.Resets.subtitle
        case .skillsManager: L10n.Workbench.Page.Skills.subtitle
        case .libraryMCP, .libraryInstructions: L10n.Workbench.Library.subtitle
        case .settings: L10n.Workbench.Page.Settings.subtitle
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
        // Three levels, left to right: the window's navigation, the page's
        // own navigation where it has one (full height, beside the header
        // rather than under it), then the header over the content.
        let header = WorkbenchPageHeader(
            page: page,
            status: pageStatus,
            appearanceIsDark: (appearanceOverride ?? colorScheme) == .dark,
            onToggleAppearance: toggleAppearance,
            onRefresh: page == .settings ? nil : refreshCurrentPage
        )
        HStack(spacing: 0) {
            WorkbenchSidebar(selection: selectionBinding)
                .frame(width: WorkbenchPorcelain.Navigation.sidebarWidth)
            WorkbenchColumnDivider()
            pageColumns(for: page, header: header, density: density)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                return L10n.Workbench.Status.localLedger
            }
            return L10n.Workbench.Status.updated(
                time: AppLocale.string(updated, dateStyle: .none, timeStyle: .medium)
            )
        case .sessionManager:
            let count = workbench.sessions.totalSessionCount
            return count == 0
                ? L10n.Workbench.Status.localIndex
                : L10n.Workbench.Status.indexed(count: count)
        case .resets:
            let next = UpcomingResets.events(environment: environment, now: Date(), horizonDays: 7).first
            guard let next,
                  let countdown = ResetCountdownFormatter.string(from: next.resetAt, now: Date())
            else { return L10n.Workbench.Status.cachedQuotas }
            return L10n.Workbench.Status.nextRefill(countdown: countdown)
        case .skillsManager, .libraryMCP, .libraryInstructions:
            return L10n.Workbench.Status.sharedLibrary
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
        case .libraryMCP: Task { await workbench.library.refresh(.mcp) }
        case .libraryInstructions: Task { await workbench.library.refresh(.instructions) }
        case .settings: break
        }
    }

    /// Show one session on the Sessions page — the Usage page's rows link
    /// here. The Sessions page reloads its list when it appears and keeps a
    /// selection only if the list holds it, so the session is selected again
    /// once that first reload has landed.
    private func openSession(_ summary: SessionSummary) {
        let sessions = workbench.sessions
        navigation.select(.sessionManager)
        sessions.select(summary)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            for _ in 0..<60 where sessions.isLoadingSummaries {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if sessions.selection?.id != summary.id {
                sessions.select(summary)
            }
        }
    }

    private var selectionBinding: Binding<WorkbenchPage?> {
        Binding(
            get: { navigation.selectedPage },
            set: { navigation.select($0) }
        )
    }

    /// Everything right of the window's sidebar. Sessions and Settings put
    /// their own navigation column first; Sessions sizes its columns from
    /// the width it is given, so it lays out the header itself.
    @ViewBuilder
    private func pageColumns(
        for page: WorkbenchPage,
        header: WorkbenchPageHeader,
        density: Theme.Density
    ) -> some View {
        switch page {
        case .sessionManager:
            SessionPageColumns(density: density, controller: workbench.sessionsPage, header: header)
        case .settings:
            HStack(spacing: 0) {
                SettingsSidebarView(selection: $settingsDestination)
                headed(header) {
                    SettingsView(density: density, selection: $settingsDestination)
                }
            }
        default:
            headed(header) { detail(for: page, density: density) }
        }
    }

    private func headed<Content: View>(
        _ header: WorkbenchPageHeader,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pages without a navigation column of their own.
    @ViewBuilder
    private func detail(for page: WorkbenchPage, density: Theme.Density) -> some View {
        switch page {
        case .usageStats:
            UsageStatsPage(density: density, model: workbench.usageStats, onOpenSession: openSession)
        case .resets:
            ResetsPage(density: density)
        case .skillsManager:
            SkillsManagerPage(density: density, model: workbench.skills)
        case .libraryMCP:
            LibraryMCPPage(density: density, model: workbench.library)
        case .libraryInstructions:
            LibraryInstructionsPage(density: density, model: workbench.library)
        case .sessionManager, .settings:
            EmptyView()
        }
    }
}

/// The window's own navigation. Its rows are the same `WorkbenchNavigationRow`
/// a page's column uses, at the `.window` level: semibold titles and a tinted
/// icon block per page, which is what marks this column as the top level.
private struct WorkbenchSidebar: View {
    @Binding var selection: WorkbenchPage?
    @Environment(\.colorScheme) private var colorScheme
    private let primaryPages: [WorkbenchPage] = [.usageStats, .sessionManager, .resets]
    private let libraryPages: [WorkbenchPage] = [.skillsManager, .libraryMCP, .libraryInstructions]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: WorkbenchPorcelain.Navigation.rowSpacing) {
                ForEach(primaryPages) { page in
                    row(for: page)
                }
                WorkbenchNavigationSectionHeader(title: L10n.Workbench.Library.title)
                ForEach(libraryPages) { page in
                    row(for: page)
                }
            }

            Spacer(minLength: 12)

            WorkbenchColumnDivider(axis: .horizontal)
                .padding(.horizontal, WorkbenchPorcelain.Navigation.rowPadding)
                .padding(.bottom, 8)

            row(for: .settings)
            Text(versionLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, WorkbenchPorcelain.Navigation.rowPadding)
                .padding(.top, 12)
        }
        .padding(.horizontal, WorkbenchPorcelain.Navigation.columnInset)
        .padding(.vertical, WorkbenchPorcelain.Navigation.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkbenchPorcelain.sidebarFill(for: colorScheme))
    }

    private func row(for page: WorkbenchPage) -> some View {
        let isSelected = selection == page
        return WorkbenchNavigationRow(
            title: page.title,
            // Settings sits apart at the bottom and reads one step quieter.
            level: page.isPrimary ? .window : .page,
            isSelected: isSelected,
            action: { selection = page }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pageTint(page).opacity(isSelected ? 0.16 : 0.11))
                Image(systemName: page.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pageTint(page))
            }
        }
    }

    private func pageTint(_ page: WorkbenchPage) -> Color {
        switch page {
        case .usageStats: WorkbenchPorcelain.accent
        case .sessionManager: Color(red: 20 / 255, green: 169 / 255, blue: 124 / 255)
        case .resets: Color(red: 88 / 255, green: 134 / 255, blue: 220 / 255)
        case .skillsManager, .libraryMCP, .libraryInstructions: Color(red: 217 / 255, green: 137 / 255, blue: 11 / 255)
        case .settings: .secondary
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Vibe Bar · " + (version ?? "Workbench")
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
                    ? L10n.Workbench.Appearance.useLight
                    : L10n.Workbench.Appearance.useDark,
                action: onToggleAppearance
            )
            if let onRefresh {
                WorkbenchHeaderIconButton(
                    systemImage: "arrow.clockwise",
                    help: L10n.Workbench.Header.refreshPage(page: page.title),
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
