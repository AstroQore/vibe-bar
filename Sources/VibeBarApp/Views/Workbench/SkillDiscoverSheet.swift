import SwiftUI
import VibeBarCore

/// Where new skills come from: the repositories the user has configured, and
/// the skills.sh community index.
///
/// Both are in one sheet because they answer the same question and end in the
/// same action. They also share one staging directory underneath — installing
/// a skills.sh hit downloads that repository, which is why its skills replace
/// whatever the results list was showing and the header says which source is
/// on screen.
struct SkillDiscoverSheet: View {
    let density: Theme.Density
    @ObservedObject var model: SkillsManagerModel

    @Environment(\.dismiss) private var dismiss
    @State private var repoDraft = ""
    @State private var query = ""
    /// Apps a row installs into when it has not been touched. Empty by
    /// design: installing is about getting the skill onto the machine, and
    /// silently switching it on for every managed harness is not that.
    @State private var defaultApps: Set<SkillAppTarget> = []
    @State private var overrides: [String: Set<SkillAppTarget>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: density.interSectionSpacing) {
                    repositoriesSection
                    searchSection
                    resultsSection
                }
                .padding(.horizontal, density.popoverPaddingH)
                .padding(.vertical, density.popoverPaddingV)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 760, height: 640)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.Workbench.skillsDiscoverTitle)
                .font(.system(size: density.titleFontSize, weight: .semibold))
            Spacer(minLength: 8)
            Button(
                defaultApps.count == SkillAppTarget.managedHarnesses.count
                    ? L10n.Workbench.skillsDiscoverSelectNone
                    : L10n.Workbench.skillsDiscoverSelectAll
            ) {
                defaultApps = defaultApps.count == SkillAppTarget.managedHarnesses.count
                    ? []
                    : Set(SkillAppTarget.managedHarnesses)
                overrides.removeAll()
            }
            .buttonStyle(.bordered)
            .help(L10n.Workbench.skillsDiscoverSelectHelp)
            Button(L10n.Common.done) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, density.popoverPaddingH)
        .padding(.vertical, 12)
    }

    // MARK: - Configured repositories

    private var repositoriesSection: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            HStack(spacing: 8) {
                sectionTitle(L10n.Workbench.skillsDiscoverReposTitle)
                Spacer(minLength: 8)
                Button {
                    if model.isDiscovering {
                        model.cancelDiscover()
                    } else {
                        model.discover()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if model.isDiscovering {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: max(9, density.segmentedFontSize - 1), weight: .semibold))
                        }
                        // A download nobody can stop is the whole complaint
                        // this button answers.
                        Text(model.isDiscovering
                            ? L10n.Common.cancel
                            : L10n.Workbench.skillsDiscoverScanRepos)
                            .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
                    }
                    .frame(minHeight: 22)
                }
                .buttonStyle(.bordered)
                .disabled(model.repoList.isEmpty && !model.isDiscovering)
                .help(model.isDiscovering
                    ? L10n.Workbench.skillsDiscoverStopScanHelp
                    : L10n.Workbench.skillsDiscoverScanReposHelp)
            }

            if let phase = model.discoverPhase {
                Text(phase)
                    .font(.system(size: max(9, density.resetCountdownFontSize)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(model.discoverFailures, id: \.self) { failure in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: max(8, density.resetCountdownFontSize - 1)))
                    Text(failure)
                        .font(.system(size: max(9, density.resetCountdownFontSize)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
            }

            if model.repoList.isEmpty {
                Text(L10n.Workbench.skillsDiscoverNoRepos)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.repoList, id: \.self) { repo in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: density.subtitleFontSize))
                            .foregroundStyle(.tertiary)
                        Text(repo)
                            .font(.system(size: density.subtitleFontSize, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            model.removeRepo(repo)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.vibeBar)
                        .help(L10n.Workbench.skillsDiscoverStopScanningRepo(repo: repo))
                        .accessibilityLabel(L10n.Workbench.skillsDiscoverRemoveRepo(repo: repo))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(L10n.Workbench.skillsDiscoverRepoFieldPlaceholder, text: $repoDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: density.subtitleFontSize, design: .monospaced))
                    .onSubmit { addRepo() }
                Button(L10n.Workbench.skillsDiscoverAddRepo) { addRepo() }
                    .buttonStyle(.bordered)
                    .disabled(!isRepoDraftValid)
            }
            if !repoDraft.isEmpty, !isRepoDraftValid {
                Text(L10n.Workbench.skillsDiscoverRepoRules)
                    .font(.system(size: max(9, density.resetCountdownFontSize)))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var isRepoDraftValid: Bool {
        SkillRepoRef(repoDraft) != nil
    }

    private func addRepo() {
        guard isRepoDraftValid else { return }
        model.addRepo(repoDraft)
        repoDraft = ""
    }

    // MARK: - skills.sh

    private var searchSection: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            HStack(spacing: 8) {
                sectionTitle(L10n.Workbench.skillsDiscoverIndexTitle)
                Spacer(minLength: 8)
                if model.isBusy(SkillsManagerModel.BusyKey.search) {
                    ProgressView().controlSize(.small)
                }
            }
            TextField(L10n.Workbench.skillsDiscoverSearchPlaceholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: density.subtitleFontSize))
                .onChange(of: query) { _, newValue in
                    model.searchSkillsSh(query: newValue)
                }

            if model.searchResults.isEmpty {
                Text(L10n.Workbench.skillsDiscoverSearchHint)
                    .font(.system(size: max(9, density.resetCountdownFontSize)))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.searchResults) { result in
                    searchRow(result)
                    if result.id != model.searchResults.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func searchRow(_ result: SkillsShSearchResult) -> some View {
        let key = result.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.repo.descriptor)
                        .font(.system(size: max(9, density.resetCountdownFontSize), design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let installs = result.installs {
                        Text(L10n.Workbench.skillsDiscoverInstalls(count: installs))
                            .font(.system(size: max(9, density.resetCountdownFontSize), design: .rounded)
                                .monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            appSelector(key: key)
            installButton(busyKey: SkillsManagerModel.BusyKey.searchRow(key)) {
                model.installSearchResult(result, apps: Array(apps(for: key)).sorted { $0.rawValue < $1.rawValue })
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        CardShell(density: density, spacing: density.cardSpacing) {
            HStack(spacing: 8) {
                sectionTitle(L10n.Workbench.skillsDiscoverAvailableTitle)
                Spacer(minLength: 8)
                if let source = model.discoverSource {
                    Text(source)
                        .font(.system(size: max(9, density.resetCountdownFontSize)))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if model.discoverResults.isEmpty {
                Text(L10n.Workbench.skillsDiscoverAvailableEmpty)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedResults, id: \.repo) { group in
                    Text(group.repo)
                        .font(.system(size: max(9, density.resetCountdownFontSize), weight: .semibold,
                                      design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    ForEach(group.skills) { discovered in
                        discoveredRow(discovered)
                    }
                }
            }
        }
    }

    private var groupedResults: [(repo: String, skills: [DiscoveredSkill])] {
        Dictionary(grouping: model.discoverResults) {
            $0.repositorySlug ?? L10n.Workbench.skillsSourceLocal
        }
            .map { (repo: $0.key, skills: $0.value) }
            .sorted { $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending }
    }

    private func discoveredRow(_ discovered: DiscoveredSkill) -> some View {
        let key = discovered.id.rawValue
        let installed = model.skills.contains { $0.id == discovered.id }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(discovered.name)
                        .font(.system(size: density.bucketTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    if installed {
                        Text(L10n.Workbench.skillsBadgeInstalled)
                            .font(.system(size: max(8, density.resetCountdownFontSize - 2), weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary.opacity(0.5)))
                    }
                }
                if let description = discovered.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: density.subtitleFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            appSelector(key: key)
            installButton(busyKey: SkillsManagerModel.BusyKey.install(discovered.id)) {
                model.installDiscovered(
                    discovered,
                    apps: Array(apps(for: key)).sorted { $0.rawValue < $1.rawValue }
                )
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Shared row pieces

    private func appSelector(key: String) -> some View {
        SkillAppToggleRow(
            isOn: { apps(for: key).contains($0) },
            toggle: { toggleApp($0, for: key) },
            diameter: 22,
            glyphSize: 11,
            spacing: 3,
            helpOverride: { L10n.Workbench.skillsToggleHelpInstallInto(app: $0.displayName) }
        )
    }

    private func installButton(busyKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if model.isBusy(busyKey) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                }
                Text(L10n.Workbench.skillsInstall)
                    .font(.system(size: density.segmentedFontSize - 1, weight: .semibold))
            }
            .frame(minHeight: 22)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy(busyKey))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: max(8, density.segmentedFontSize - 3), weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
    }

    private func apps(for key: String) -> Set<SkillAppTarget> {
        overrides[key] ?? defaultApps
    }

    private func toggleApp(_ app: SkillAppTarget, for key: String) {
        var selection = apps(for: key)
        selection.formSymmetricDifference([app])
        overrides[key] = selection
    }
}
