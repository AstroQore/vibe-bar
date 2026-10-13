import SwiftUI
import VibeBarCore

/// Actions apply to the selected compared version, independently of the two
/// read-only comparison pickers. Every mutation goes through the page model.
struct SkillCopyResolutionControls: View {
    let skill: Skill
    @ObservedObject var model: SkillsManagerModel
    @ObservedObject var detail: SkillCopiesDetailModel
    @State private var pending: Request?

    private struct Request {
        let action: Action
        let version: SkillVersion
    }

    private enum Action: String, Identifiable {
        case replace, overwrite, adopt, restore
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replace: L10n.Workbench.Skills.Copies.replaceShared
            case .overwrite: L10n.Workbench.Skills.Copies.overwriteCopy
            case .adopt: L10n.Workbench.Skills.Copies.adoptManaged
            case .restore: L10n.Workbench.Skills.Copies.restoreShared
            }
        }
    }

    private var version: SkillVersion? { detail.version(id: detail.comparedID) }
    private var harnessCopy: SkillCopy? {
        guard let version, let copy = version.copy,
              copy.directoryName == skill.directory else { return nil }
        switch version.kind {
        case .independentCopy, .managedCopy: return copy
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.inventory != nil, !skill.isLinked {
                Text(detail.differingCopiesCount == 0
                     ? (detail.unknownCopiesCount == 0 ? L10n.Workbench.Skills.Copies.allMatch : L10n.Workbench.Skills.Copies.notCompared)
                     : L10n.Workbench.Skills.Copies.differCount(count: detail.differingCopiesCount))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !skill.isLinked, let version, version.isReadable {
                HStack(spacing: 8) {
                    if let copy = version.copy, version.comparison == .differs, copy.name == skill.name {
                        action(.replace)
                    }
                    if harnessCopy != nil {
                        if version.comparison == .differs { action(.overwrite) }
                        if case .independentCopy = version.kind { action(.adopt) }
                    }
                    if case .backup = version.kind { action(.restore) }
                    Spacer(minLength: 0)
                }
                .disabled(model.isBusy(skill: skill))
            }
        }
        .confirmationDialog(pending?.action.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { request in
            let action = request.action
            if action == .adopt, let copy = request.version.copy {
                Button(L10n.Workbench.Skills.Copies.adoptShared, role: .destructive) {
                    model.adoptCopy(skill: skill, copy: copy, replaceShared: false)
                }
                if request.version.comparison == .differs, copy.name == skill.name {
                    Button(L10n.Workbench.Skills.Copies.adoptCompared, role: .destructive) {
                        model.adoptCopy(skill: skill, copy: copy, replaceShared: true)
                    }
                }
            } else {
                Button(action.title, role: .destructive) { perform(request) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { request in
            Text(request.action == .adopt
                 ? L10n.Workbench.Skills.Copies.adoptNotice(path: model.skillBackupDirectory)
                 : L10n.Workbench.Skills.Copies.backupNotice(path: model.skillBackupDirectory))
        }
    }

    private func action(_ action: Action) -> some View {
        Button(action.title) { if let version { pending = Request(action: action, version: version) } }
            .buttonStyle(WorkbenchPillButtonStyle())
    }

    private func perform(_ request: Request) {
        let version = request.version
        switch request.action {
        case .replace:
            if let copy = version.copy { model.replaceSharedCopy(skill: skill, with: copy) }
        case .overwrite:
            if let copy = version.copy { model.overwriteCopy(skill: skill, copy: copy) }
        case .restore:
            model.restoreCopy(skill: skill, backup: version.url.deletingLastPathComponent())
        case .adopt: break
        }
    }
}

struct SkillMergeControls: View {
    let skill: Skill
    @ObservedObject var model: SkillsManagerModel
    @ObservedObject var detail: SkillCopiesDetailModel
    private struct Request {
        let copy: SkillCopy
        let resolutions: [String: SkillMergeSide]
        let sharedHash: String?
    }
    @State private var pending: Request?

    var body: some View {
        if !skill.isLinked, detail.mergeCopy != nil, !detail.changedPaths.isEmpty {
            Text(detail.unresolvedCount == 0
                 ? L10n.Workbench.Skills.Copies.mergeReady
                 : L10n.Workbench.Skills.Copies.unresolved(count: detail.unresolvedCount))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L10n.Workbench.Skills.Copies.mergeShared) {
                if let copy = detail.mergeCopy {
                    pending = Request(copy: copy, resolutions: detail.resolutions,
                                      sharedHash: detail.version(id: detail.baseID)?.contentHash)
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!detail.canMerge || model.isBusy(skill: skill))
                .confirmationDialog(L10n.Workbench.Skills.Copies.mergeShared, isPresented: Binding(
                    get: { pending != nil }, set: { if !$0 { pending = nil } }
                ), titleVisibility: .visible, presenting: pending) { request in
                    Button(L10n.Workbench.Skills.Copies.mergeShared, role: .destructive) {
                        model.mergeCopy(skill: skill, copy: request.copy, resolutions: request.resolutions,
                                        sharedHash: request.sharedHash)
                    }
                    Button(L10n.Common.cancel, role: .cancel) {}
                } message: { _ in
                    Text(L10n.Workbench.Skills.Copies.backupNotice(path: model.skillBackupDirectory))
                }
        }
    }
}
