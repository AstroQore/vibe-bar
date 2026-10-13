import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// One settings navigator for both static preferences and provider-specific
/// configuration. Provider ordering is edited directly where it is consumed,
/// rather than in a second, disconnected ordering screen.
///
/// The Settings page's own navigation column: a `WorkbenchSecondaryColumn`,
/// the same column the Sessions page's harnesses use, with the search field
/// in its header slot. It runs the full height of the window beside the
/// page header, so the window reads as its sidebar, then this column, then
/// the section it opens.
struct SettingsSidebarView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @Binding var selection: SettingsDestination

    @State private var searchText = ""
    @State private var draggedCoreProvider: ToolType?
    @State private var draggedMiscProviderID: String?

    private let basicPages: [SettingsSectionID] = [
        .system,
        .permissions,
        .costData,
        .pricing,
        .mcp,
        .remote,
        .privacy,
        .menuBar,
        .menuBarHealth,
        .miniWindow,
        .layout,
        .einkDisplays,
    ]

    var body: some View {
        WorkbenchSecondaryColumn {
            searchField
        } content: {
            // Each filter runs once per render, not once per use.
            let basicPages = filteredBasicPages
            let coreProviders = filteredCoreProviders
            let miscProviders = filteredMiscProviders
            let showsMiscLanding = miscLandingMatchesSearch

            if searchText.isEmpty || !basicPages.isEmpty {
                WorkbenchNavigationSectionHeader(title: L10n.Popover.Header.settings)
                ForEach(basicPages, id: \.rawValue) { page in
                    staticRow(page)
                }
            }

            if searchText.isEmpty || !coreProviders.isEmpty {
                WorkbenchNavigationSectionHeader(title: L10n.Settings.Sidebar.coreProviders)
                ForEach(coreProviders, id: \.self) { tool in
                    coreProviderRow(tool)
                        .onDrag {
                            draggedCoreProvider = tool
                            return NSItemProvider(object: tool.rawValue as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: SettingsCoreProviderDropDelegate(
                                target: tool,
                                dragged: $draggedCoreProvider,
                                settingsStore: settingsStore
                            )
                        )
                }
                if searchText.isEmpty {
                    Color.clear
                        .frame(height: 6)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.text],
                            delegate: SettingsCoreProviderDropDelegate(
                                target: nil,
                                dragged: $draggedCoreProvider,
                                settingsStore: settingsStore
                            )
                        )
                }
            }

            if showsMiscLanding || !miscProviders.isEmpty {
                WorkbenchNavigationSectionHeader(title: L10n.Popover.Tab.misc)
                if showsMiscLanding {
                    miscLandingRow
                }
                ForEach(miscProviders) { instance in
                    miscProviderRow(instance)
                        .onDrag {
                            draggedMiscProviderID = instance.id
                            return NSItemProvider(object: instance.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: SettingsMiscProviderDropDelegate(
                                targetID: instance.id,
                                draggedID: $draggedMiscProviderID,
                                settingsStore: settingsStore
                            )
                        )
                }
                if searchText.isEmpty {
                    Color.clear
                        .frame(height: 8)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.text],
                            delegate: SettingsMiscProviderDropDelegate(
                                targetID: nil,
                                draggedID: $draggedMiscProviderID,
                                settingsStore: settingsStore
                            )
                        )
                }
            }
        }
    }

    /// The column's header slot. The glyph sits in a mark-sized frame and the
    /// text starts where the rows' titles start, so the field lines up with
    /// the column under it.
    private var searchField: some View {
        HStack(spacing: WorkbenchPorcelain.Navigation.markSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: WorkbenchPorcelain.Navigation.markSize)
            TextField(L10n.Settings.search, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, WorkbenchPorcelain.Navigation.rowPadding)
        .frame(height: 30)
        .workbenchFieldSurface(cornerRadius: WorkbenchPorcelain.Navigation.rowCornerRadius)
        // The search field is the column's one native control; give it
        // back the system focus ring the column switches off.
        .vibeBarSystemControlFocus()
    }

    private var filteredBasicPages: [SettingsSectionID] {
        guard !searchText.isEmpty else { return basicPages }
        return basicPages.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredCoreProviders: [ToolType] {
        settingsStore.settings.orderedCoreProviders.filter { tool in
            searchText.isEmpty
                || coreProviderTitle(tool).localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredMiscProviders: [MiscProviderInstance] {
        guard !searchText.isEmpty else { return settingsStore.settings.miscProviderInstances }
        return settingsStore.settings.miscProviderInstances.filter { instance in
            Self.searchTerms(for: instance).contains {
                $0.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    /// Everything a user might type to find one misc row.
    ///
    /// `menuTitle` collapses the plan pairs — both Volcengine rows are
    /// "Volcengine", both Bailian rows "Bailian" — so searching for the
    /// thing that actually distinguishes them ("Agent Plan", "Token Plan")
    /// used to match nothing. `displayName` and `subtitle` carry the plan;
    /// the vendor aliases cover the brands whose console name differs from
    /// the one Vibe Bar shows.
    private static func searchTerms(for instance: MiscProviderInstance) -> [String] {
        let tool = instance.tool
        var terms = [
            instance.displayTitle(fallback: tool.displayName),
            tool.displayName,
            tool.menuTitle,
            tool.subtitle,
            tool.productName,
            tool.vendorName,
            tool.statusProviderName
        ]
        terms.append(contentsOf: vendorAliases(for: tool))
        return terms
    }

    /// Names users know a provider by that no `ToolType` field carries.
    private static func vendorAliases(for tool: ToolType) -> [String] {
        switch tool {
        case .alibaba, .alibabaTokenPlan:
            return ["DashScope", "Aliyun", "Model Studio", "阿里云", "百炼"]
        case .volcengine, .volcengineAgentPlan:
            return ["Doubao", "Ark", "ByteDance", "火山引擎", "豆包"]
        case .tencentHunyuan, .tencentTokenPlan:
            return ["TokenHub", "腾讯云", "混元"]
        case .zai:
            return ["Zhipu", "BigModel", "GLM", "智谱"]
        case .baiduQianfan:
            return ["Baidu", "BCE", "百度", "千帆"]
        case .iflytek:
            return ["Spark", "MaaS", "讯飞", "星火"]
        case .mimo:
            return ["Xiaomi", "小米"]
        case .kimi:
            return ["Moonshot", "月之暗面"]
        case .copilot:
            return ["GitHub"]
        case .openCodeGo:
            return ["OpenCode"]
        default:
            return []
        }
    }

    private var miscLandingMatchesSearch: Bool {
        searchText.isEmpty
            || L10n.Onboarding.Step.BrowserCookies.title.localizedCaseInsensitiveContains(searchText)
            || L10n.Popover.Tab.misc.localizedCaseInsensitiveContains(searchText)
    }

    private func staticRow(_ page: SettingsSectionID) -> some View {
        let isSelected = selection == .page(page)
        return WorkbenchNavigationRow(
            title: page.title,
            isSelected: isSelected,
            action: { selection = .page(page) }
        ) {
            WorkbenchNavigationSymbol(systemImage: page.systemImage, isSelected: isSelected)
        }
    }

    private func coreProviderRow(_ tool: ToolType) -> some View {
        let enabled = settingsStore.settings.isCoreProviderVisible(tool)
        let destination = SettingsDestination.coreProvider(tool)
        return WorkbenchNavigationRow(
            title: coreProviderTitle(tool),
            isSelected: selection == destination,
            isDimmed: !enabled,
            action: { selection = destination }
        ) {
            // The row is titled with the company (`coreProviderTitle`),
            // so it is marked with the company too.
            CompanyBrandIconView(tool: tool, size: 16)
        } accessory: {
            providerAccessory(enabled: enabled)
        }
        .contextMenu {
            Button(enabled ? L10n.Settings.Sidebar.hideFromOverview : L10n.Onboarding.Subscriptions.showInOverview) {
                settingsStore.settings.setCoreProviderVisible(!enabled, for: tool)
            }
        }
    }

    private func miscProviderRow(_ instance: MiscProviderInstance) -> some View {
        let enabled = instance.isVisible
        let destination = SettingsDestination.miscProvider(instance.id)
        return WorkbenchNavigationRow(
            // `menuTitle` is the L2 SubProvider, which is identical for the
            // Coding Plan / Token Plan / Agent Plan pairs — two sidebar rows
            // reading "Volcengine" with no way to tell which is which.
            // `displayName` keeps the plan.
            title: instance.displayTitle(fallback: instance.tool.displayName),
            isSelected: selection == destination,
            isDimmed: !enabled,
            action: { selection = destination }
        ) {
            ToolBrandIconView(tool: instance.tool, size: 16)
        } accessory: {
            providerAccessory(enabled: enabled)
        }
        .contextMenu {
            Button(enabled ? L10n.Settings.Sidebar.disableProvider : L10n.Settings.Sidebar.enableProvider) {
                settingsStore.settings.setMiscProviderInstanceVisible(!enabled, forID: instance.id)
            }
        }
    }

    private var miscLandingRow: some View {
        let isSelected = selection == .page(.miscProviders)
        return WorkbenchNavigationRow(
            title: L10n.Onboarding.Step.BrowserCookies.title,
            isSelected: isSelected,
            action: { selection = .page(.miscProviders) }
        ) {
            WorkbenchNavigationSymbol(systemImage: "safari", isSelected: isSelected)
        }
    }

    /// A provider row's trailing slot: whether it is on, and the handle that
    /// says the rows can be dragged into a new order.
    private func providerAccessory(enabled: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(enabled ? Color.green : Color.secondary.opacity(0.42))
                .frame(width: 6, height: 6)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func coreProviderTitle(_ tool: ToolType) -> String {
        switch tool.coreProviderRepresentative {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .gemini: "Google AI"
        case .grok: "SpaceXAI"
        case .muse: "Meta AI"
        case .devin: "Cognition"
        case .mistralVibe: "Mistral AI"
        default: tool.vendorName
        }
    }
}

private struct SettingsCoreProviderDropDelegate: DropDelegate {
    let target: ToolType?
    @Binding var dragged: ToolType?
    let settingsStore: SettingsStore

    func dropEntered(info: DropInfo) {
        guard let dragged else { return }
        if let target {
            settingsStore.settings.moveCoreProvider(dragged, before: target)
        } else {
            settingsStore.settings.moveCoreProviderToEnd(dragged)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct SettingsMiscProviderDropDelegate: DropDelegate {
    let targetID: String?
    @Binding var draggedID: String?
    let settingsStore: SettingsStore

    func dropEntered(info: DropInfo) {
        guard let draggedID else { return }
        if let targetID {
            settingsStore.settings.moveMiscProviderInstance(id: draggedID, before: targetID)
        } else {
            settingsStore.settings.moveMiscProviderInstanceToEnd(id: draggedID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
