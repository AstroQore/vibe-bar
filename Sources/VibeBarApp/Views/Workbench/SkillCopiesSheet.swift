import AppKit
import SwiftUI
import VibeBarCore

/// Every copy of one installed skill — where it is, what it is, whether it
/// matches the shared copy — and a file-by-file, line-by-line comparison of
/// any two of them.
///
/// The sheet only renders stored state: the inventory, comparisons and line
/// diffs are computed by `SkillCopiesDetailModel` on detached tasks and
/// cached by content hash. The actions that change something (replace the
/// shared copy, accept local edits) go through `SkillsManagerModel`, whose
/// reload hands this sheet a new `Skill` and so a fresh inventory.
struct SkillCopiesSheet: View {
    let density: Theme.Density
    let skillID: SkillID
    @ObservedObject var model: SkillsManagerModel
    @StateObject private var detail: SkillCopiesDetailModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingReplacement: SkillCopy?

    init(density: Theme.Density, skillID: SkillID, model: SkillsManagerModel) {
        self.density = density
        self.skillID = skillID
        self.model = model
        _detail = StateObject(wrappedValue: model.makeCopiesDetailModel())
    }

    private var skill: Skill? { model.skill(with: skillID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let skill {
                HStack(alignment: .top, spacing: 0) {
                    versionList(skill)
                        .frame(width: 330)
                    Divider()
                    SkillComparisonPane(density: density, detail: detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            Divider()
            footer
        }
        // Fits inside the Workbench window's 1040 × 680 minimum, so the sheet
        // never hangs past its parent.
        .frame(minWidth: 900, idealWidth: 980, minHeight: 560, idealHeight: 630)
        .onAppear { if let skill { detail.load(skill) } }
        .onChange(of: skill) { _, latest in
            if let latest { detail.load(latest) } else { dismiss() }
        }
        .confirmationDialog(
            L10n.Workbench.Skills.Copies.replaceConfirmTitle(skill: skill?.name ?? ""),
            isPresented: Binding(
                get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingReplacement
        ) { copy in
            Button(L10n.Workbench.Skills.Copies.replaceShared, role: .destructive) {
                if let skill { model.replaceSharedCopy(skill: skill, with: copy) }
                pendingReplacement = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingReplacement = nil }
        } message: { _ in
            Text(L10n.Workbench.Skills.Copies.replaceConfirmMessage)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Workbench.Skills.Copies.title(skill: skill?.name ?? ""))
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(L10n.Workbench.Skills.Copies.subtitle)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let skill, skill.isLocallyModified {
                Text(L10n.Workbench.Skills.Badge.modified)
                    .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .help(L10n.Workbench.Skills.Badge.modifiedHelp)
                Button(L10n.Workbench.Skills.menuAcceptLocalChanges) {
                    model.acceptLocalChanges(skill)
                }
                .buttonStyle(WorkbenchPillButtonStyle())
                .disabled(model.isBusy(skill: skill))
            }
            if let skill, model.isBusy(skill: skill) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.Common.done) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    // MARK: - Versions

    private func versionList(_ skill: Skill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if skill.isLinked {
                    // Its folder lies outside every root a comparison may
                    // read, so every version is listed and none compared.
                    Label(L10n.Workbench.Skills.Copies.linkedNotCompared, systemImage: "link")
                        .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .workbenchFieldSurface()
                }
                if detail.inventory?.baseline == .unavailable {
                    Label(L10n.Workbench.Skills.Copies.baselineUnavailable, systemImage: "info.circle")
                        .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .workbenchFieldSurface()
                }
                if detail.inventory == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)
                }
                ForEach(detail.versions) { version in
                    SkillVersionRow(
                        density: density,
                        version: version,
                        skill: skill,
                        role: role(of: version),
                        onSelect: { detail.setCompared(version.id) },
                        onReplace: { copy in pendingReplacement = copy }
                    )
                }
            }
            .padding(12)
        }
    }

    private func role(of version: SkillVersion) -> SkillVersionRow.Role {
        if version.id == detail.baseID { return .base }
        if version.id == detail.comparedID { return .compared }
        return .none
    }
}

