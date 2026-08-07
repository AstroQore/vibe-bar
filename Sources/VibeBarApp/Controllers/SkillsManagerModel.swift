import Combine
import Foundation
import VibeBarCore

/// State behind the Workbench's Skills page.
///
/// `SkillsService` is an actor and every method here reaches it through
/// `await`, so no filesystem walk, no zip extraction, and no repository
/// download ever runs on the main thread — only the finished value is assigned
/// back to a `@Published` property.
///
/// Every mutating action goes through `perform(_:_:)`, which owns the three
/// things each of them needs identically: a busy key so a second tap on the
/// same row is a no-op, a reload of the registry afterwards so the list
/// describes the disk again, and one error surface (`toast`) rather than a
/// per-action alert.
@MainActor
final class SkillsManagerModel: ObservableObject {
    /// Keys into `busy`. Strings rather than an enum because the set mixes
    /// page-wide operations with per-skill and per-row ones.
    enum BusyKey {
        static let updates = "updates"
        static let discover = "discover"
        static let search = "search"
        static let importing = "import"
        static let zip = "zip"

        static func skill(_ id: SkillID) -> String { "skill:\(id.rawValue)" }
        static func install(_ id: SkillID) -> String { "install:\(id.rawValue)" }
        static func searchRow(_ id: String) -> String { "search-row:\(id)" }
        static func backup(_ name: String) -> String { "backup:\(name)" }
    }

    // MARK: - Installed skills

    @Published private(set) var skills: [Skill] = []
    @Published var searchText = ""
    @Published private(set) var updateStates: [SkillID: SkillUpdateState] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var toast: String?

    // MARK: - Sheets

    @Published var importReport: SkillImportReport?
    @Published var isImportSheetPresented = false
    @Published var isDiscoverSheetPresented = false
    @Published var isBackupsSheetPresented = false

    @Published private(set) var repoList: [String] = []
    @Published private(set) var discoverResults: [DiscoveredSkill] = []
    /// What produced `discoverResults`. Shown in the sheet because a single
    /// staging directory backs them: scanning the configured repos and
    /// installing a skills.sh hit are the same operation underneath, and the
    /// second replaces the first.
    @Published private(set) var discoverSource: String?
    @Published private(set) var searchResults: [SkillsShSearchResult] = []
    @Published private(set) var backups: [SkillBackupManager.Backup] = []

    private let settingsStore: SettingsStore
    private let service: SkillsService
    private let searchClient: SkillsSearchClient
    private var searchTask: Task<Void, Never>?
    private var hasActivated = false

    init(
        settingsStore: SettingsStore,
        service: SkillsService = SkillsService(),
        searchClient: SkillsSearchClient = SkillsSearchClient()
    ) {
        self.settingsStore = settingsStore
        self.service = service
        self.searchClient = searchClient
    }

    // MARK: - Derived

