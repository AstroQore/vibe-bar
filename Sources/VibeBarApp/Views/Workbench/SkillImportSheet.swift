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
                Text(L10n.Workbench.Skills.Import.title)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Text(L10n.Workbench.Skills.Import.subtitle)
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
            Button(L10n.Common.cancel) {
                model.isImportSheetPresented = false
                dismiss()
            }
            .buttonStyle(.bordered)
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
                    Text(L10n.Workbench.Skills.Import.apply(
                        count: report.adopted.count + adopting.count
                    ))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(report.adopted.isEmpty && adopting.isEmpty)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    private func summary(_ report: SkillImportReport) -> String {
        L10n.Workbench.Skills.Import.summary(
            adopted: report.adopted.count,
            unmanaged: report.unmanagedDirectories.count,
            conflicts: report.conflicts.count
        )
    }

    // MARK: - Adopted

    private func adoptedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            DisclosureGroup(isExpanded: $showsExistingSkills) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.Workbench.Skills.Import.keepEvidenceFor)
                            .font(.system(size: max(10, density.resetCountdownFontSize)))
                            .foregroundStyle(.tertiary)
                        SkillAppToggleRow(
                            isOn: { adoptedApps.contains($0) },
                            toggle: { adoptedApps.formSymmetricDifference([$0]) },
                            diameter: 22,
                            glyphSize: 11,
                            spacing: 3,
                            helpOverride: {
                                L10n.Workbench.Skills.ToggleHelp.keepLinks(app: $0.displayName)
                            }
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
                                    ForEach(skill.projectedApps, id: \.self) { app in
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
                    L10n.Workbench.Skills.Import.alreadyShared,
                    detail: L10n.Workbench.Skills.Import.recognizedCount(
                        count: report.adopted.count
                    )
                )
            }
            Text(L10n.Workbench.Skills.Import.alreadySharedDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Unmanaged

    private func unmanagedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader(
                L10n.Workbench.Skills.Import.needsAdoption,
                detail: AppLocale.number(report.unmanagedDirectories.count)
            )
            Text(L10n.Workbench.Skills.Import.needsAdoptionDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            unmanagedBulkControls(report)
            ForEach(report.unmanagedDirectories, id: \.directoryName) { entry in
                unmanagedRow(entry)
            }
        }
    }

    private func unmanagedBulkControls(_ report: SkillImportReport) -> some View {
        let entries = report.unmanagedDirectories
        let firstChecked = entries.first { adopting[$0.directoryName] != nil }
        return HStack(spacing: 6) {
            smallButton(L10n.Workbench.Skills.Import.selectAllRows) {
                // Rows already checked keep whatever the user picked for
                // them; only the unchecked ones take the default set.
                for entry in entries where adopting[entry.directoryName] == nil {
                    adopting[entry.directoryName] = initialSelection(for: entry)
                }
            }
            .disabled(adopting.count == entries.count)
            smallButton(L10n.Workbench.Skills.Import.selectNoRows) {
                adopting = [:]
            }
            .disabled(adopting.isEmpty)
            Spacer(minLength: 8)
            smallButton(L10n.Workbench.Skills.Import.applyToAllRows) {
                guard let firstChecked,
                      let selection = adopting[firstChecked.directoryName]
                else { return }
                for entry in entries where adopting[entry.directoryName] != nil {
                    adopting[entry.directoryName] = SkillAdoptionSelection.copy(
                        selection, onto: entry.foundIn
                    )
                }
            }
            .disabled(adopting.count < 2)
        }
    }

    /// Same look as the discovery sheet's in-card actions: bordered, one
    /// step below the section text.
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .frame(minHeight: 22)
        }
        .buttonStyle(.bordered)
    }

    /// What a row starts with when its checkbox is turned on: the user's
    /// default harnesses plus the apps the scan found the directory in —
    /// adopting a folder always keeps it where it was.
    private func initialSelection(for entry: UnmanagedSkillDirectory) -> Set<SkillAppTarget> {
        SkillAdoptionSelection.seed(foundIn: entry.foundIn, defaults: model.defaultApps)
    }

    private func unmanagedRow(_ entry: UnmanagedSkillDirectory) -> some View {
        let opted = adopting[entry.directoryName] != nil
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { opted },
                set: { isOn in
                    adopting[entry.directoryName] = isOn ? initialSelection(for: entry) : nil
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name ?? entry.directoryName)
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    Text(L10n.Workbench.Skills.Import.foundIn(
                        apps: entry.foundIn.map(\.displayName).joined(separator: ", ")
                    ))
                        .font(.system(size: max(10, density.resetCountdownFontSize)))
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
                helpOverride: {
                    L10n.Workbench.Skills.ToggleHelp.linkAfterAdopting(app: $0.displayName)
                }
            )
        }
        .padding(.vertical, 2)
    }

    // MARK: - Read-only findings

    private func unrecognizedSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader(
                L10n.Workbench.Skills.Import.notSkills,
                detail: AppLocale.number(report.unrecognized.count)
            )
            Text(L10n.Workbench.Skills.Import.notSkillsDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            Text(report.unrecognized.joined(separator: ", "))
                .font(.system(size: max(10, density.resetCountdownFontSize), design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func conflictsSection(_ report: SkillImportReport) -> some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            sectionHeader(
                L10n.Workbench.Skills.Import.conflicts,
                detail: L10n.Workbench.Skills.Import.conflictsCount(count: report.conflicts.count)
            )
            Text(L10n.Workbench.Skills.Import.conflictsDetail)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
            ForEach(report.conflicts, id: \.self) { conflict in
                HStack(spacing: 8) {
                    SkillAppGlyph(app: conflict.app, size: 11)
                    Text(conflict.directoryName)
                        .font(.system(size: max(10, density.resetCountdownFontSize), design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(conflict.app.displayName)
                        .font(.system(size: max(10, density.resetCountdownFontSize)))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: max(10, density.segmentedFontSize - 3), weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: max(10, density.resetCountdownFontSize), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    /// Pre-checks exactly the apps the scan found evidence for: the default
    /// import records the machine as it is, and unchecking an app is how the
    /// user says "stop treating that link as mine".
    private func seedSelection() {
        guard let report else { return }
        adoptedApps = Set(report.adopted.flatMap(\.projectedApps))
        adopting = [:]
    }
}
