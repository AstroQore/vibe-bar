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

extension SkillVersion {
    /// "Changed 3 days ago" for the last week, "Changed Sep 2, 2026" beyond
    /// it — a relative phrase stops meaning much past a few days. Formatted
    /// on demand, so it follows a language change; a backup's title already
    /// carries its date, so it has none.
    var changedText: String? {
        if case .backup = kind { return nil }
        guard let modifiedAt else { return nil }
        let now = Date()
        let date = now.timeIntervalSince(modifiedAt) < 7 * 86_400
            ? AppLocale.relativeDateTimeFormatter(unitsStyle: .full)
                .localizedString(for: modifiedAt, relativeTo: now)
            : AppLocale.string(modifiedAt, template: "yMMMd")
        return L10n.Workbench.Skills.Copies.changed(date: date)
    }
}

extension SkillCopy {
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