    /// Case-insensitive match on name, description, and the serialized id, so
    /// `owner/repo` narrows to one repository's skills.
    var filteredSkills: [Skill] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(needle)
                || (skill.description?.localizedCaseInsensitiveContains(needle) ?? false)
                || skill.id.rawValue.localizedCaseInsensitiveContains(needle)
        }
    }

    func installedCount(for app: SkillAppTarget) -> Int {
        skills.reduce(into: 0) { total, skill in
            if skill.isEnabled(for: app) { total += 1 }
        }
    }

    func updateState(for skill: Skill) -> SkillUpdateState? {
        updateStates[skill.id]
    }

    var updatesAvailableCount: Int {
        updateStates.values.count { $0.updateAvailable }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func isBusy(skill: Skill) -> Bool { busy.contains(BusyKey.skill(skill.id)) }

    // MARK: - Lifecycle

    /// Loads the registry, and — on a machine that has skills on disk but
    /// nothing recorded — opens the import sheet unasked. That is the primary
    /// onboarding path: `~/.agents/skills` is usually already full, linked
    /// into the app dirs by another installer, and recording it is a read-only
    /// scan followed by one confirmation.
    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        Task {
            await reloadSkills()
            repoList = await service.discoverRepos()
            guard skills.isEmpty else { return }
            let report = await scanForImport()
            guard !report.adopted.isEmpty || !report.unmanagedDirectories.isEmpty else { return }
            importReport = report
            isImportSheetPresented = true
        }
    }

    func refresh() {
        Task { await reloadSkills() }
    }

    // MARK: - Per-skill actions

    func toggle(skill: Skill, app: SkillAppTarget) {
        let enable = !skill.isEnabled(for: app)
        let method = settingsStore.settings.skillsSyncMethod
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let changed = try await service.setEnabled(id, app: app, enabled: enable, method: method)
            // Disabling reports `false` when the app-side entry was a foreign
            // directory or an edited copy: the enable bit still cleared, but
            // the user's files were left where they are and they should hear
            // about it rather than discover the skill still loading.
            if !enable, !changed {
                toast = "\(skill.name) is no longer managed for \(app.displayName), "
                    + "but the existing folder was left in place."
            }
        }
    }

    func uninstall(_ skill: Skill) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let result = try await service.uninstall(id)
            updateStates[id] = nil
            let kept = SkillAppTarget.allCases
                .filter { skill.isEnabled(for: $0) && result.removedByApp[$0] == false }
            toast = kept.isEmpty
                ? "Uninstalled \(skill.name). A backup was saved."
                : "Uninstalled \(skill.name). Left in place for "
                    + kept.map(\.displayName).joined(separator: ", ") + "."
        }
    }

    func checkForUpdates() {
        perform(BusyKey.updates) { [self] in
            let states = await service.checkForUpdates()
            updateStates = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
            let available = states.count { $0.updateAvailable }
            toast = available == 0
                ? "Every repository skill is up to date."
                : "\(available) skill\(available == 1 ? "" : "s") can be updated."
        }
    }

    func updateSkill(_ skill: Skill) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let updated = try await service.update(id)
            updateStates[id] = nil
            toast = "Updated \(updated.name)."
        }
    }

    // MARK: - Discovery

    func discover() {
        perform(BusyKey.discover) { [self] in
            let refs = await service.discoverRepoRefs()
            guard !refs.isEmpty else {
                discoverResults = []
                discoverSource = nil
                toast = "Add a repository first."
                return
            }
            discoverResults = await service.discoverSkills(from: refs)
            discoverSource = "Configured repositories"
            if discoverResults.isEmpty {
                toast = "No skills were found in the configured repositories."
            }
        }
    }

    /// Drops the staging directory the last discovery pass left behind. Called
    /// when the sheet closes: the extracted trees are only useful while their
    /// rows are on screen, and they can be hundreds of megabytes.
    func discoverSheetDismissed() {
        searchTask?.cancel()
        searchTask = nil
        Task { [service] in await service.clearDiscoveryStaging() }
        discoverResults = []
        discoverSource = nil
        searchResults = []
    }

    /// Debounced so typing a query does not put one request per keystroke on
    /// skills.sh.
    func searchSkillsSh(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            busy.remove(BusyKey.search)
            return
        }
        busy.insert(BusyKey.search)
        searchTask = Task { [searchClient] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let results = try await searchClient.search(trimmed)
                guard !Task.isCancelled else { return }
                searchResults = results
                if results.isEmpty { toast = "skills.sh returned no matches." }
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
                toast = error.localizedDescription
            }
            busy.remove(BusyKey.search)
        }
    }

    func installDiscovered(_ discovered: DiscoveredSkill, apps: [SkillAppTarget]) {
        let method = settingsStore.settings.skillsSyncMethod
        perform(BusyKey.install(discovered.id)) { [self] in
            let installed = try await service.install(discovered, enableFor: apps, method: method)
            toast = apps.isEmpty
                ? "Installed \(installed.name)."
                : "Installed \(installed.name) for \(apps.map(\.displayName).joined(separator: ", "))."
        }
    }

    /// Installs a skills.sh hit by downloading the repository it names and
    /// picking the matching skill out of it.
    ///
    /// The download replaces the discovery staging, so the repo's other skills
    /// become the visible results — the alternative would be leaving rows on
    /// screen whose sources have just been deleted underneath them.
    func installSearchResult(_ result: SkillsShSearchResult, apps: [SkillAppTarget]) {
        let method = settingsStore.settings.skillsSyncMethod
        perform(BusyKey.searchRow(result.id)) { [self] in
            let found = await service.discoverSkills(from: [result.repo])
            discoverResults = found
            discoverSource = "\(result.repo.descriptor) (from skills.sh)"
            guard let match = Self.match(result.name, in: found) else {
                toast = "\(result.name) was not found in \(result.repo.slug)."
                return
            }
            let installed = try await service.install(match, enableFor: apps, method: method)
            toast = apps.isEmpty
                ? "Installed \(installed.name)."
                : "Installed \(installed.name) for \(apps.map(\.displayName).joined(separator: ", "))."
        }
    }

    func installZip(url: URL, apps: [SkillAppTarget]) {
        let method = settingsStore.settings.skillsSyncMethod
        perform(BusyKey.zip) { [self] in
            let installed = try await service.installFromZip(at: url, enableFor: apps, method: method)
            guard !installed.isEmpty else {
                toast = "Nothing in that archive could be installed."
                return
            }
            let count = "\(installed.count) skill\(installed.count == 1 ? "" : "s")"
            toast = apps.isEmpty
                ? "Installed \(count) from the archive. Switch each one on for the apps you want."
                : "Installed \(count) from the archive for \(apps.map(\.displayName).joined(separator: ", "))."
        }
    }

    // MARK: - Repository list

    func addRepo(_ raw: String) {
        perform(BusyKey.discover) { [self] in
            guard try await service.addDiscoverRepo(raw) else {
                toast = "\"\(raw)\" is not a new owner/repo[@branch] reference."
                return
            }
            repoList = await service.discoverRepos()
        }
    }

    func removeRepo(_ raw: String) {
        perform(BusyKey.discover) { [self] in
            _ = try await service.removeDiscoverRepo(raw)
            repoList = await service.discoverRepos()
        }
    }

    // MARK: - Import

    func presentImportSheet() {
        perform(BusyKey.importing) { [self] in
            importReport = await scanForImport()
            isImportSheetPresented = true
        }
    }

    /// Records the scan's adopted skills, then copies each opted-in unmanaged
    /// directory into the SSOT.
    ///
    /// Adoption is per directory rather than all-or-nothing because an
    /// unmanaged directory is real content in an app's own folder: bringing it
    /// under management replaces it with a link, and that is a decision the
    /// user makes one row at a time.
    func runImport(apps: [SkillAppTarget], adopting: [String: [SkillAppTarget]]) {
        guard let report = importReport else { return }
        let method = settingsStore.settings.skillsSyncMethod
        perform(BusyKey.importing) { [self] in
            var recorded = try await service.importAdopted(report, apps: apps).count
            var failed = 0
            for directory in adopting.keys.sorted() {
                guard
                    let targets = adopting[directory], !targets.isEmpty,
                    let source = report.unmanagedDirectories
                        .first(where: { $0.directoryName == directory })?
                        .foundIn.first
                else { continue }
                do {
                    _ = try await service.adoptUnmanaged(
                        directoryName: directory,
                        from: source,
                        apps: targets,
                        method: method
                    )
                    recorded += 1
                } catch {
                    failed += 1
                    toast = error.localizedDescription
                }
            }
            isImportSheetPresented = false
            importReport = nil
            if failed == 0 {
                toast = "Recorded \(recorded) skill\(recorded == 1 ? "" : "s")."
            }
        }
    }

    // MARK: - Backups

    func presentBackupsSheet() {
        Task {
            backups = await listBackups()
            isBackupsSheetPresented = true
        }
    }

    func reloadBackups() {
        Task { backups = await listBackups() }
    }

    func restoreBackup(_ backup: SkillBackupManager.Backup) {
        perform(BusyKey.backup(backup.directoryName)) { [self] in
            let restored = try await service.restoreBackup(backup.url)
            backups = await listBackups()
            toast = "Restored \(restored.name). Enable it for the apps you want it in."
        }
    }

    func deleteBackup(_ backup: SkillBackupManager.Backup) {
        perform(BusyKey.backup(backup.directoryName)) { [self] in
            let service = self.service
            let url = backup.url
            try await Task.detached { try service.deleteBackup(url) }.value
            backups = await listBackups()
        }
    }

    // MARK: - Internals

    /// Runs one mutating action: guards re-entry on `key`, reloads the
    /// registry when it finishes, and routes any error to `toast`.
    private func perform(_ key: String, _ body: @MainActor @escaping () async throws -> Void) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            do {
                try await body()
            } catch {
                toast = error.localizedDescription
            }
            await reloadSkills()
            busy.remove(key)
        }
    }

    private func reloadSkills() async {
        skills = await service.installedSkills()
    }

    /// `scanForImport` and `listBackups` are `nonisolated` on the service —
    /// convenient, but they walk the filesystem, so they are pushed off the
    /// main thread explicitly instead of being called inline.
    private func scanForImport() async -> SkillImportReport {
        let service = self.service
        return await Task.detached { service.scanForImport() }.value
    }

    private func listBackups() async -> [SkillBackupManager.Backup] {
        let service = self.service
        return await Task.detached { service.listBackups() }.value
    }

    /// skills.sh reports a display name; the repository lays the skill out
    /// under a directory. Match on either, case-insensitively, because neither
    /// side promises the other's spelling.
    private static func match(_ name: String, in discovered: [DiscoveredSkill]) -> DiscoveredSkill? {
        discovered.first { $0.name == name || $0.directory == name }
            ?? discovered.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || $0.directory.caseInsensitiveCompare(name) == .orderedSame
            }
    }
}
