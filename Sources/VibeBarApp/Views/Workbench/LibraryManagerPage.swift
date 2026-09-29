import AppKit
import SwiftUI
import VibeBarCore

/// Keeps the established Skills page and its actions in the same navigation
/// position while adding native-config resources beside it.
struct LibraryManagerPage: View {
    let density: Theme.Density
    @ObservedObject var skills: SkillsManagerModel
    @StateObject private var library: AgentLibraryManagerModel
    @State private var selected: LibraryResourceKind = .skills

    init(density: Theme.Density, skills: SkillsManagerModel, homeDirectory: URL) {
        self.density = density
        self.skills = skills
        _library = StateObject(wrappedValue: AgentLibraryManagerModel(homeDirectory: homeDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.Workbench.Library.title, selection: $selected) {
                ForEach(LibraryResourceKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, density.popoverPaddingH)
            .padding(.top, density.popoverPaddingV)
            Group {
                switch selected {
                case .skills: SkillsManagerPage(density: density, model: skills)
                case .mcp: LibraryMCPPage(density: density, model: library)
                case .instructions: LibraryInstructionsPage(density: density, model: library)
                }
            }
        }
        .task(id: selected) {
            library.message = nil
            await library.refresh(selected)
        }
        .onChange(of: skills.refreshRevision) { _, _ in Task { await library.refresh(selected) } }
        .sheet(item: $library.editor) { draft in LibraryResourceEditor(draft: draft, model: library) }
        .sheet(item: $library.shareDraft) { draft in LibraryShareSheet(draft: draft, model: library) }
        .confirmationDialog(
            library.pendingDelete.map { L10n.Workbench.Library.confirmDelete(name: $0.name) } ?? "",
            isPresented: Binding(get: { library.pendingDelete != nil }, set: { if !$0 { library.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let row = library.pendingDelete {
                Button(L10n.Common.delete, role: .destructive) { library.deleteMCP(row) }
                Button(L10n.Common.cancel, role: .cancel) { library.pendingDelete = nil }
            }
        }
        .confirmationDialog(
            L10n.Workbench.Library.removeProjection,
            isPresented: Binding(get: { library.pendingRemoveProjection != nil }, set: { if !$0 { library.pendingRemoveProjection = nil } }),
            titleVisibility: .visible
        ) {
            if let row = library.pendingRemoveProjection {
                Button(L10n.Common.remove, role: .destructive) { library.removeProjection(row) }
                Button(L10n.Common.cancel, role: .cancel) { library.pendingRemoveProjection = nil }
            }
        }
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
