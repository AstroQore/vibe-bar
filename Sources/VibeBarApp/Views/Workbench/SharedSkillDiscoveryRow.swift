import AppKit
import SwiftUI
import VibeBarCore

/// One entry the registry does not own — a folder or link found in the
/// shared root, or an adopted link whose receipt no longer matches — with
/// the few actions that apply to it. Nothing here edits the entry's files:
/// adopting and re-confirming write `skills.json`, unlinking removes the
/// recorded link and its projections.
struct SharedSkillDiscoveryRow: View {
    let entry: SharedSkillDiscovery
    let density: Theme.Density
    var isBusy = false
    let preview: () -> Void
    var onAdoptLink: () -> Void = {}
    var onReconfirm: () -> Void = {}
    var onUnlink: () -> Void = {}

    @State private var confirmingUnlink = false

    private var sourceChanged: Bool {
        if case .receiptMismatch = entry.registration { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: density.cardSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name).font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    Text(stateLabel).font(.caption)
                        .foregroundStyle(entry.state == .ready && !sourceChanged ? Color.secondary : .orange)
                }
                if let detail = registrationDetail {
                    Text(detail).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Points into a folder Vibe Bar writes itself (another
                // agent's skills folder, the shared root), so there is
                // nothing outside to adopt: the agent that folder belongs to
                // manages it.
                if entry.linkTargetUnsupported, entry.state == .ready {
                    Text(L10n.Workbench.Library.Error.notOwnedProjection).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let description = entry.description {
                    Text(description).font(.system(size: density.subtitleFontSize)).foregroundStyle(.secondary).lineLimit(2)
                }
                path(entry.logicalURL, title: L10n.Workbench.Skills.Wiring.source)
                if entry.isSymlink, let target = entry.resolvedURL, entry.state != .missing {
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
            if entry.canAdoptLink {
                Button(L10n.Workbench.Library.adoptLink, action: onAdoptLink)
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                    .help(L10n.Workbench.Library.adoptLinkHelp)
                    .disabled(isBusy)
            }
            if entry.canReconfirmLink {
                Button(L10n.Workbench.Skills.menuReconfirmSource, action: onReconfirm)
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true))
                    .disabled(isBusy)
            }
            if entry.canUnlink {
                Button(L10n.Workbench.Skills.unlink) { confirmingUnlink = true }
                    .buttonStyle(WorkbenchPillButtonStyle())
                    .disabled(isBusy)
            }
            if entry.state != .missing {
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
        }
        .padding(.vertical, density.cardSpacing)
        .padding(.horizontal, 4)
        .opacity(isBusy ? 0.55 : 1)
        .confirmationDialog(
            L10n.Workbench.Skills.unlinkConfirmTitle(skill: entry.name),
            isPresented: $confirmingUnlink,
            titleVisibility: .visible
        ) {
            Button(L10n.Workbench.Skills.unlink, role: .destructive) { onUnlink() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Workbench.Skills.unlinkConfirmMessage)
        }
    }

    /// Why an adopted link sits in the read-only list, and what gets it out.
    private var registrationDetail: String? {
        guard case let .receiptMismatch(_, reason) = entry.registration else { return nil }
        switch reason {
        case .notALink: return L10n.Workbench.Library.linkReplacedDetail
        case .missing, .retargeted, .resolvesElsewhere, .replaced, .unavailable:
            return L10n.Workbench.Library.sourceChangedDetail
        }
    }

    private var availableAgents: String {
        SkillAppTarget.managedHarnesses.filter { entry.agents[$0] == .available }.map(\.displayName).joined(separator: ", ")
    }

    private var stateLabel: String {
        if entry.state == .missing { return L10n.Workbench.Library.linkMissing }
        if sourceChanged, entry.state == .ready { return L10n.Workbench.Library.sourceChanged }
        switch entry.state {
        case .ready: return entry.isSymlink ? L10n.Workbench.Library.linkedSource : L10n.Workbench.Library.discovered
        case .brokenLink: return L10n.Workbench.Library.brokenLink
        case .cyclicLink: return L10n.Workbench.Library.cyclicLink
        case .missingSkillFile: return L10n.Workbench.Library.missingSkillFile
        case .unreadable: return L10n.Workbench.Library.unreadable
        case .tooLarge: return L10n.Workbench.Library.tooLarge
        case .missing: return L10n.Workbench.Library.linkMissing
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
