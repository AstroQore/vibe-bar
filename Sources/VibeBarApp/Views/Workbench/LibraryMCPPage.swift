import SwiftUI
import VibeBarCore

/// One card per server name, with a brand circle per harness: lit where the
/// harness already defines that server (whoever wrote it), dim where it can
/// be shared with a click, faded where Core says it cannot go.
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
                    ForEach(model.mcpGroups) { group in definition(group) }
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
        .libraryResourceChrome(model: model)
        .task {
            model.message = nil
            await model.refresh(.mcp)
        }
    }

    private func definition(_ group: AgentMCPGroup) -> some View {
        let primary = group.primary
        let managed = group.rows.values.first { $0.projectionOwned }
        return CardShell(density: density) {
            HStack(alignment: .center, spacing: 8) {
                Text(group.name).font(.system(size: density.titleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                LibraryHarnessToggleRow(
                    targets: AgentLibraryTarget.allCases,
                    resource: group.id,
                    state: { group.states[$0] ?? .off },
                    activeToggle: model.activeToggle,
                    failedToggle: model.failedToggle,
                    isBusy: model.isBusy,
                    action: { model.toggleMCP(group, target: $0) },
                    menu: { target in
                        if let row = group.rows[target] {
                            Button(L10n.Workbench.Library.edit) { model.editMCP(row) }
                            Button(L10n.Common.delete, role: .destructive) { model.pendingDelete = row }
                        }
                    }
                )
            }
            LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: primary.path)
            LabeledContent(L10n.Workbench.Library.transport, value: primary.transport.rawValue).font(.caption)
            if let managed, let source = managed.sharedSourceTarget {
                HStack {
                    Text(L10n.Workbench.Library.managed)
                    Text(L10n.Workbench.Skills.Wiring.source + ": " + source.libraryDisplayName)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if primary.status != .ready { LibraryStatusLabel(status: primary.status, errorCode: primary.errorCode) }
            HStack {
                Button(L10n.Workbench.Library.edit) { model.editMCP(primary) }
                Spacer()
            }.buttonStyle(WorkbenchPillButtonStyle()).disabled(model.isBusy)
        }
    }
}