// MARK: - One version

private struct SkillVersionRow: View {
    enum Role { case none, base, compared }

    let density: Theme.Density
    let version: SkillVersion
    let skill: Skill
    let role: Role
    let onSelect: () -> Void
    let onReplace: (SkillCopy) -> Void

    @State private var isHovering = false
    @State private var copiedPath = false
    @Environment(\.colorScheme) private var colorScheme

    private var smallFont: Font { .system(size: max(9, density.resetCountdownFontSize - 1)) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            glyph
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    kindChip
                    Spacer(minLength: 4)
                    roleMarker
                }
                status
                if let changed = version.changedText {
                    Text(changed).font(smallFont).foregroundStyle(.tertiary)
                }
                pathLine
                if let copy = replaceableCopy {
                    Button(L10n.Workbench.Skills.Copies.replaceShared) { onReplace(copy) }
                        .buttonStyle(WorkbenchPillButtonStyle())
                        .padding(.top, 2)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    role == .none ? WorkbenchPorcelain.hairline(for: colorScheme) : roleTint.opacity(0.55),
                    lineWidth: role == .none ? Theme.Card.hairlineWidth : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { if version.isReadable, role != .base { onSelect() } }
    }

    private var background: Color {
        if role != .none { return roleTint.opacity(0.07) }
        return isHovering ? WorkbenchPorcelain.hoverFill(for: colorScheme) : WorkbenchPorcelain.toolbarFill(for: colorScheme)
    }

    private var roleTint: Color { role == .base ? Color.secondary : WorkbenchPorcelain.accent }

