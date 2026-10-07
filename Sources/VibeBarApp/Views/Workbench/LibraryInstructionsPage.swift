import SwiftUI
import VibeBarCore

/// The shared instructions file and the agents that read it. The circles on
/// the shared card are the share switches: lit where the agent's file
/// already leads to the shared one — including links the user made, which
/// carry a link badge and are never removed from here.
struct LibraryInstructionsPage: View {
    let density: Theme.Density
    @ObservedObject var model: AgentLibraryManagerModel

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            HStack {
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(L10n.Common.refresh) { Task { await model.refresh(.instructions) } }
                    .buttonStyle(WorkbenchPillButtonStyle())
            }.disabled(model.isBusy)
            LibraryMessage(message: model.message)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    ForEach(model.instructions.filter { $0.status != .unsupported }) { row in instruction(row) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, density.popoverPaddingH).padding(.vertical, density.popoverPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .libraryResourceChrome(model: model)
        .task {
            model.message = nil
            await model.refresh(.instructions)
        }
    }

    private func instruction(_ row: AgentInstructionSummary) -> some View {
        CardShell(density: density) {
            HStack(alignment: .center, spacing: 8) {
                Text(row.isCanonical ? L10n.Workbench.Library.canonical : row.target?.libraryDisplayName ?? row.id)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Spacer(minLength: 8)
                if row.isCanonical { shareToggles }
            }
            if !row.path.isEmpty { LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: row.path) }
            if row.isSymlink, let resolved = row.resolvedPath {
                LibrarySourcePath(title: L10n.Workbench.Library.linkedSource, path: resolved)
            }
            LibraryStatusLabel(status: row.status, errorCode: row.errorCode)
            if let override = row.overridePath {
                Text(L10n.Workbench.Library.overrideActive(file: override)).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.Workbench.Library.editInstructions) { model.editInstruction(row) }
                    .disabled(row.status != .ready && row.status != .missing)
                Spacer()
            }.buttonStyle(WorkbenchPillButtonStyle()).disabled(model.isBusy)
        }
    }

    private var shareToggles: some View {
        let states = model.instructionStates
        let rows = model.instructions
        return LibraryHarnessToggleRow(
            targets: AgentLibraryTarget.allCases.filter { states[$0] != nil },
            resource: "instructions",
            state: { states[$0] ?? .off },
            activeToggle: model.activeToggle,
            failedToggle: model.failedToggle,
            isBusy: model.isBusy,
            detail: { target in
                guard let row = rows.first(where: { $0.target == target }), row.isSymlink,
                      let resolved = row.resolvedPath else { return nil }
                return L10n.Workbench.Library.linkedSource + ": " + resolved
            },
            action: { model.toggleInstruction($0) },
            menu: { _ in EmptyView() }
        )
    }
}
