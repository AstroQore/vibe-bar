import AppKit
import SwiftUI
import VibeBarCore

struct SharedSkillDiscoveryRow: View {
    let entry: SharedSkillDiscovery
    let density: Theme.Density
    let preview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: density.cardSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name).font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Text(stateLabel).font(.caption).foregroundStyle(entry.state == .ready ? Color.secondary : .orange)
                }
                if let description = entry.description {
                    Text(description).font(.system(size: density.subtitleFontSize)).foregroundStyle(.secondary).lineLimit(2)
                }
                path(entry.logicalURL, title: L10n.Workbench.Skills.Wiring.source)
                if entry.isSymlink, let target = entry.resolvedURL {
                    path(target, title: L10n.Workbench.Library.linkedSource)
                }
                if !entry.agents.isEmpty {
                    if !availableAgents.isEmpty {
                        Text(L10n.Workbench.Library.availableTo(agents: availableAgents))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let disabled = SkillAppTarget.managedHarnesses.filter { entry.agents[$0] == .disabled }
                    ForEach(disabled, id: \.self) { app in
                        Text(L10n.Workbench.Skills.Badge.nativeOff(app: app.displayName)).font(.caption).foregroundStyle(.orange)
                    }
                    if entry.agents.values.contains(.unknown) {
                        Text(L10n.Workbench.Skills.Badge.nativeUnknownHelp).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(L10n.Workbench.Library.readOnlySource).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button(L10n.MenuBar.Composer.preview, action: preview)
                .buttonStyle(WorkbenchPillButtonStyle())
                .disabled(entry.state != .ready)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.logicalURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.vibeBar)
            .help(L10n.Workbench.Skills.menuRevealInFinder)
        }
        .padding(.vertical, density.cardSpacing)
        .padding(.horizontal, 4)
    }

    private var availableAgents: String {
        SkillAppTarget.managedHarnesses.filter { entry.agents[$0] == .available }.map(\.displayName).joined(separator: ", ")
    }

    private var stateLabel: String {
        switch entry.state {
        case .ready: entry.isSymlink ? L10n.Workbench.Library.linkedSource : L10n.Workbench.Library.discovered
        case .brokenLink: L10n.Workbench.Library.brokenLink
        case .cyclicLink: L10n.Workbench.Library.cyclicLink
        case .missingSkillFile: L10n.Workbench.Library.missingSkillFile
        case .unreadable: L10n.Workbench.Library.unreadable
        case .tooLarge: L10n.Workbench.Library.tooLarge
        case .missing: L10n.Workbench.Library.brokenLink
        }
    }

    private func path(_ url: URL, title: String) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.tertiary)
            Button(url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(url.path)
        }.font(.caption)
    }
}

struct SharedSkillPreviewSheet: View {
    let preview: SharedSkillPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.name).font(.headline)
            Text(preview.source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                Text(preview.text).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(L10n.Common.done) { dismiss() } }
        }.padding(20).frame(minWidth: 680, minHeight: 480)
    }
}
