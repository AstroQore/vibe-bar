import SwiftUI
import VibeBarCore

enum WorkbenchPage: String, CaseIterable, Identifiable {
    case usageStats
    case sessionManager
    case skillsManager

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usageStats: "Usage Stats"
        case .sessionManager: "Sessions"
        case .skillsManager: "Skills"
        }
    }

    var systemImage: String {
        switch self {
        case .usageStats: "chart.xyaxis.line"
        case .sessionManager: "bubble.left.and.text.bubble.right"
        case .skillsManager: "puzzlepiece.extension"
        }
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
    @AppStorage("workbench.selectedPage") private var storedPage: String = WorkbenchPage.usageStats.rawValue
    @State private var selection: WorkbenchPage?

    private var page: WorkbenchPage {
        selection ?? .usageStats
    }

    var body: some View {
        // One density for the whole window, resolved once: pages share the
        // popover's card metrics so a card looks the same in both surfaces.
        let density = Theme.overviewDensity(for: settingsStore.settings.popoverDensity)
        NavigationSplitView {
            List(selection: $selection) {
                Section("WORKBENCH") {
                    ForEach(WorkbenchPage.allCases) { page in
                        Label(page.title, systemImage: page.systemImage)
                            .tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Workbench")
            .navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 268)
        } detail: {
            detail(for: page, density: density)
                .navigationTitle(page.title)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            guard selection == nil else { return }
            selection = initialPage ?? WorkbenchPage(rawValue: storedPage) ?? .usageStats
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            storedPage = newValue.rawValue
        }
    }

    @ViewBuilder
    private func detail(for page: WorkbenchPage, density: Theme.Density) -> some View {
        switch page {
        case .usageStats:
            UsageStatsPage(density: density, model: workbench.usageStats)
        case .sessionManager:
            SessionManagerPage(density: density, model: workbench.sessions)
        case .skillsManager:
            SkillsManagerPage(density: density, model: workbench.skills)
        }
    }
}
