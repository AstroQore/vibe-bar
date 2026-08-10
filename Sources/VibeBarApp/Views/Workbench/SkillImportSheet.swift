import SwiftUI
import VibeBarCore

/// What an import scan found, and what Vibe Bar would do about it.
///
/// The scan itself changed nothing — it only read directories and symlinks —
/// so this sheet is where the user turns a description of the machine into
/// records. Adopting the SSOT skills is one button because it writes no files
/// at all; adopting a foreign app-side directory is per row, because that one
/// copies real content into `~/.agents/skills` and replaces the original with
/// a link.
struct SkillImportSheet: View {
    let density: Theme.Density
    @ObservedObject var model: SkillsManagerModel

    @Environment(\.dismiss) private var dismiss
    @State private var adoptedApps: Set<SkillAppTarget> = []
    @State private var adopting: [String: Set<SkillAppTarget>] = [:]
    @State private var showsExistingSkills = false

    private var report: SkillImportReport? { model.importReport }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                        if !report.adopted.isEmpty { adoptedSection(report) }
                        if !report.unmanagedDirectories.isEmpty { unmanagedSection(report) }
                        if !report.unrecognized.isEmpty { unrecognizedSection(report) }
                        if !report.conflicts.isEmpty { conflictsSection(report) }
                    }
                    .padding(.horizontal, density.popoverPaddingH)
                    .padding(.vertical, density.popoverPaddingV)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                footer(report)
            } else {
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(width: 760, height: 640)
        .onAppear { seedSelection() }
        .onChange(of: report) { _, _ in seedSelection() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review On-Disk Skills")
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Text("Vibe Bar already recognizes shared skills. Only selected app-local folders will move.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    private func footer(_ report: SkillImportReport) -> some View {
        HStack(spacing: 10) {
            Text(summary(report))
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Cancel") {
                model.isImportSheetPresented = false
                dismiss()
            }
            .buttonStyle(.glass)
            Button {
                model.runImport(
                    apps: Array(adoptedApps).sorted { $0.rawValue < $1.rawValue },
                    adopting: adopting.mapValues { Array($0).sorted { $0.rawValue < $1.rawValue } }
                )
            } label: {
                HStack(spacing: 5) {
                    if model.isBusy(SkillsManagerModel.BusyKey.importing) {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                    }
                    Text("Apply \(report.adopted.count + adopting.count) change"
                        + (report.adopted.count + adopting.count == 1 ? "" : "s"))
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(report.adopted.isEmpty && adopting.isEmpty)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    private func summary(_ report: SkillImportReport) -> String {
        "\(report.adopted.count) already shared · \(report.unmanagedDirectories.count) need adoption "
            + "· \(report.conflicts.count) left unchanged"
    }

    // MARK: - Adopted

    private func adoptedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            DisclosureGroup(isExpanded: $showsExistingSkills) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Keep evidence for")
                            .font(.system(size: max(9, density.resetCountdownFontSize)))
                            .foregroundStyle(.tertiary)
                        SkillAppToggleRow(
                            isOn: { adoptedApps.contains($0) },
                            toggle: { adoptedApps.formSymmetricDifference([$0]) },
                            diameter: 22,
                            glyphSize: 11,
                            spacing: 3,
                            helpSuffix: "keep the links already on disk"
                        )
                    }
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(report.adopted) { skill in
                            HStack(spacing: 8) {
                                Text(skill.name)
                                    .font(.system(size: density.subtitleFontSize))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                HStack(spacing: 3) {
                                    ForEach(skill.enabledApps, id: \.self) { app in
                                        SkillAppGlyph(app: app, size: 11)
                                            .help(app.displayName)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                sectionHeader(
                    "Already shared",
                    detail: "\(report.adopted.count) recognized"
                )
            }
            Text("These already live in ~/.agents/skills, including layouts created by CC Switch. "
                + "Vibe Bar records their existing links; it does not import or copy them again.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Unmanaged

    private func unmanagedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader(
                "Needs adoption",
                detail: "\(report.unmanagedDirectories.count)"
            )
            Text("These do not exist in the shared directory yet. Selecting one copies it into "
                + "~/.agents/skills, then replaces the chosen app copies with managed links.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            ForEach(report.unmanagedDirectories, id: \.directoryName) { entry in
                unmanagedRow(entry)
            }
        }
    }

    private func unmanagedRow(_ entry: UnmanagedSkillDirectory) -> some View {
        let opted = adopting[entry.directoryName] != nil
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { opted },
                set: { isOn in
                    adopting[entry.directoryName] = isOn ? Set(entry.foundIn) : nil
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name ?? entry.directoryName)
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    Text("found in " + entry.foundIn.map(\.displayName).joined(separator: ", "))
                        .font(.system(size: max(9, density.resetCountdownFontSize)))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            SkillAppToggleRow(
                isOn: { adopting[entry.directoryName]?.contains($0) ?? false },
                toggle: { app in
                    var selection = adopting[entry.directoryName] ?? []
                    selection.formSymmetricDifference([app])
                    adopting[entry.directoryName] = selection.isEmpty ? nil : selection
                },
                diameter: 22,
                glyphSize: 11,
                spacing: 3,
                helpSuffix: "link into after adopting"
            )
        }
        .padding(.vertical, 2)
    }

    // MARK: - Read-only findings

    private func unrecognizedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader("Not skills", detail: "\(report.unrecognized.count)")
            Text("Directories in ~/.agents/skills with no SKILL.md. Left exactly as they are.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            Text(report.unrecognized.joined(separator: ", "))
                .font(.system(size: max(9, density.resetCountdownFontSize), design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func conflictsSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader("Conflicting app copies", detail: "\(report.conflicts.count) unchanged")
            Text("A real folder in an app's skills directory has the same name as one in "
                + "~/.agents/skills. Vibe Bar will not overwrite it — resolve it by hand, or "
                + "enable the shared skill for that app once the folder is gone.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            ForEach(report.conflicts, id: \.self) { conflict in
                HStack(spacing: 8) {
                    SkillAppGlyph(app: conflict.app, size: 11)
                    Text(conflict.directoryName)
                        .font(.system(size: max(9, density.resetCountdownFontSize), design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(conflict.app.displayName)
                        .font(.system(size: max(9, density.resetCountdownFontSize)))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    /// Pre-checks exactly the apps the scan found evidence for: the default
    /// import records the machine as it is, and unchecking an app is how the
    /// user says "stop treating that link as mine".
    private func seedSelection() {
        guard let report else { return }
        adoptedApps = Set(report.adopted.flatMap(\.enabledApps))
        adopting = [:]
    }
}
