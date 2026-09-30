import SwiftUI
import VibeBarCore

struct LibraryMCPPage: View {
    let density: Theme.Density
    @ObservedObject var model: AgentLibraryManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            HStack {
                Button(L10n.Workbench.Library.addMCP) { model.beginNewMCP() }
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(L10n.Common.refresh) { Task { await model.refresh(.mcp) } }
                    .buttonStyle(WorkbenchPillButtonStyle())
            }.disabled(model.isBusy)
            LibraryMessage(message: model.message)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    if model.mcp?.definitions.isEmpty == true {
                        CardShell(density: density) { Text(L10n.Workbench.Library.emptyMCP).foregroundStyle(.secondary) }
                    }
                    ForEach(model.mcp?.definitions ?? []) { row in definition(row) }
                    ForEach(model.mcp?.files ?? []) { file in
                        CardShell(density: density) {
                            Text(file.target.libraryDisplayName).font(.system(size: density.titleFontSize, weight: .semibold))
                            LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: file.path)
                            LibraryStatusLabel(status: file.status, errorCode: file.errorCode)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, density.popoverPaddingH).padding(.vertical, density.popoverPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func definition(_ row: AgentMCPDefinitionSummary) -> some View {
        CardShell(density: density) {
            HStack {
                Text(row.name).font(.system(size: density.titleFontSize, weight: .semibold))
                Spacer()
                Text(row.target.libraryDisplayName).font(.caption).foregroundStyle(.secondary)
            }
            LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: row.path)
            LabeledContent(L10n.Workbench.Library.transport, value: row.transport.rawValue).font(.caption)
            LabeledContent(L10n.Workbench.Library.targets, value: ([row.target] + row.matchingTargets)
                .map(\.libraryDisplayName).joined(separator: ", ")).font(.caption)
            if row.projectionOwned, let source = row.sharedSourceTarget {
                HStack {
                    Text(L10n.Workbench.Library.managed)
                    Text(L10n.Workbench.Skills.Wiring.source + ": " + source.libraryDisplayName)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if row.status != .ready { LibraryStatusLabel(status: row.status, errorCode: row.errorCode) }
            HStack {
                Button(L10n.Workbench.Library.edit) { model.editMCP(row) }
                Button(L10n.Workbench.Library.targets) { model.beginShareMCP(row) }.disabled(row.status != .ready)
                Spacer()
                Button(L10n.Common.delete, role: .destructive) { model.pendingDelete = row }
            }.buttonStyle(WorkbenchPillButtonStyle()).disabled(model.isBusy)
        }
    }
}
