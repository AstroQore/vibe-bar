import SwiftUI
import UniformTypeIdentifiers
import VibeBarCore

/// The Workbench's Skills page.
///
/// Unlike Usage Stats, which is one scrolling column of cards, this page is a
/// fixed toolbar over a list that owns the remaining height: the installed set
/// is routinely a hundred rows on a machine that already uses skills, and a
/// list that scrolls inside its own frame keeps the search field and the
/// action buttons on screen while the user works through it.
struct SkillsManagerPage: View {
    let density: Theme.Density
    @ObservedObject var model: SkillsManagerModel

    @State private var showsZipImporter = false
    @State private var toastDismissal: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            toolbar
            skillList
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, density.popoverPaddingV)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { toastBanner }
        .task { model.activate() }
        .onChange(of: model.toast) { _, newValue in
            toastDismissal?.cancel()
            guard newValue != nil else { return }
            toastDismissal = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                model.toast = nil
            }
        }
        .fileImporter(
            isPresented: $showsZipImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                // Installed into the shared directory only. An archive can
                // hold several skills, and switching all of them on for every
                // agent CLI is not what picking a file asked for.
                model.installZip(url: url, apps: [])
            case let .failure(error):
                model.toast = error.localizedDescription
            }
        }
        .sheet(isPresented: $model.isDiscoverSheetPresented, onDismiss: model.discoverSheetDismissed) {
            SkillDiscoverSheet(density: density, model: model)
        }
        .sheet(isPresented: $model.isImportSheetPresented) {
            SkillImportSheet(density: density, model: model)
        }
        .sheet(isPresented: $model.isBackupsSheetPresented) {
            SkillBackupsSheet(density: density, model: model)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            HStack(spacing: 8) {
                searchField
                Spacer(minLength: 8)
                actionButtons
            }
            Divider().opacity(0.35)
            appCountRow
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Filter installed skills", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: density.segmentedFontSize))
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: 320)
        .background(Capsule().fill(.background.tertiary.opacity(0.7)))
        .overlay(Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5))
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button {
                model.checkForUpdates()
            } label: {
                buttonLabel(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: model.updatesAvailableCount > 0
                        ? "Updates (\(model.updatesAvailableCount))"
                        : "Check Updates",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.updates)
                )
            }
            .buttonStyle(.glass)
            .help("Compare every repository-backed skill against its source")

            Button {
                showsZipImporter = true
            } label: {
                buttonLabel(
                    systemImage: "doc.zipper",
                    title: "Install from ZIP",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.zip)
                )
            }
            .buttonStyle(.glass)
            .help("Install every skill inside a local .zip archive")

            Button {
                model.presentImportSheet()
            } label: {
                buttonLabel(
                    systemImage: "square.and.arrow.down.on.square",
                    title: "Import Existing",
                    busy: model.isBusy(SkillsManagerModel.BusyKey.importing)
                )
            }
            .buttonStyle(.glass)
            .help("Recognize skills already on this Mac without moving them")

            Button {
                model.presentBackupsSheet()
            } label: {
                buttonLabel(systemImage: "clock.arrow.circlepath", title: "Backups", busy: false)
            }
            .buttonStyle(.glass)
            .help("Restore a skill from a pre-uninstall snapshot")

            Button {
                model.isDiscoverSheetPresented = true
            } label: {
                buttonLabel(systemImage: "sparkle.magnifyingglass", title: "Discover", busy: false)
            }
            .buttonStyle(.glassProminent)
            .help("Browse configured repositories and the skills.sh index")
        }
    }

    private func buttonLabel(systemImage: String, title: String, busy: Bool) -> some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
            }
            Text(title)
                .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                .lineLimit(1)
        }
        .frame(minHeight: 22)
    }

    /// How many skills each agent CLI currently sees. The single number that
    /// answers "did that toggle actually land", and the reason the row sits
    /// above the list rather than inside a menu.
    private var appCountRow: some View {
        HStack(spacing: 6) {
            ForEach(SkillAppTarget.allCases, id: \.self) { app in
                let count = model.installedCount(for: app)
                HStack(spacing: 4) {
                    SkillAppGlyph(app: app, size: density.segmentedFontSize)
                    Text("\(count)")
                        .font(.system(size: density.segmentedFontSize - 1, weight: .semibold,
                                      design: .rounded).monospacedDigit())
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(Capsule().fill(app.accent.opacity(count == 0 ? 0.05 : 0.14)))
                .overlay(Capsule().stroke(app.accent.opacity(count == 0 ? 0.16 : 0.45), lineWidth: 0.8))
                .opacity(count == 0 ? 0.5 : 1)
                .saturation(count == 0 ? 0.2 : 1)
                .help("\(app.displayName): \(count) skill\(count == 1 ? "" : "s")")
                .accessibilityLabel("\(app.displayName), \(count) skills")
            }
            Spacer(minLength: 8)
            Text(countSummary)
                .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                    .monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var countSummary: String {
        let total = model.skills.count
        let shown = model.filteredSkills.count
        if shown == total { return "\(total) skill\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total) skills"
    }

    // MARK: - List

    @ViewBuilder
    private var skillList: some View {
        if model.skills.isEmpty {
            emptyCard
        } else if model.filteredSkills.isEmpty {
            CardShell(density: density, alignment: .center) {
                Text("No skill matches \"\(model.searchText)\"")
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.filteredSkills) { skill in
                SkillListRow(
                    density: density,
                    skill: skill,
                    updateState: model.updateState(for: skill),
                    isBusy: model.isBusy(skill: skill),
                    onToggle: { model.toggle(skill: skill, app: $0) },
                    onUpdate: { model.updateSkill(skill) },
                    onUninstall: { model.uninstall(skill) }
                )
                .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .cardSurface(density: density)
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyCard: some View {
        CardShell(density: density, alignment: .center) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No skills recorded yet")
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Text("Vibe Bar keeps one copy of every skill in ~/.agents/skills and links it into "
                + "each agent CLI. Import what is already on this Mac, or install something new "
                + "from a repository.")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Import Existing") { model.presentImportSheet() }
                    .buttonStyle(.bordered)
                Button("Discover") { model.isDiscoverSheetPresented = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastBanner: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Text(toast)
                    .font(.system(size: density.subtitleFontSize))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.toast = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: density.subtitleFontSize - 2, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: density.cardCornerRadius, style: .continuous)
                    .stroke(.separator.opacity(0.5), lineWidth: 0.5)
            )
            .padding(.bottom, density.popoverPaddingV)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
