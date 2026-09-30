import SwiftUI
import VibeBarCore

struct LibraryInstructionsPage: View {
    let density: Theme.Density
    @ObservedObject var model: AgentLibraryManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            HStack {
                Button(L10n.Workbench.Library.linkInstructions) { model.beginLinkInstructions() }
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                    .disabled(model.instructions.first { $0.isCanonical }?.status != .ready)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(L10n.Common.refresh) { Task { await model.refresh(.instructions) } }
                    .buttonStyle(WorkbenchPillButtonStyle())
            }.disabled(model.isBusy)
            LibraryMessage(message: model.message)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    ForEach(model.instructions) { row in instruction(row) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, density.popoverPaddingH).padding(.vertical, density.popoverPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func instruction(_ row: AgentInstructionSummary) -> some View {
        CardShell(density: density) {
            Text(row.isCanonical ? L10n.Workbench.Library.canonical : row.target?.libraryDisplayName ?? row.id)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            if !row.path.isEmpty { LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: row.path) }
            if row.isSymlink, let resolved = row.resolvedPath {
                LibrarySourcePath(title: L10n.Workbench.Library.linkedSource, path: resolved)
            }
            LibraryStatusLabel(status: row.status, errorCode: row.errorCode)
            if let override = row.overridePath {
                Text(L10n.Workbench.Library.overrideActive(file: override)).font(.caption).foregroundStyle(.orange)
            }
            if row.isCanonical, let source = row.resolvedPath {
                let targets = model.instructions.filter { !$0.isCanonical && $0.isSymlink && $0.resolvedPath == source }
                    .compactMap(\.target).map(\.libraryDisplayName)
                if !targets.isEmpty { Text(L10n.Workbench.Library.availableTo(agents: targets.joined(separator: ", "))).font(.caption) }
            }
            HStack {
                Button(L10n.Workbench.Library.editInstructions) { model.editInstruction(row) }
                    .disabled(row.status != .ready && row.status != .missing)
                Spacer()
                if row.projectionOwned {
                    Button(L10n.Workbench.Library.removeProjection, role: .destructive) { model.pendingRemoveProjection = row }
                }
            }.buttonStyle(WorkbenchPillButtonStyle()).disabled(model.isBusy)
        }
    }
}
