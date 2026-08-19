import AppKit
import SwiftUI
import VibeBarCore

extension SkillAppTarget {
    /// The provider this agent CLI shares a brand mark with, when there is
    /// one. Every visible managed harness has a real provider asset, so the
    /// toggle row never falls back to an empty or unrelated glyph.
    var brandTool: ToolType? { ToolType(rawValue: rawValue) }

    var fallbackSystemImage: String {
        switch self {
        case .hermes: return "cross.case"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .claude, .codex, .gemini, .grok, .antigravity, .cursor:
            return "puzzlepiece.extension"
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
        } else if app == .hermes, let image = hermesImage {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: app.fallbackSystemImage)
                .font(.system(size: size * 0.92, weight: .semibold))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// Official Hermes mark from NousResearch's hermes-agent site:
    /// https://github.com/NousResearch/hermes-agent/blob/main/website/static/img/favicon.svg
    private var hermesImage: NSImage? {
        let filename = "ProviderIcon-hermes.svg"
        let bundled = Bundle.main.url(
            forResource: "ProviderIcon-hermes",
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        )
        let local = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ProviderIcons/\(filename)")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: local.path) ? local : nil),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

/// One circular brand button per locally manageable core harness.
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

    @State private var hoveredApp: SkillAppTarget?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
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
                    Circle().fill(accent.opacity(on ? 0.18 : hoveredApp == app ? 0.10 : 0.05))
                )
                .overlay(
                    Circle().stroke(accent.opacity(on ? 0.6 : hoveredApp == app ? 0.42 : 0.20), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        // An off app has to stay readable — the user is picking from these —
        // but must not wear the accent, which is the only signal that says
        // "this skill is live here".
        .opacity(on ? 1 : 0.62)
        .saturation(on ? 1 : 0.45)
        .onHover { hovering in hoveredApp = hovering ? app : nil }
        .help(helpSuffix.map { "\(app.displayName) — \($0)" } ?? app.displayName)
        .accessibilityLabel(app.displayName)
        .accessibilityValue(on ? "Enabled" : "Disabled")
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
    @State private var isHovering = false

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
        .padding(.horizontal, 4)
        .padding(.vertical, 11)
        .opacity(isBusy ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.045) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHovering ? Color.primary.opacity(0.12) : Color.clear,
                    lineWidth: 0.7
                )
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
                    .font(.system(size: max(12, density.bucketTitleFontSize), weight: .semibold))
                    .lineLimit(1)
                sourceBadge
                if updateState?.updateAvailable == true {
                    updateBadge
                }
            }
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: max(10, density.subtitleFontSize)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sourceBadge: some View {
        Text(skill.id.repositorySlug ?? "local")
            .font(.system(size: max(10, density.resetCountdownFontSize - 1), design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            .help(skill.repoBranch.map { "Branch \($0)" } ?? "Installed locally")
    }

    private var updateBadge: some View {
        Text("UPDATE")
            .font(.system(size: max(10, density.resetCountdownFontSize - 2), weight: .semibold))
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
                .font(.system(size: max(10, density.subtitleFontSize), weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityLabel("More actions for \(skill.name)")
    }
}