    @ViewBuilder
    private var roleMarker: some View {
        switch role {
        case .base:
            Text(L10n.Workbench.Skills.Copies.Diff.base)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(.secondary)
        case .compared:
            Text(L10n.Workbench.Skills.Copies.Diff.compared)
                .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .semibold))
                .foregroundStyle(WorkbenchPorcelain.accent)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var glyph: some View {
        Group {
            if let app = version.kind.app {
                SkillAppGlyph(app: app, size: 13)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(app.accent.opacity(0.10)))
            } else {
                Image(systemName: version.kind == .shared ? "tray.full" : "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
        }
    }

    private var title: String {
        switch version.kind {
        case .shared: L10n.Workbench.Status.sharedLibrary
        case let .managedCopy(app), let .symlink(app), let .independentCopy(app):
            L10n.Workbench.Skills.Copies.appFolder(app: app.displayName)
        case let .builtIn(app): L10n.Workbench.Skills.Copies.builtIn(app: app.displayName)
        case let .backup(createdAt):
            L10n.Workbench.Skills.Copies.backupTitle(
                date: AppLocale.string(createdAt, dateStyle: .medium, timeStyle: .short)
            )
        }
    }

    private var kindChip: some View {
        let label: String = switch version.kind {
        case .shared: L10n.Workbench.Skills.Copies.Kind.source
        case .managedCopy: L10n.Workbench.Skills.Copies.Kind.managedCopy
        case .symlink: L10n.Workbench.Skills.Copies.Kind.symlink
        case .independentCopy: L10n.Workbench.Skills.Copies.Kind.independentCopy
        case .builtIn: L10n.Workbench.Skills.Copies.Kind.builtIn
        case .backup: L10n.Workbench.Skills.Copies.Kind.backup
        }
        return Text(label)
            .font(.system(size: max(9, density.resetCountdownFontSize - 2), weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var status: some View {
        if version.isRecordedBaseline {
            Label(L10n.Workbench.Skills.Copies.recordedBaseline, systemImage: "checkmark.seal")
                .font(smallFont)
                .foregroundStyle(.secondary)
        }
        if let state = version.linkState {
            switch state {
            case .shared:
                detail(L10n.Workbench.Skills.Copies.linkToShared, style: .secondary)
            case .inside:
                detail(L10n.Workbench.Skills.Copies.linkTarget(path: version.linkTarget ?? ""), style: .secondary)
            case .outside:
                detail(L10n.Workbench.Skills.Copies.linkTarget(path: version.linkTarget ?? ""), style: .secondary)
                Label(L10n.Workbench.Skills.Copies.linkOutside, systemImage: "exclamationmark.triangle.fill")
                    .font(smallFont)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .broken:
                detail(L10n.Workbench.Skills.Copies.linkTarget(path: version.linkTarget ?? ""), style: .secondary)
                Label(L10n.Workbench.Skills.Copies.linkBroken, systemImage: "exclamationmark.triangle.fill")
                    .font(smallFont)
                    .foregroundStyle(.orange)
            }
        }
        if version.linkState != .shared {
            switch version.comparison {
            case .source: EmptyView()
            case .identical: detail(L10n.Workbench.Skills.Copies.identical, style: .secondary)
            case .differs: detail(L10n.Workbench.Skills.Copies.differs, style: .orange)
            case .unknown:
                if version.isReadable {
                    detail(L10n.Workbench.Skills.Copies.notCompared, style: .tertiary)
                }
            }
        }
        if let copy = version.copy, copy.shadowsShared, let app = copy.location.app {
            Label(L10n.Workbench.Skills.Copies.shadowsShared(app: app.displayName), systemImage: "exclamationmark.triangle.fill")
                .font(smallFont)
                .foregroundStyle(copy.sameAsShared ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ text: String, style: some ShapeStyle) -> some View {
        Text(text)
            .font(smallFont)
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pathLine: some View {
        HStack(spacing: 4) {
            Text(version.url.path)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(version.url.path)
            Spacer(minLength: 2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(version.url.path, forType: .string)
                copiedPath = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    copiedPath = false
                }
            } label: {
                Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
            }
            .buttonStyle(.vibeBar)
            .foregroundStyle(.secondary)
            .help(copiedPath ? L10n.Common.copied : L10n.Workbench.Skills.Copies.copyPath)
            .accessibilityLabel(L10n.Workbench.Skills.Copies.copyPath)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([version.url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
            }
            .buttonStyle(.vibeBar)
            .foregroundStyle(.secondary)
            .help(L10n.Workbench.Skills.menuRevealInFinder)
            .accessibilityLabel(L10n.Workbench.Skills.menuRevealInFinder)
        }
    }

    /// Only a differing copy of the same name may become the shared copy —
    /// the service refuses a rename because native switches are name-keyed.
    private var replaceableCopy: SkillCopy? {
        guard !skill.isLinked, let copy = version.copy, version.kind != .shared,
              version.comparison == .differs, copy.name == skill.name
        else { return nil }
        return copy
    }
}

// MARK: - Comparison

private struct SkillComparisonPane: View {
    let density: Theme.Density
    @ObservedObject var detail: SkillCopiesDetailModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            content
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            versionPicker(L10n.Workbench.Skills.Copies.Diff.base, selection: detail.baseID, set: detail.setBase)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            versionPicker(L10n.Workbench.Skills.Copies.Diff.compared, selection: detail.comparedID, set: detail.setCompared)
            Spacer(minLength: 8)
            Picker(selection: $detail.layout) {
                Text(L10n.Workbench.Skills.Copies.Diff.unified).tag(SkillCopiesDetailModel.DiffLayout.unified)
                Text(L10n.Workbench.Skills.Copies.Diff.sideBySide).tag(SkillCopiesDetailModel.DiffLayout.sideBySide)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func versionPicker(_ label: String, selection: String?, set: @escaping (String?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: max(10, density.resetCountdownFontSize - 1), weight: .semibold))
                .foregroundStyle(.secondary)
            Picker(selection: Binding(get: { selection }, set: set)) {
                ForEach(detail.versions.filter(\.isReadable)) { version in
                    Text(Self.pickerTitle(version)).tag(Optional(version.id))
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .frame(maxWidth: 230)
        }
    }

    private static func pickerTitle(_ version: SkillVersion) -> String {
        switch version.kind {
        case .shared: L10n.Workbench.Status.sharedLibrary
        case let .managedCopy(app), let .symlink(app), let .independentCopy(app):
            L10n.Workbench.Skills.Copies.appFolder(app: app.displayName)
        case let .builtIn(app): L10n.Workbench.Skills.Copies.builtIn(app: app.displayName)
        case let .backup(createdAt):
            version.isRecordedBaseline
                ? L10n.Workbench.Skills.Copies.recordedBaseline
                : L10n.Workbench.Skills.Copies.backupTitle(
                    date: AppLocale.string(createdAt, dateStyle: .medium, timeStyle: .short)
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        if detail.comparisonFailed {
            message(L10n.Workbench.Skills.Copies.Diff.unreadableVersion, systemImage: "exclamationmark.triangle")
        } else if let comparison = detail.comparison {
            VStack(alignment: .leading, spacing: 0) {
                summary(comparison)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    fileList(comparison)
                        .frame(width: 230)
                    Divider()
                    SkillFileDiffView(density: density, detail: detail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if detail.isComparing {
            message(L10n.Workbench.Skills.Copies.Diff.loading, systemImage: nil)
        } else {
            message(L10n.Workbench.Skills.Copies.Diff.pickVersion, systemImage: "arrow.left.arrow.right")
        }
    }

    private func summary(_ comparison: SkillTreeComparison) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.Workbench.Skills.Copies.Diff.summary(
                added: comparison.count(.added),
                removed: comparison.count(.removed),
                modified: comparison.count(.modified),
                unchanged: comparison.count(.unchanged)
            ))
            .font(.system(size: max(10, density.resetCountdownFontSize - 1)).monospacedDigit())
            .foregroundStyle(.secondary)
            if comparison.truncated {
                Text(L10n.Workbench.Skills.Copies.Diff.truncated(count: SkillDiffLimits.standard.maxFiles))
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func fileList(_ comparison: SkillTreeComparison) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(comparison.files) { file in
                    fileRow(file)
                }
            }
            .padding(6)
        }
    }

    private func fileRow(_ file: SkillFileComparison) -> some View {
        let selected = file.path == detail.selectedPath
        return Button {
            detail.select(path: file.path)
        } label: {
            HStack(spacing: 6) {
                Text(Self.marker(file.change))
                    .font(.system(size: max(10, density.resetCountdownFontSize), weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.tint(file.change))
                    .frame(width: 12)
                Text(file.path)
                    .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .monospaced))
                    .foregroundStyle(file.change == .unchanged ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? WorkbenchPorcelain.selectedNavigationFill(for: colorScheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.changeHelp(file.change))
    }

    static func marker(_ change: SkillFileChange) -> String {
        switch change {
        case .added: "+"
        case .removed: "−"
        case .modified: "~"
        case .unchanged: "="
        }
    }

    static func tint(_ change: SkillFileChange) -> Color {
        switch change {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        case .unchanged: .secondary
        }
    }

    private static func changeHelp(_ change: SkillFileChange) -> String {
        switch change {
        case .added: L10n.Workbench.Skills.Copies.Diff.Change.added
        case .removed: L10n.Workbench.Skills.Copies.Diff.Change.removed
        case .modified: L10n.Workbench.Skills.Copies.Diff.Change.modified
        case .unchanged: L10n.Workbench.Skills.Copies.Diff.Change.unchanged
        }
    }

    private func message(_ text: String, systemImage: String?) -> some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - One file

private struct SkillFileDiffView: View {
    let density: Theme.Density
    @ObservedObject var detail: SkillCopiesDetailModel

    @Environment(\.colorScheme) private var colorScheme

    private var codeFont: Font {
        .system(size: max(10, density.resetCountdownFontSize), design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = detail.selectedPath {
                HStack(spacing: 8) {
                    Text(path)
                        .font(.system(size: max(10, density.resetCountdownFontSize), weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    if case let .text(lines)? = detail.fileDiff?.diff, !lines.isIdentical {
                        Text(L10n.Workbench.Skills.Copies.Diff.lineStats(added: lines.addedCount, removed: lines.removedCount))
                            .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if detail.isDiffing { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            body(for: detail.fileDiff)
        }
    }

    @ViewBuilder
    private func body(for display: SkillCopiesDetailModel.FileDiffDisplay?) -> some View {
        switch display?.diff {
        case nil:
            Spacer()
        case let .text(lines)?:
            if lines.isIdentical {
                note(L10n.Workbench.Skills.Copies.Diff.noDifferences, systemImage: "checkmark.circle")
            } else if detail.layout == .unified {
                unified(lines)
            } else {
                sideBySide(lines, rows: display?.sideBySide ?? [])
            }
        case let .binary(left, right)?:
            facts(L10n.Workbench.Skills.Copies.Diff.binary, left: left, right: right)
        case let .tooLarge(left, right)?:
            facts(L10n.Workbench.Skills.Copies.Diff.tooLarge, left: left, right: right)
        case let .symlink(left, right)?:
            VStack(alignment: .leading, spacing: 8) {
                sideLine(L10n.Workbench.Skills.Copies.Diff.base, value: Self.sideText(left))
                sideLine(L10n.Workbench.Skills.Copies.Diff.compared, value: Self.sideText(right))
                Spacer()
            }
            .padding(14)
        case .unreadable?:
            note(L10n.Workbench.Skills.Copies.Diff.unreadable, systemImage: "exclamationmark.triangle")
        }
    }

    private func unified(_ lines: SkillLineDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.hunks) { hunk in
                    hunkHeader(hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 0) {
                            gutter(line.oldNumber)
                            gutter(line.newNumber)
                            Text(Self.prefix(line.kind) + line.text)
                                .font(codeFont)
                                .foregroundStyle(Self.textColor(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 6)
                        }
                        .background(Self.fill(line.kind))
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, 8)
        }
    }

    private func sideBySide(_ lines: SkillLineDiff, rows: [[SkillLineDiff.Row]]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(zip(lines.hunks, rows)), id: \.0.id) { hunk, hunkRows in
                    hunkHeader(hunk)
                    ForEach(Array(hunkRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 0) {
                            cell(row.left, number: row.left?.oldNumber)
                            Rectangle()
                                .fill(WorkbenchPorcelain.hairline(for: colorScheme))
                                .frame(width: 1)
                            cell(row.right, number: row.right?.newNumber)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, 8)
        }
    }

    private func cell(_ line: SkillLineDiff.Line?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(number)
            Text(line?.text ?? "")
                .font(codeFont)
                .foregroundStyle(line.map { Self.textColor($0.kind) } ?? .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line.map { Self.fill($0.kind) } ?? Color.primary.opacity(0.025))
    }

    private func hunkHeader(_ hunk: SkillLineDiff.Hunk) -> some View {
        Text(hunk.header)
            .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .monospaced))
            .foregroundStyle(WorkbenchPorcelain.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(WorkbenchPorcelain.accent.opacity(0.07))
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map { String($0) } ?? "")
            .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func facts(_ title: String, left: SkillFileFacts?, right: SkillFileFacts?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "doc")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            sideLine(L10n.Workbench.Skills.Copies.Diff.base, value: left.map(Self.factsText))
            sideLine(L10n.Workbench.Skills.Copies.Diff.compared, value: right.map(Self.factsText))
            Spacer()
        }
        .padding(14)
    }

    private func sideLine(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value ?? L10n.Workbench.Skills.Copies.Diff.absent)
                .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func sideText(_ side: SkillDiffSide) -> String? {
        switch side {
        case .absent: nil
        case let .symlink(target): L10n.Workbench.Skills.Copies.Diff.symlinkTarget(target: target)
        case let .file(facts): factsText(facts)
        }
    }

    private static func factsText(_ facts: SkillFileFacts) -> String {
        L10n.Workbench.Skills.Copies.Diff.fileFacts(
            size: Int64(clamping: facts.size).formatted(.byteCount(style: .file).locale(AppLocale.current)),
            hash: facts.sha256
        )
    }

    private func note(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func prefix(_ kind: SkillLineDiff.Line.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "− "
        case .context: "  "
        }
    }

    /// The tinted row carries the change; the text itself stays primary so
    /// it reads in both appearances. Context lines step back a little.
    private static func textColor(_ kind: SkillLineDiff.Line.Kind) -> Color {
        switch kind {
        case .added, .removed: .primary
        case .context: .primary.opacity(0.78)
        }
    }

    private static func fill(_ kind: SkillLineDiff.Line.Kind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        case .context: .clear
        }
    }
}
