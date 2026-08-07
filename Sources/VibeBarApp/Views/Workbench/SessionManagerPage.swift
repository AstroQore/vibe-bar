import SwiftUI
import VibeBarCore

extension SessionProvider {
    /// The provider's identity elsewhere in the app. Every session provider
    /// is also a tool Vibe Bar tracks usage for, so brand badge, accent, and
    /// name all come from the one table rather than a second one here.
    var tool: ToolType {
        switch self {
        case .claude:      .claude
        case .codex:       .codex
        case .grok:        .grok
        case .gemini:      .gemini
        case .antigravity: .antigravity
        }
    }

    var accent: Color { Theme.providerAccent(for: tool) }
}

/// The Workbench's Sessions page.
///
/// A split, not a scroll: the list is a place you keep coming back to while
/// reading one transcript, so it stays put on the left instead of scrolling
/// away above the thing you selected. The toolbar above both columns is a
/// `CardShell` at the window density, which is what makes this page read as
/// the same material as Usage Stats.
struct SessionManagerPage: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    var body: some View {
        VStack(spacing: 0) {
            SessionFiltersBar(density: density, model: model)
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.top, density.popoverPaddingV)
                .padding(.bottom, density.popoverPaddingV / 2)
            HSplitView {
                SessionListView(density: density, model: model)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 620)
                TranscriptView(density: density, model: model)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { toastBanner }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: {
            Text("The session logs are removed from disk. This cannot be undone.")
        }
        .task { model.activate() }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { if !$0 { model.cancelDelete() } }
        )
    }

    private var deletionTitle: String {
        let count = model.pendingDeletion?.count ?? 0
        return count == 1 ? "Delete this session?" : "Delete \(count) sessions?"
    }

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: 460)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.dismissToast() }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Everything that narrows the session list, plus the page's own options.
///
/// Provider chips carry the brand accent for the same reason the usage
/// filters do — colour is how this app says "provider" — and the rest is
/// glass menus so a rarely-used control never outweighs the list.
struct SessionFiltersBar: View {
    let density: Theme.Density
    @ObservedObject var model: SessionManagerModel

    var body: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            HStack(spacing: 8) {
                searchField
                indexStatus
                SectionRefreshButton(isRefreshing: model.indexProgress != nil) {
                    model.refreshIndex()
                }
                .help("Rescan the session logs on disk")
            }
            Divider().opacity(0.35)
            providerChips
            controlRow
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: density.segmentedFontSize - 1))
                .foregroundStyle(.secondary)
            TextField("Search titles, projects, and message text", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: density.segmentedFontSize))
            if !model.searchText.isEmpty {
                BorderlessIconButton(systemImage: "xmark.circle.fill", help: "Clear the search") {
                    model.searchText = ""
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 27)
        .background(
            Capsule().fill(Color.primary.opacity(0.055))
                .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 0.6))
        )
    }

    @ViewBuilder
    private var indexStatus: some View {
        if let progress = model.indexProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 70)
                Text(progress.total > 0 ? "\(progress.done)/\(progress.total)" : "scanning…")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
        } else {
            Text(countSummary)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var countSummary: String {
        guard model.isIndexAvailable else { return "index unavailable" }
        let shown = model.rows.count
        return shown == 1 ? "1 session" : "\(shown) sessions"
    }

    // MARK: - Providers

    private var providerChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                allProvidersChip
                ForEach(SessionProvider.allCases, id: \.self) { provider in
                    providerChip(provider)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
    }

    private var allProvidersChip: some View {
        Button {
            model.setProviderFilter(nil)
        } label: {
            Text("All providers")
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .foregroundStyle(model.providerFilter == nil ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: .accentColor, selected: model.providerFilter == nil))
        .accessibilityLabel("Show every provider")
    }

    private func providerChip(_ provider: SessionProvider) -> some View {
        let selected = model.providerFilter?.contains(provider) ?? true
        let count = model.providerCounts[provider] ?? 0
        return Button {
            model.toggleProvider(provider)
        } label: {
            HStack(spacing: 5) {
                ToolBrandIconView(tool: provider.tool, size: density.segmentedFontSize + 1)
                Text(provider.displayName)
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: max(8, density.segmentedFontSize - 3), design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
        }
        .buttonStyle(.plain)
        .background(chipBackground(tint: provider.accent, selected: selected))
        .opacity(selected ? 1 : 0.45)
        .saturation(selected ? 1 : 0.2)
        .help(provider.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func chipBackground(tint: Color, selected: Bool) -> some View {
        ZStack {
            Capsule().fill(tint.opacity(selected ? 0.16 : 0.05))
            Capsule().stroke(tint.opacity(selected ? 0.55 : 0.18), lineWidth: 0.8)
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: 8) {
            rangeMenu
            sortMenu
            optionsMenu
            Spacer(minLength: 8)
            deleteControls
        }
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Date range", selection: $model.dateRange) {
                ForEach(SessionManagerModel.DateRange.allCases) { range in
                    Label(range.title, systemImage: range.systemImage).tag(range)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuLabel(systemImage: "calendar", title: "When", detail: model.dateRange.title)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose how far back to list sessions")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.sortOrder) {
                ForEach(SessionManagerModel.SortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Group by project", isOn: $model.groupByProject)
        } label: {
            menuLabel(
                systemImage: "arrow.up.arrow.down",
                title: "Sort",
                detail: model.groupByProject ? "\(model.sortOrder.title) · grouped" : model.sortOrder.title
            )
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Choose how the list is ordered")
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Open in", selection: terminalBinding) {
                ForEach(PreferredTerminal.allCases, id: \.self) { terminal in
                    Text(terminal.displayName).tag(terminal)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Index message text", isOn: bodyIndexingBinding)
            Button("Rebuild index…") { model.rebuildIndex() }
        } label: {
            menuLabel(systemImage: "slider.horizontal.3", title: "Options", detail: model.preferredTerminal.displayName)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Terminal and index options")
    }

    @ViewBuilder
    private var deleteControls: some View {
        if model.isDeleteMode {
            Button(role: .destructive) {
                model.requestDelete(model.checkedSummaries)
            } label: {
                Text(model.checkedIDs.isEmpty ? "Delete" : "Delete \(model.checkedIDs.count)")
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
            }
            .buttonStyle(.glass)
            .disabled(model.checkedIDs.isEmpty)
            .fixedSize()
        }
        Button {
            model.isDeleteMode.toggle()
        } label: {
            Label(model.isDeleteMode ? "Done" : "Select", systemImage: "checklist")
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.glass)
        .fixedSize()
        .help("Pick sessions to delete")
    }

    // MARK: - Bindings and labels

    private var terminalBinding: Binding<PreferredTerminal> {
        Binding(get: { model.preferredTerminal }, set: { model.setPreferredTerminal($0) })
    }

    private var bodyIndexingBinding: Binding<Bool> {
        Binding(get: { model.isBodyIndexingEnabled }, set: { model.setBodyIndexing($0) })
    }

    private func menuLabel(systemImage: String, title: String, detail: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: max(8, density.segmentedFontSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title.uppercased())
                .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Text(detail)
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(minHeight: 22)
    }
}
