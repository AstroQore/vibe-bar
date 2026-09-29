import AppKit
import SwiftUI
import VibeBarCore

extension SkillCopy.Location {
    var label: String {
        switch self {
        case .shared: L10n.Workbench.Status.sharedLibrary
        case let .appFolder(app): L10n.Workbench.Skills.Copies.appFolder(app: app.displayName)
        case let .builtIn(app): L10n.Workbench.Skills.Copies.builtIn(app: app.displayName)
        }
    }
}

extension SkillCopy {
    /// "Changed 3 days ago" for the last week, "Changed Sep 2, 2026" beyond
    /// it — a relative phrase stops meaning much past a few days. Formatted
    /// on demand: only an open popover asks.
    var changedText: String? {
        guard let modifiedAt else { return nil }
        let now = Date()
        let date = now.timeIntervalSince(modifiedAt) < 7 * 86_400
            ? AppLocale.relativeDateTimeFormatter(unitsStyle: .full)
                .localizedString(for: modifiedAt, relativeTo: now)
            : AppLocale.string(modifiedAt, template: "yMMMd")
        return L10n.Workbench.Skills.Copies.changed(date: date)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Every copy of one installed skill, shared copy first.
///
/// Everything shown was computed by the service's reload — hashes, the
/// identical/differs verdict, the shadowing flag — so opening this does no
/// filesystem work beyond what a Reveal click asks Finder to do.
struct SkillCopiesPopover: View {
    let skill: Skill
    let density: Theme.Density
    let onReplace: (SkillCopy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Workbench.Skills.Copies.title(skill: skill.name))
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                .lineLimit(1)

            sharedRow

            Divider().opacity(0.4)

            ForEach(skill.otherCopies) { copy in
                copyRow(copy)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var sharedRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tray.full")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                header(
                    title: SkillCopy.Location.shared.label,
                    reveal: skill.sharedCopy?.url
                        ?? SkillAppCatalog.ssotDirectory()
                            .appendingPathComponent(skill.directory, isDirectory: true)
                )
                if let changed = skill.sharedCopy?.changedText {
                    detail(changed, style: .tertiary)
                }
            }
        }
    }

    private func copyRow(_ copy: SkillCopy) -> some View {
        let hasShared = skill.sharedCopy != nil
        return HStack(alignment: .top, spacing: 8) {
            glyph(for: copy.location)
            VStack(alignment: .leading, spacing: 2) {
                header(title: copy.location.label, reveal: copy.url)
                if !hasShared {
                    detail(L10n.Workbench.Skills.Copies.noShared, style: .secondary)
                } else if copy.sameAsShared {
                    detail(L10n.Workbench.Skills.Copies.identical, style: .secondary)
                } else {
                    detail(L10n.Workbench.Skills.Copies.differs, style: .orange)
                }
                if let changed = copy.changedText {
                    detail(changed, style: .tertiary)
                }
                if copy.shadowsShared, let app = copy.location.app {
                    // Orange only when it matters: an identical copy in the
                    // harness folder hides nothing the user would miss.
                    Label(
                        L10n.Workbench.Skills.Copies.shadowsShared(app: app.displayName),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(copy.sameAsShared ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                }
                // A differently named copy would re-point the name-keyed
                // native switches; the service refuses it, so never offer it.
                if hasShared, !copy.sameAsShared,
                   copy.name.lowercased() == skill.name.lowercased() {
                    Button(L10n.Workbench.Skills.Copies.replaceShared) {
                        onReplace(copy)
                    }
                    .buttonStyle(WorkbenchPillButtonStyle())
                    .padding(.top, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func glyph(for location: SkillCopy.Location) -> some View {
        if let app = location.app {
            SkillAppGlyph(app: app, size: 13)
                .frame(width: 20, height: 20)
                .background(Circle().fill(app.accent.opacity(0.10)))
        }
    }

    private func header(title: String, reveal url: URL) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
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

    private func detail(_ text: String, style: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: max(9, density.resetCountdownFontSize - 1)))
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A skill a harness ships in its own built-in folder, with no shared copy.
///
/// Read-only by construction: no harness toggles (the harness already loads
/// it, and its folder is not Vibe Bar's to change), only Reveal and a copy
/// into the shared library, after which it becomes an ordinary installed row
/// that lists this built-in under its copies.
struct SkillBuiltInRow: View {
    let density: Theme.Density
    let copy: SkillCopy
    let isBusy: Bool
    let onCopyToShared: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            details
            Spacer(minLength: 8)
            overflowMenu
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 11)
        .opacity(isBusy ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.045) : .clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 2)
        }
        .overlay(alignment: .trailing) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(copy.name)
                    .font(.system(size: max(12, density.bucketTitleFontSize), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let app = copy.location.app {
                    sourceBadge(app: app)
                }
            }
            if let description = copy.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: max(10, density.subtitleFontSize)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceBadge(app: SkillAppTarget) -> some View {
        HStack(spacing: 4) {
            SkillAppGlyph(app: app, size: max(9, density.resetCountdownFontSize - 1))
            Text(L10n.Workbench.Skills.sourceBuiltIn(app: app.displayName))
                .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(app.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(app.accent.opacity(0.22), lineWidth: 0.6)
        )
        .help(L10n.Workbench.Skills.sourceBuiltInHelp(app: app.displayName))
    }

    private var overflowMenu: some View {
        Menu {
            Button(L10n.Workbench.Skills.menuRevealInFinder, systemImage: "folder") {
                copy.revealInFinder()
            }
            Divider()
            Button(L10n.Workbench.Skills.Copies.copyToShared, systemImage: "square.and.arrow.down") {
                onCopyToShared()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityLabel(L10n.Workbench.Skills.menuMoreActions(skill: copy.name))
    }
}
