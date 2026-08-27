import AppKit
import SwiftUI
import VibeBarCore

/// Per-skill answer to "what exactly did Vibe Bar do on my disk".
///
/// The toggle circles compress three mechanisms — shared-root discovery, the
/// per-app projection, and the harness's native switch — into one colored
/// state. This popover keeps the layers apart and names every path involved,
/// so the badge vocabulary (`shared root`, `OFF`, adopted copies) can be
/// checked against the filesystem instead of taken on faith.
struct SkillWiringPopover: View {
    let skill: Skill
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(skill.name)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        SkillAppCatalog.ssotDirectory()
                            .appendingPathComponent(skill.directory, isDirectory: true)
                    ])
                } label: {
                    Label("Reveal", systemImage: "folder")
                        .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
                }
                .buttonStyle(.vibeBar)
                .foregroundStyle(.secondary)
                .help("Show the skill's source directory in Finder")
            }

            wiringRow(
                title: "Source",
                lines: [line("One copy of the skill. Every harness below reads this directory or a link to it.")],
                path: skill.wiring(for: .codex).sourcePath
            )

            Divider().opacity(0.4)

            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                harnessRow(skill.wiring(for: app))
            }

            Divider().opacity(0.4)

            Text("Vibe Bar writes only inside the skills folders above and the four listed config files, and backs a skill up before uninstalling it.")
                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
    }

    private func harnessRow(_ wiring: SkillHarnessWiring) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SkillAppGlyph(app: wiring.app, size: 13)
                .frame(width: 20, height: 20)
                .background(Circle().fill(wiring.app.accent.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(wiring.app.displayName)
                        .font(.system(size: density.subtitleFontSize, weight: .semibold))
                    Spacer(minLength: 6)
                    stateLabel(wiring)
                }
                ForEach(mechanismLines(wiring), id: \.self) { text in
                    line(text)
                }
            }
        }
    }

    private func wiringRow(title: String, lines: [some View], path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: density.subtitleFontSize, weight: .semibold))
                Spacer(minLength: 6)
                Text(path)
                    .font(.system(size: max(9, density.resetCountdownFontSize - 1), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { $0.element }
        }
    }

    @ViewBuilder
    private func stateLabel(_ wiring: SkillHarnessWiring) -> some View {
        let (text, color): (String, Color) = switch wiring.state {
        case .enabled: ("On", .green)
        case .coupled: (wiring.viaGeminiCompatibility ? "On · via Gemini" : "On · shared root", .secondary)
        case .disabledInHarness: ("Off · native switch", .orange)
        case .notProjected: ("Off · not linked", .secondary)
        case .unknown: ("Config unreadable", .orange)
        }
        Text(text)
            .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
            .foregroundStyle(color)
    }

    /// The mechanism, one plain sentence per layer that exists.
    private func mechanismLines(_ wiring: SkillHarnessWiring) -> [String] {
        var lines: [String] = []
        if wiring.viaGeminiCompatibility {
            lines.append("Also reads the Gemini CLI skills folder, which holds this skill's Gemini projection.")
        } else if wiring.discoversSharedRoot {
            lines.append("Scans the shared root itself — no per-app link needed.")
        }
        if let projection = wiring.projection {
            let kind = projection.method == .symlink ? "Symlink" : "Copy"
            let origin = projection.adopted ? " · adopted from an existing install" : ""
            lines.append("\(kind) at \(wiring.projectionPath)\(origin)")
        } else if !wiring.discoversSharedRoot, !wiring.viaGeminiCompatibility {
            lines.append("No entry at \(wiring.projectionPath) — the harness cannot see this skill.")
        }
        if let path = wiring.nativeConfigPath, let key = wiring.nativeConfigKey {
            lines.append("Per-skill switch: \(key) in \(path)")
        } else {
            lines.append("No per-skill switch — whatever is discovered is active.")
        }
        return lines
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Page-level "how syncing works" — the model in four sentences plus the
/// per-harness table, so the badges and circles have a legend.
struct SkillSyncExplainerPopover: View {
    let density: Theme.Density

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How skill syncing works")
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))

            paragraph(
                "One source of truth.",
                "Every skill lives in ~/\(SkillAppCatalog.ssotRelativePath)/<name>. Install, update, and uninstall all happen there and only there."
            )
            paragraph(
                "Projections.",
                "Claude Code and AntiGravity read only their own skills folders, so Vibe Bar links (or copies) skills into them. Codex, Gemini CLI, Grok Build, and Cursor scan the shared root themselves — no link needed."
            )
            paragraph(
                "Native switches.",
                "Where a harness has its own per-skill off switch, the circles flip that switch. Cursor has none, so every skill in the shared root is always available to it — that is the \u{201C}shared root\u{201D} badge, and there is nothing to toggle."
            )

            Divider().opacity(0.4)

            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                harnessLine(app)
            }

            Divider().opacity(0.4)

            Text("Vibe Bar writes only inside ~/\(SkillAppCatalog.ssotRelativePath), the per-harness skills folders, and the config files above.")
                .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 420)
    }

    private func paragraph(_ lead: String, _ body: String) -> some View {
        (Text(lead).fontWeight(.semibold) + Text(" " + body))
            .font(.system(size: max(10, density.subtitleFontSize - 1)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func harnessLine(_ app: SkillAppTarget) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SkillAppGlyph(app: app, size: 12)
                .frame(width: 18, height: 18)
                .background(Circle().fill(app.accent.opacity(0.10)))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .font(.system(size: max(10, density.subtitleFontSize - 1), weight: .semibold))
                Text(harnessSummary(app))
                    .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func harnessSummary(_ app: SkillAppTarget) -> String {
        var parts: [String] = []
        parts.append(
            app.discoversSharedSkillRoot
                ? "scans ~/\(SkillAppCatalog.ssotRelativePath) directly"
                : "reads only ~/\(SkillAppCatalog.relativePath(for: app))"
        )
        if let key = app.nativeConfigKeyDescription, let path = app.nativeConfigRelativePath {
            parts.append("per-skill switch \(key) in ~/\(path)")
        } else if app == .antigravity {
            parts.append("no per-skill switch; also reads ~/\(SkillAppCatalog.relativePath(for: .gemini))")
        } else {
            parts.append("no per-skill switch")
        }
        return parts.joined(separator: " · ")
    }
}
