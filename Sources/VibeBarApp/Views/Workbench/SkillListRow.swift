import SwiftUI
import VibeBarCore

extension SkillAppTarget {
    /// The provider this agent CLI shares a brand mark with, when there is
    /// one. Five of the seven targets are also usage providers, so their rows
    /// wear the same glyph and accent they wear everywhere else in the app;
    /// Hermes and OpenCode have no provider entry and fall back to a symbol.
    var brandTool: ToolType? { ToolType(rawValue: rawValue) }

    var fallbackSystemImage: String {
        switch self {
        case .hermes: return "bolt.horizontal.circle"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .claude, .codex, .gemini, .grok, .antigravity: return "puzzlepiece.extension"
        }
    }

    var accent: Color {
        brandTool.map(Theme.providerAccent(for:)) ?? .accentColor
    }
}

/// One agent CLI's mark at a given size — brand icon where the app has one,
/// SF Symbol where it does not.
struct SkillAppGlyph: View {
    let app: SkillAppTarget
    var size: CGFloat = 13

    var body: some View {
        if let tool = app.brandTool {
            ToolBrandIconView(tool: tool, size: size)
        } else {
            Image(systemName: app.fallbackSystemImage)
                .font(.system(size: size * 0.92, weight: .semibold))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// The seven-app row: one circular brand button per agent CLI.
///
/// Used both as a live control (an installed skill's enable bits) and as a
/// selection (which apps a pending install should be enabled for) — the two
/// read identically on purpose, because they mean the same thing.
struct SkillAppToggleRow: View {
    let isOn: (SkillAppTarget) -> Bool
    let toggle: (SkillAppTarget) -> Void
    var diameter: CGFloat = 25
    var glyphSize: CGFloat = 13
    var spacing: CGFloat = 4
    var helpSuffix: String?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(SkillAppTarget.allCases, id: \.self) { app in
                button(for: app)
            }
        }
    }

    private func button(for app: SkillAppTarget) -> some View {
        let on = isOn(app)
        let accent = app.accent
        return Button {
            toggle(app)
        } label: {
            SkillAppGlyph(app: app, size: glyphSize)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(accent.opacity(on ? 0.18 : 0.05))
                )
                .overlay(
                    Circle().stroke(accent.opacity(on ? 0.6 : 0.16), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        // An off app has to stay readable — the user is picking from these —
        // but must not wear the accent, which is the only signal that says
        // "this skill is live here".
        .opacity(on ? 1 : 0.35)
        .saturation(on ? 1 : 0.15)
        .help(helpSuffix.map { "\(app.displayName) — \($0)" } ?? app.displayName)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// One installed skill: what it is, where it came from, and which agent CLIs
/// currently see it.
struct SkillListRow: View {
    let density: Theme.Density
    let skill: Skill
    let updateState: SkillUpdateState?
    let isBusy: Bool
    let onToggle: (SkillAppTarget) -> Void
    let onUpdate: () -> Void
    let onUninstall: () -> Void

    @State private var confirmingUninstall = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            details
            Spacer(minLength: 8)
            SkillAppToggleRow(
                isOn: { skill.isEnabled(for: $0) },
                toggle: onToggle,
                helpSuffix: nil
            )
            .disabled(isBusy)
            overflowMenu
        }
        .padding(.vertical, 5)
        .opacity(isBusy ? 0.55 : 1)
        .overlay(alignment: .trailing) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .confirmationDialog(
            "Uninstall \(skill.name)?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { onUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The skill is backed up first, and removed from every app that links to it.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                sourceBadge
                if updateState?.updateAvailable == true {
                    updateBadge
                }
            }
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceBadge: some View {
        Text(skill.id.repositorySlug ?? "local")
            .font(.system(size: max(8, density.resetCountdownFontSize - 1), design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .help(skill.repoBranch.map { "Branch \($0)" } ?? "Installed locally")
    }

    private var updateBadge: some View {
        Text("UPDATE")
            .font(.system(size: max(8, density.resetCountdownFontSize - 2), weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.45), lineWidth: 0.7))
    }

    private var overflowMenu: some View {
        Menu {
            Button("Update from repository", systemImage: "arrow.down.circle") { onUpdate() }
                .disabled(!skill.id.isRepositoryBacked)
            Divider()
            Button("Uninstall…", systemImage: "trash", role: .destructive) {
                confirmingUninstall = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: density.subtitleFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityLabel("More actions for \(skill.name)")
    }
}
