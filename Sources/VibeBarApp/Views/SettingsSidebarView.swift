import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// One settings navigator for both static preferences and provider-specific
/// configuration. Provider ordering is edited directly where it is consumed,
/// rather than in a second, disconnected ordering screen.
struct SettingsSidebarView: View {
    static let width: CGFloat = 236

    @EnvironmentObject private var settingsStore: SettingsStore
    @Binding var selection: SettingsDestination

    @State private var searchText = ""
    @State private var draggedCoreProvider: ToolType?
    @State private var draggedMiscProviderID: String?

    private let basicPages: [SettingsSectionID] = [
        .system,
        .costData,
        .privacy,
        .menuBar,
        .miniWindow,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Vibe Bar")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if searchText.isEmpty || !filteredBasicPages.isEmpty {
                        sidebarGroup("Settings") {
                            ForEach(filteredBasicPages, id: \.rawValue) { page in
                                staticRow(page)
                            }
                        }
                    }

                    if searchText.isEmpty || !filteredCoreProviders.isEmpty {
                        sidebarGroup("Core Providers") {
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

                    if searchText.isEmpty || !filteredMiscProviders.isEmpty {
                        sidebarGroup("Misc Providers") {
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
        .background(Color.primary.opacity(0.035))
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
        settingsStore.settings.miscProviderInstances.filter { instance in
            let title = instance.displayTitle(fallback: instance.tool.menuTitle)
            return searchText.isEmpty
                || title.localizedCaseInsensitiveContains(searchText)
                || instance.tool.vendorName.localizedCaseInsensitiveContains(searchText)
        }
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
            Button(enabled ? "Hide from Overview" : "Show in Overview") {
                settingsStore.settings.setCoreProviderVisible(!enabled, for: tool)
            }
        }
    }

    private func miscProviderRow(_ instance: MiscProviderInstance) -> some View {
        let enabled = instance.isVisible
        return sidebarRow(
            destination: .miscProvider(instance.id),
            title: instance.displayTitle(fallback: instance.tool.menuTitle),
            icon: AnyView(ToolBrandIconView(tool: instance.tool, size: 17).frame(width: 20, height: 20)),
            enabled: enabled,
            showsStatusDot: true,
            showsDragHandle: true
        )
        .contextMenu {
            Button(enabled ? "Disable Provider" : "Enable Provider") {
                settingsStore.settings.setMiscProviderInstanceVisible(!enabled, forID: instance.id)
            }
        }
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
                        .fill(Color.accentColor.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.32), lineWidth: 0.6)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .opacity(enabled || selected ? 1 : 0.62)
    }

    private func coreProviderTitle(_ tool: ToolType) -> String {
        switch tool.coreProviderRepresentative {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .gemini: "Google AI"
        case .grok: "xAI"
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
