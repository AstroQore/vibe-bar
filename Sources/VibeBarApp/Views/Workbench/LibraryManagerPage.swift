import AppKit
import SwiftUI
import VibeBarCore

/// Pieces the Library's MCP and AGENTS.md pages share. Each of those is its
/// own sidebar page; the model behind both lives in `WorkbenchServices`, so
/// switching between them keeps the last inventory on screen while the
/// page's `.task` re-reads it off the main thread.
extension View {
    /// The editor sheet and delete confirmation both Library pages raise.
    func libraryResourceChrome(model: AgentLibraryManagerModel) -> some View {
        modifier(LibraryResourceChrome(model: model))
    }
}

private struct LibraryResourceChrome: ViewModifier {
    @ObservedObject var model: AgentLibraryManagerModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.editor) { draft in LibraryResourceEditor(draft: draft, model: model) }
            .confirmationDialog(
                model.pendingDelete.map {
                    L10n.Workbench.Library.confirmDelete(name: $0.name + " · " + $0.target.libraryDisplayName)
                } ?? "",
                isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let row = model.pendingDelete {
                    Button(L10n.Common.delete, role: .destructive) { model.deleteMCP(row) }
                    Button(L10n.Common.cancel, role: .cancel) { model.pendingDelete = nil }
                }
            }
    }
}

extension AgentLibraryTarget {
    /// The Skills harness with the same brand mark, so a Library circle and
    /// a Skills circle for one agent are the same circle.
    var skillApp: SkillAppTarget {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .cursor: .cursor
        case .gemini: .gemini
        case .grok: .grok
        }
    }
}

/// One brand circle per harness, lit where the resource is shared — the
/// Skills toggle row's circle and dimming, driven by Library share state.
/// Click toggles; the per-circle spinner and failure badge are the feedback.
struct LibraryHarnessToggleRow<MenuContent: View>: View {
    let targets: [AgentLibraryTarget]
    /// Identifies the resource in `AgentLibraryManagerModel.toggleKey`.
    let resource: String
    let state: (AgentLibraryTarget) -> AgentLibraryShareState
    let activeToggle: String?
    let failedToggle: (key: String, code: String)?
    let isBusy: Bool
    /// An extra tooltip line for a target, e.g. where its link leads.
    var detail: (AgentLibraryTarget) -> String? = { _ in nil }
    let action: (AgentLibraryTarget) -> Void
    @ViewBuilder var menu: (AgentLibraryTarget) -> MenuContent

    @State private var hovered: AgentLibraryTarget?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(targets) { target in button(for: target) }
        }
    }

    private func button(for target: AgentLibraryTarget) -> some View {
        let current = state(target)
        let key = AgentLibraryManagerModel.toggleKey(id: resource, target)
        let failure = failedToggle?.key == key ? failedToggle?.code : nil
        let working = activeToggle == key
        let help = Self.help(target: target, state: current, failure: failure, detail: detail(target))
        return Button {
            action(target)
        } label: {
            HarnessToggleCircle(app: target.skillApp, isOn: current.isOn, isHovered: hovered == target) {
                badge(current, failure: failure)
            }
            .overlay {
                if working { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.vibeBar)
        .disabled(isBusy)
        .opacity(Self.opacity(current))
        .saturation(Self.saturation(current))
        .onHover { hovering in hovered = hovering ? target : (hovered == target ? nil : hovered) }
        .help(help)
        .contextMenu { menu(target) }
        .accessibilityLabel(target.libraryDisplayName)
        .accessibilityValue(help)
        .accessibilityAddTraits(current.isOn ? [.isSelected] : [])
    }

    @ViewBuilder
    private func badge(_ state: AgentLibraryShareState, failure: String?) -> some View {
        if failure != nil {
            badgeImage(systemName: "exclamationmark.triangle.fill", color: .red)
        } else {
            switch state {
            case .linked:
                // Informational, like Skills' coupled badge: shared through
                // a link the user made, which Vibe Bar shows but never owns.
                badgeImage(systemName: "link.circle.fill", color: .secondary)
            case .differs:
                badgeImage(systemName: "exclamationmark.circle.fill", color: .orange)
            case .shared, .off, .unavailable:
                EmptyView()
            }
        }
    }

    private func badgeImage(systemName name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .background(Circle().fill(.background))
    }

    private static func opacity(_ state: AgentLibraryShareState) -> Double {
        switch state {
        case .shared, .linked: 1
        case .differs: 0.82
        case .off: 0.62
        case .unavailable: 0.32
        }
    }

    private static func saturation(_ state: AgentLibraryShareState) -> Double {
        switch state {
        case .shared, .linked: 1
        case .differs: 0.65
        case .off: 0.45
        case .unavailable: 0
        }
    }

    static func help(target: AgentLibraryTarget, state: AgentLibraryShareState,
                     failure: String?, detail: String?) -> String {
        let name = target.libraryDisplayName
        if let failure { return name + " — " + AgentLibraryManagerModel.message(code: failure) }
        var text: String
        switch state {
        case .shared(managed: true):
            text = L10n.Workbench.Library.availableTo(agents: name) + " · " + L10n.Workbench.Library.managed
        case .shared(managed: false), .linked:
            text = L10n.Workbench.Library.availableTo(agents: name)
        case .differs:
            text = name + " — " + L10n.Workbench.Library.Error.sameNameConflict
        case .off:
            text = L10n.Workbench.Library.targets + " " + name
        case .unavailable(let code):
            text = name + " — " + AgentLibraryManagerModel.message(code: code)
        }
        if let detail { text += "\n" + detail }
        return text
    }
}

struct LibrarySourcePath: View {
    let title: String
    let path: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).foregroundStyle(.tertiary)
            Button(path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(path)
        }.font(.caption)
    }
}

struct LibraryStatusLabel: View {
    let status: AgentLibraryFileStatus
    let errorCode: String?
    var body: some View {
        Text(label).font(.caption).foregroundStyle(status == .ready || status == .missing ? Color.secondary : .orange)
    }
    private var label: String {
        if let errorCode { return AgentLibraryManagerModel.message(code: errorCode) }
        switch status {
        case .ready: return L10n.Workbench.Library.readable
        case .missing: return L10n.Workbench.Library.notCreated
        case .invalid: return L10n.Workbench.Library.Error.invalidDocument
        case .unsafe: return L10n.Workbench.Library.Error.unsafePath
        case .unsupported: return L10n.Workbench.Library.Error.unsupportedTarget
        }
    }
}

struct LibraryMessage: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
