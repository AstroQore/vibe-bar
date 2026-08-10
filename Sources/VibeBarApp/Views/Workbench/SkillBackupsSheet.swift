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
            pendingDeletion.map { "Delete the backup of \($0.skill?.name ?? $0.directoryName)?" }
                ?? "Delete this backup?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let backup = pendingDeletion { model.deleteBackup(backup) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The snapshot is removed from ~/.vibebar and cannot be restored afterwards.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Skill Backups")
                    .font(.system(size: density.titleFontSize, weight: .semibold))
                Text("Taken automatically before an uninstall or an update.")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            SectionRefreshButton(isRefreshing: false) { model.reloadBackups() }
                .help("Re-read the backup directory")
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
                Text("No backups yet")
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
            Button("Restore") { model.restoreBackup(backup) }
                .buttonStyle(.bordered)
                .disabled(busy)
                .help("Copy the snapshot back into ~/.agents/skills")
            Button {
                pendingDeletion = backup
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Delete this backup")
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Restoring recreates the shared directory only — enable the skill for the apps "
                + "you want it in afterwards.")
                .font(.system(size: max(9, density.resetCountdownFontSize)))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
