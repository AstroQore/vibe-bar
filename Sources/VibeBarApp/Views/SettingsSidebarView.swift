import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// One settings navigator for both static preferences and provider-specific
/// configuration. Provider ordering is edited directly where it is consumed,
/// rather than in a second, disconnected ordering screen.
///
/// This is a column *inside* the Settings page, not a second window sidebar:
/// no fill, no title of its own, no chrome the Workbench already provides.
/// It reads as a segmented list of sections, which is what it is — the
/// Workbench's own rail stays the only navigation surface in the window.
struct SettingsSidebarView: View {
    static let width: CGFloat = 236

    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: SettingsDestination

    @State private var searchText = ""
    @State private var draggedCoreProvider: ToolType?
    @State private var draggedMiscProviderID: String?

    private let basicPages: [SettingsSectionID] = [
        .system,
        .costData,
        .pricing,
        .mcp,
        .remote,
        .privacy,
        .menuBar,
        .menuBarHealth,
        .miniWindow,
        .layout,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.Settings.search, text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .workbenchFieldSurface(cornerRadius: 8)
            // The search field is the sidebar's one native control; give it
            // back the system focus ring the rail switches off.
            .vibeBarSystemControlFocus()
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if searchText.isEmpty || !filteredBasicPages.isEmpty {
                        sidebarGroup(L10n.Settings.sidebarSettings) {
                            ForEach(filteredBasicPages, id: \.rawValue) { page in
                                staticRow(page)
                            }
                        }
                    }

                    if searchText.isEmpty || !filteredCoreProviders.isEmpty {
                        sidebarGroup(L10n.Settings.sidebarCoreProviders) {
                            ForEach(filteredCoreProviders, id: \.self) { tool in
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
                    }

                    if miscLandingMatchesSearch || !filteredMiscProviders.isEmpty {
                        sidebarGroup(L10n.Popover.tabMisc) {
                            if miscLandingMatchesSearch {
                                miscLandingRow
                            }
                            ForEach(filteredMiscProviders) { instance in
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
                .padding(.horizontal, 10)
                .padding(.bottom, 18)
            }
        }
        .frame(width: Self.width)
        // A rail of hand-drawn rows: the system focus ring stays off and
        // each row's `VibeBarButtonStyle` hairline marks keyboard focus.
        .vibeBarControlFocus()
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
            || L10n.Onboarding.doneBrowserCookies.localizedCaseInsensitiveContains(searchText)
            || L10n.Popover.tabMisc.localizedCaseInsensitiveContains(searchText)
    }

    private func sidebarGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.55)
                .padding(.horizontal, 9)
                .padding(.bottom, 2)
            content()
        }
    }

    private func staticRow(_ page: SettingsSectionID) -> some View {
        sidebarRow(
            destination: .page(page),
            title: page.title,
            icon: AnyView(
                Image(systemName: page.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
            ),
            enabled: true,
            showsStatusDot: false,
            showsDragHandle: false
        )
    }

    private func coreProviderRow(_ tool: ToolType) -> some View {
        let enabled = settingsStore.settings.isCoreProviderVisible(tool)
        return sidebarRow(
            destination: .coreProvider(tool),
            title: coreProviderTitle(tool),
            icon: AnyView(ToolBrandIconView(tool: tool, size: 17).frame(width: 20, height: 20)),
            enabled: enabled,
            showsStatusDot: true,
            showsDragHandle: true
        )
        .contextMenu {
            Button(enabled ? L10n.Settings.sidebarHideFromOverview : L10n.Onboarding.subscriptionsShowInOverview) {
                settingsStore.settings.setCoreProviderVisible(!enabled, for: tool)
            }
        }
    }

    private func miscProviderRow(_ instance: MiscProviderInstance) -> some View {
        let enabled = instance.isVisible
        return sidebarRow(
            destination: .miscProvider(instance.id),
            // `menuTitle` is the L2 SubProvider, which is identical for the
            // Coding Plan / Token Plan / Agent Plan pairs — two sidebar rows
            // reading "Volcengine" with no way to tell which is which.
            // `displayName` keeps the plan.
            title: instance.displayTitle(fallback: instance.tool.displayName),
            icon: AnyView(ToolBrandIconView(tool: instance.tool, size: 17).frame(width: 20, height: 20)),
            enabled: enabled,
            showsStatusDot: true,
            showsDragHandle: true
        )
        .contextMenu {
            Button(enabled ? L10n.Settings.sidebarDisableProvider : L10n.Settings.sidebarEnableProvider) {
                settingsStore.settings.setMiscProviderInstanceVisible(!enabled, forID: instance.id)
            }
        }
    }

    private var miscLandingRow: some View {
        sidebarRow(
            destination: .page(.miscProviders),
            title: L10n.Onboarding.doneBrowserCookies,
            icon: AnyView(
                Image(systemName: "safari")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20, height: 20)
            ),
            enabled: true,
            showsStatusDot: false,
            showsDragHandle: false
        )
    }

    private func sidebarRow(
        destination: SettingsDestination,
        title: String,
        icon: AnyView,
        enabled: Bool,
        showsStatusDot: Bool,
        showsDragHandle: Bool
    ) -> some View {
        let selected = selection == destination
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 9) {
                icon
                    .opacity(enabled || selected ? 1 : 0.48)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsStatusDot {
                    Circle()
                        .fill(enabled ? Color.green : Color.secondary.opacity(0.42))
                        .frame(width: 6, height: 6)
                }
                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(selected ? Color.primary : (enabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 9)
            .frame(height: 33)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(WorkbenchPorcelain.selectedNavigationFill(for: colorScheme))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    WorkbenchPorcelain.hairline(for: colorScheme),
                                    lineWidth: Theme.Card.hairlineWidth
                                )
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.vibeBar(cornerRadius: 7))
        .opacity(enabled || selected ? 1 : 0.62)
    }

    private func coreProviderTitle(_ tool: ToolType) -> String {
        switch tool.coreProviderRepresentative {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .gemini: "Google AI"
        case .grok: "SpaceXAI"
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
