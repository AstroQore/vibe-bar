import SwiftUI
import VibeBarCore

/// Snapshots taken before an uninstall or an update.
///
/// A repository-backed skill can always be fetched again; a locally authored
/// one exists here and nowhere else once its directory is gone. That is why
/// restore is one click and delete asks first.
struct SkillBackupsSheet: View {
    let density: Theme.Density
    @ObservedObject var model: SkillsManagerModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: SkillBackupManager.Backup?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .confirmationDialog(
            pendingDeletion.map {
                L10n.Workbench.skillsBackupsDeleteConfirmTitle(
                    skill: $0.skill?.name ?? $0.directoryName
                )
            } ?? L10n.Workbench.skillsBackupsDeleteConfirmTitleGeneric,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.Common.delete, role: .destructive) {
                if let backup = pendingDeletion { model.deleteBackup(backup) }
                pendingDeletion = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.Workbench.skillsBackupsDeleteConfirmMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Workbench.skillsBackupsTitle)
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Text(L10n.Workbench.skillsBackupsSubtitle)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SectionRefreshButton(isRefreshing: false) { model.reloadBackups() }
                .help(L10n.Workbench.skillsBackupsRefreshHelp)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.backups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text(L10n.Workbench.skillsBackupsEmpty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.backups) { backup in
                row(backup)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ backup: SkillBackupManager.Backup) -> some View {
        let busy = model.isBusy(SkillsManagerModel.BusyKey.backup(backup.directoryName))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.skill?.name ?? backup.directoryName)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: backup.createdAt))
                        .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                            .monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if let slug = backup.skill?.id.repositorySlug {
                        Text(slug)
                            .font(.system(size: max(9, density.resetCountdownFontSize),
                                          design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            }
            Button(L10n.Workbench.skillsBackupsRestore) { model.restoreBackup(backup) }
                .buttonStyle(.bordered)
                .disabled(busy)
                .help(L10n.Workbench.skillsBackupsRestoreHelp)
            Button {
                pendingDeletion = backup
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.vibeBar)
            .disabled(busy)
            .accessibilityLabel(L10n.Workbench.skillsBackupsDeleteAccessibility)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(L10n.Workbench.skillsBackupsFooter)
                .font(.system(size: max(9, density.resetCountdownFontSize)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.Common.done) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    // Built per language rather than once per process: a formatter
    // parked in a `static let` keeps the language it was created in.
    private static var dateFormatter: DateFormatter {
        AppLocale.dateFormatter(dateStyle: .medium, timeStyle: .short)
    }
}
