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
                    Label(L10n.Workbench.Skills.Wiring.reveal, systemImage: "folder")
                        .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
                }
                .buttonStyle(.vibeBar)
                .foregroundStyle(.secondary)
                .help(L10n.Workbench.Skills.Wiring.revealHelp)
            }

            wiringRow(
                title: L10n.Workbench.Skills.Wiring.source,
                lines: [line(L10n.Workbench.Skills.Wiring.sourceDetail)],
                path: skill.wiring(for: .codex).sourcePath
            )

            Divider().opacity(0.4)

            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                harnessRow(skill.wiring(for: app))
            }

            Divider().opacity(0.4)

            Text(L10n.Workbench.Skills.Wiring.footer)
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
        case .enabled: (L10n.Common.on, .green)
        case .coupled: (
            wiring.viaGeminiCompatibility
                ? L10n.Workbench.Skills.Wiring.stateCoupledGemini
                : L10n.Workbench.Skills.Wiring.stateCoupledSharedRoot,
            .secondary
        )
        case .disabledInHarness: (L10n.Workbench.Skills.Wiring.stateNativeOff, .orange)
        case .notProjected: (L10n.Workbench.Skills.Wiring.stateNotLinked, .secondary)
        case .unknown: (L10n.Workbench.Skills.Wiring.stateConfigUnreadable, .orange)
        }
        Text(text)
            .font(.system(size: max(9, density.resetCountdownFontSize - 1), weight: .semibold))
            .foregroundStyle(color)
    }

    /// The mechanism, one plain sentence per layer that exists.
    private func mechanismLines(_ wiring: SkillHarnessWiring) -> [String] {
        var lines: [String] = []
        if wiring.viaGeminiCompatibility {
            lines.append(L10n.Workbench.Skills.Wiring.mechanismGeminiCompat)
        } else if wiring.discoversSharedRoot {
            lines.append(L10n.Workbench.Skills.Wiring.mechanismSharedRoot)
        }
        if let projection = wiring.projection {
            // Four whole sentences rather than a kind word plus an optional
            // tail: the adopted clause is not a suffix a second language can
            // hang off an English frame.
            let path = wiring.projectionPath
            switch (projection.method, projection.adopted) {
            case (.symlink, false):
                lines.append(L10n.Workbench.Skills.Wiring.projectionSymlink(path: path))
            case (.symlink, true):
                lines.append(L10n.Workbench.Skills.Wiring.projectionSymlinkAdopted(path: path))
            case (_, false):
                lines.append(L10n.Workbench.Skills.Wiring.projectionCopy(path: path))
            case (_, true):
                lines.append(L10n.Workbench.Skills.Wiring.projectionCopyAdopted(path: path))
            }
        } else if !wiring.discoversSharedRoot, !wiring.viaGeminiCompatibility {
            lines.append(
                L10n.Workbench.Skills.Wiring.projectionMissing(path: wiring.projectionPath)
            )
        }
        if let path = wiring.nativeConfigPath, let key = wiring.nativeConfigKey {
            lines.append(L10n.Workbench.Skills.Wiring.nativeSwitch(key: key, path: path))
        } else {
            lines.append(L10n.Workbench.Skills.Wiring.noNativeSwitch)
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
            Text(L10n.Workbench.Skills.Sync.title)
                .font(.system(size: density.bucketTitleFontSize, weight: .semibold))

            paragraph(
                L10n.Workbench.Skills.Sync.ssotLead,
                L10n.Workbench.Skills.Sync.ssotBody(path: SkillAppCatalog.ssotRelativePath)
            )
            paragraph(
                L10n.Workbench.Skills.Sync.projectionsLead,
                L10n.Workbench.Skills.Sync.projectionsBody
            )
            paragraph(
                L10n.Workbench.Skills.Sync.nativeSwitchesLead,
                L10n.Workbench.Skills.Sync.nativeSwitchesBody
            )

            Divider().opacity(0.4)

            ForEach(SkillAppTarget.managedHarnesses, id: \.self) { app in
                harnessLine(app)
            }

            Divider().opacity(0.4)

            Text(L10n.Workbench.Skills.Sync.footer(path: SkillAppCatalog.ssotRelativePath))
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
                ? L10n.Workbench.Skills.Sync.scansSharedRoot(
                    path: SkillAppCatalog.ssotRelativePath
                )
                : L10n.Workbench.Skills.Sync.readsOwnFolder(
                    path: SkillAppCatalog.relativePath(for: app)
                )
        )
        if let key = app.nativeConfigKeyDescription, let path = app.nativeConfigRelativePath {
            parts.append(L10n.Workbench.Skills.Sync.perSkillSwitch(key: key, path: path))
        } else if app == .antigravity {
            parts.append(
                L10n.Workbench.Skills.Sync.noSwitchAlsoReads(
                    path: SkillAppCatalog.relativePath(for: .gemini)
                )
            )
        } else {
            parts.append(L10n.Workbench.Skills.Sync.noPerSkillSwitch)
        }
        return parts.joined(separator: " · ")
    }
}
