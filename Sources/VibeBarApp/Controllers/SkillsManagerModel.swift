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
        static let bulk = "bulk"

        static func skill(_ id: SkillID) -> String { "skill:\(id.rawValue)" }
        static func install(_ id: SkillID) -> String { "install:\(id.rawValue)" }
        static func searchRow(_ id: String) -> String { "search-row:\(id)" }
        static func backup(_ name: String) -> String { "backup:\(name)" }
        static func copy(_ copy: SkillCopy) -> String { "copy:\(copy.id)" }
    }

    // MARK: - Installed skills

    @Published private(set) var skills: [Skill] = []
    /// Harness built-ins with no installed counterpart, from the same scan
    /// that attaches `Skill.otherCopies`.
    @Published private(set) var builtIns: [SkillCopy] = []
    @Published private(set) var discoveredShared: [SharedSkillDiscovery] = []
    @Published var sharedPreview: SharedSkillPreview?
    @Published private(set) var refreshRevision = 0
    @Published private(set) var inventoryCounts: [SkillAppTarget: SkillsInventoryCounts] = [:]
    /// Mirrors `AppSettings.skillsShowBuiltIn` so the page re-renders on a
    /// flip; written back only from the toolbar toggle, never per reload.
    @Published private(set) var showsBuiltIn: Bool
    @Published var searchText = ""
    @Published private(set) var updateStates: [SkillID: SkillUpdateState] = [:]
    @Published private(set) var busy: Set<String> = []
    /// Rows whose shared copy was edited outside Vibe Bar. Kept alongside
    /// `skills` and recomputed only when that list changes, so the header
    /// caption never walks the rows on a render.
    @Published private(set) var locallyModifiedCount = 0
    @Published var toast: String?
    /// Rows a running bulk change still owns. Their toggles read as busy so a
    /// hand click cannot race the loop on the same skill.
    @Published private(set) var bulkSkillIDs: Set<SkillID> = []

    // MARK: - Sheets

    @Published var importReport: SkillImportReport?
    @Published var isImportSheetPresented = false
    @Published var isDiscoverSheetPresented = false
    @Published var isBackupsSheetPresented = false

    @Published private(set) var repoList: [String] = []
    @Published private(set) var discoverResults: [DiscoveredSkill] = []
    /// What the running scan is doing, shown under the button. A repository
    /// zipball is megabytes over someone else's network; without this the
    /// sheet is a spinner with no story.
    @Published private(set) var discoverPhase: String?
    /// One line per repository the scan could not read, kept on screen after
    /// the scan ends — a toast that has already faded cannot explain an empty
    /// results list.
    @Published private(set) var discoverFailures: [String] = []
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
    /// Held so "Scan repos" can become "Cancel". Discovery is the one action
    /// here that can legitimately run for a minute.
    private var discoverTask: Task<Void, Never>?
    private var hasActivated = false

    init(
        settingsStore: SettingsStore,
        service: SkillsService = SkillsService(),
        searchClient: SkillsSearchClient = SkillsSearchClient()
    ) {
        self.settingsStore = settingsStore
        self.service = service
        self.searchClient = searchClient
        self.showsBuiltIn = settingsStore.settings.skillsShowBuiltIn
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

    var filteredSharedDiscoveries: [SharedSkillDiscovery] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return discoveredShared }
        return discoveredShared.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.description?.localizedCaseInsensitiveContains(needle) ?? false)
                || $0.logicalURL.path.localizedCaseInsensitiveContains(needle)
                || ($0.resolvedURL?.path.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// Built-in rows under the current search; empty while the toggle hides
    /// them. Matches name, description, and the harness name, so "codex"
    /// narrows to Codex's bundled skills.
    var filteredBuiltIns: [SkillCopy] {
        guard showsBuiltIn else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return builtIns }
        return builtIns.filter { copy in
            copy.name.localizedCaseInsensitiveContains(needle)
                || (copy.description?.localizedCaseInsensitiveContains(needle) ?? false)
                || (copy.location.app?.displayName.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    func setShowsBuiltIn(_ shows: Bool) {
        guard shows != showsBuiltIn else { return }
        showsBuiltIn = shows
        settingsStore.settings.skillsShowBuiltIn = shows
    }

    func installedCount(for app: SkillAppTarget) -> Int {
        inventoryCounts[app]?.enabled ?? 0
    }

    /// How many skills the harness can actually use: enabled ones plus the
    /// ones it discovers through a shared or compatibility root. This is the
    /// header-pill number — counting only `.enabled` made Cursor claim three
    /// skills while it could see nearly a hundred.
    ///
    /// A harness's own built-ins count for it too — it loads them whether or
    /// not they are listed — so this reads the whole inventory: standalone
    /// built-ins plus built-in copies attached to installed skills,
    /// independent of the show-built-in toggle and the search, like the
    /// installed half.
    func visibleCount(for app: SkillAppTarget) -> Int {
        inventoryCounts[app]?.visible ?? 0
    }

    func nativeDisabledCount(for app: SkillAppTarget) -> Int {
        inventoryCounts[app]?.nativeDisabled ?? 0
    }

    func coupledCount(for app: SkillAppTarget) -> Int {
        inventoryCounts[app]?.coupled ?? 0
    }

    func updateState(for skill: Skill) -> SkillUpdateState? {
        updateStates[skill.id]
    }

    var updatesAvailableCount: Int {
        updateStates.values.count { $0.updateAvailable }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func isBusy(skill: Skill) -> Bool {
        busy.contains(BusyKey.skill(skill.id)) || bulkSkillIDs.contains(skill.id)
    }

    // MARK: - Default harness selection

    /// Harnesses the install, discovery, and adoption sheets start with.
    var defaultApps: [SkillAppTarget] { settingsStore.settings.skillsDefaultApps }

    func isDefaultApp(_ app: SkillAppTarget) -> Bool {
        settingsStore.settings.skillsDefaultApps.contains(app)
    }

    /// One settings write per menu pick — never on a render or a tick. The
    /// explicit `objectWillChange` is what re-renders the capsule menus: the
    /// value lives in `SettingsStore`, which this model does not republish.
    func setDefaultApp(_ app: SkillAppTarget, isOn: Bool) {
        guard isOn != isDefaultApp(app) else { return }
        objectWillChange.send()
        var apps = settingsStore.settings.skillsDefaultApps
        if isOn {
            apps.append(app)
        } else {
            apps.removeAll { $0 == app }
        }
        settingsStore.settings.skillsDefaultApps = apps
    }

    // MARK: - Lifecycle

    /// Loading the page inventories existing shared entries without adopting
    /// them. The explicit Import Existing action keeps registry ownership
    /// separate from read-only discovery.
    func activate() {
        guard !hasActivated else { return }
        hasActivated = true
        Task {
            await reloadSkills()
            repoList = await service.discoverRepos()
        }
    }

    func refresh() {
        refreshRevision &+= 1
        Task { await reloadSkills() }
    }

    /// Keeps the visible toggles tied to the filesystem rather than the last
    /// registry write. SwiftUI cancels the page task when Skills is no longer
    /// visible, so this inexpensive lstat-only pass runs only while it can
    /// change something the user sees.
    func monitorFilesystem() async {
        await reloadSkills()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await reloadSkills()
        }
    }

    // MARK: - Per-skill actions

    func setActivation(
        skill: Skill,
        app: SkillAppTarget,
        action: SkillActivationAction
    ) {
        let method = settingsStore.settings.skillsSyncMethod
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let changed = try await service.setActivation(
                id,
                app: app,
                action: action,
                method: method
            )
            if action == .removeProjection, !changed {
                toast = L10n.Workbench.Skills.Toast.projectionClearedFolderKept(
                    skill: skill.name, app: app.displayName
                )
            } else if action == .removeProjection, changed, app.discoversSharedSkillRoot {
                // Removing the link is not an off switch for these harnesses,
                // and silently letting it look like one is how the old
                // "click did nothing" confusion started.
                toast = L10n.Workbench.Skills.Toast.linkRemovedStillShared(
                    app: app.displayName, skill: skill.name
                )
            } else if action == .enable, !changed {
                toast = L10n.Workbench.Skills.Toast.sharedRootNoSwitch(
                    app: app.displayName, skill: skill.name
                )
            } else if action == .disableInHarness {
                toast = L10n.Workbench.Skills.Toast.disabledKeptProjection(
                    skill: skill.name, app: app.displayName
                )
            }
        }
    }

    // MARK: - Bulk actions

    /// What switching `app` toward `direction` would do to the rows the
    /// current filter shows. Computed on a menu pick, not in `body`.
    func bulkPlan(app: SkillAppTarget, direction: SkillBulkDirection) -> SkillBulkPlan {
        SkillBulkPlan(app: app, direction: direction, skills: filteredSkills)
    }

    func startBulk(_ plan: SkillBulkPlan) {
        Task { await applyBulk(plan) }
    }

    /// Runs a confirmed bulk change row by row through the same
    /// `setActivation` the per-skill toggles use, so a bulk enable writes
    /// exactly what a hundred single clicks would have.
    ///
    /// Plain `async` rather than routed through `perform`: the loop reports
    /// progress into the toast as it goes and settles its own summary, where
    /// `perform` would replace both with a single error.
    func applyBulk(_ confirmed: SkillBulkPlan) async {
        guard !busy.contains(BusyKey.bulk) else { return }
        busy.insert(BusyKey.bulk)
        // The dialog may have sat open across several reloads; act on the
        // registry as it is now, not on the reading the count was quoted from.
        let plan = confirmed.refreshed(against: skills)
        bulkSkillIDs = Set(plan.steps.map(\.id))
        let method = settingsStore.settings.skillsSyncMethod
        let app = plan.app
        let service = self.service
        let outcome = await plan.run(
            apply: { step in
                // `false` is a managed copy the user edited, left in place.
                try await service.setActivation(
                    step.id,
                    app: app,
                    action: step.action,
                    method: method
                )
            },
            progress: { [weak self] done, total in
                self?.showBulkProgress(app: app, done: done, total: total)
            }
        )
        await reloadSkills()
        bulkSkillIDs = []
        busy.remove(BusyKey.bulk)
        toast = outcome.notChanged == 0
            ? L10n.Workbench.Skills.Toast.bulkDone(app: app.displayName, succeeded: outcome.succeeded)
            : L10n.Workbench.Skills.Toast.bulkPartial(
                app: app.displayName,
                succeeded: outcome.succeeded,
                failed: outcome.notChanged
            )
    }

    private func showBulkProgress(app: SkillAppTarget, done: Int, total: Int) {
        toast = [
            app.displayName,
            L10n.Quota.History.curvesSome(shown: done, total: total),
        ].joined(separator: " · ")
    }

    func uninstall(_ skill: Skill) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let result = try await service.uninstall(id)
            updateStates[id] = nil
            let kept = result.retainedApps
            toast = kept.isEmpty
                ? L10n.Workbench.Skills.Toast.uninstalledBackedUp(skill: skill.name)
                : L10n.Workbench.Skills.Toast.uninstalledLeftInPlace(
                    skill: skill.name,
                    apps: kept.map(\.displayName).joined(separator: ", ")
                )
        }
    }

    func checkForUpdates() {
        perform(BusyKey.updates) { [self] in
            let states = await service.checkForUpdates()
            updateStates = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
            let available = states.count { $0.updateAvailable }
            toast = available == 0
                ? L10n.Workbench.Skills.Toast.allUpToDate
                : L10n.Workbench.Skills.Toast.updatesAvailable(count: available)
        }
    }

    /// Makes the shared copy's current contents the recorded baseline. The
    /// cached update state was measured against the old baseline, so it is
    /// dropped rather than left to claim a comparison nobody ran.
    func acceptLocalChanges(_ skill: Skill) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let accepted = try await service.acceptLocalChanges(id)
            updateStates[id] = nil
            toast = L10n.Workbench.Skills.Toast.acceptedLocalChanges(skill: accepted.name)
        }
    }

    func updateSkill(_ skill: Skill) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let updated = try await service.update(id)
            updateStates[id] = nil
            toast = L10n.Workbench.Skills.Toast.updated(skill: updated.name)
        }
    }

    // MARK: - Copies

    /// Makes `copy`'s content the shared copy of `skill`. The service backs
    /// the shared copy up first; the confirmation lives in the row.
    func replaceSharedCopy(skill: Skill, with copy: SkillCopy) {
        let id = skill.id
        perform(BusyKey.skill(id)) { [self] in
            let replaced = try await service.replaceSharedCopy(id, with: copy)
            toast = L10n.Workbench.Skills.Toast.replacedShared(skill: replaced.name)
        }
    }

    /// Installs a built-in into the shared library with no harness enabled.
    func copyToShared(_ copy: SkillCopy) {
        perform(BusyKey.copy(copy)) { [self] in
            let installed = try await service.copyToShared(copy)
            toast = L10n.Workbench.Skills.Toast.copiedToShared(skill: installed.name)
        }
    }

    // MARK: - Discovery

    var isDiscovering: Bool { isBusy(BusyKey.discover) }

    /// Bumped per discovery so a phase update still queued on the main actor
    /// when a run ends (or is cancelled) cannot resurrect stale text.
    private var discoverGeneration = 0

    func discover() {
        discoverFailures = []
        discoverPhase = nil
        discoverGeneration += 1
        let generation = discoverGeneration
        discoverTask = perform(BusyKey.discover) { [self] in
            let refs = await service.discoverRepoRefs()
            guard !refs.isEmpty else {
                discoverResults = []
                discoverSource = nil
                toast = L10n.Workbench.Skills.Toast.addRepoFirst
                return
            }
            // The phases arrive from the download tasks; the hop back is what
            // keeps `@Published` on the main actor.
            let result = await service.discover(from: refs) { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.discoverGeneration == generation, self.isDiscovering else { return }
                    self.discoverPhase = Self.text(for: phase)
                }
            }
            discoverGeneration += 1
            discoverPhase = nil
            discoverResults = result.skills
            discoverSource = L10n.Workbench.Skills.Discover.reposTitle
            discoverFailures = result.failures.map(\.displayText)
            if result.wasCancelled {
                toast = L10n.Workbench.Skills.Toast.scanStopped
            } else if !result.failures.isEmpty {
                toast = result.failures.count == 1
                    ? result.failures[0].displayText
                    : L10n.Workbench.Skills.Toast.reposUnreadable(count: result.failures.count)
            } else if result.skills.isEmpty {
                toast = L10n.Workbench.Skills.Toast.noSkillsFound
            }
        }
    }

    /// Stops an in-flight scan. The service returns what it already had, so
    /// the results list keeps any repository that finished first.
    func cancelDiscover() {
        discoverGeneration += 1
        discoverTask?.cancel()
    }

    private static func text(for phase: SkillDiscoveryPhase) -> String {
        switch phase {
        case let .downloading(slug):
            return L10n.Workbench.Skills.Phase.downloading(repo: slug)
        case let .scanning(slug):
            return L10n.Workbench.Skills.Phase.scanning(repo: slug)
        case let .repositoryFinished(_, completed, total):
            return total == 1
                ? L10n.Workbench.Skills.Phase.downloadedOne
                : L10n.Workbench.Skills.Phase.downloadedProgress(
                    completed: completed, total: total
                )
        }
    }

    /// Drops the staging directory the last discovery pass left behind. Called
    /// when the sheet closes: the extracted trees are only useful while their
    /// rows are on screen, and they can be hundreds of megabytes.
    func discoverSheetDismissed() {
        searchTask?.cancel()
        searchTask = nil
        discoverGeneration += 1
        discoverTask?.cancel()
        discoverTask = nil
        discoverPhase = nil
        discoverFailures = []
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
                if results.isEmpty { toast = L10n.Workbench.Skills.Toast.noSearchMatches }
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
                ? L10n.Workbench.Skills.Toast.installedShared(skill: installed.name)
                : L10n.Workbench.Skills.Toast.installedForApps(
                    skill: installed.name,
                    apps: apps.map(\.displayName).joined(separator: ", ")
                )
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
            discoverSource = L10n.Workbench.Skills.Discover.sourceFromSkillsSh(
                repo: result.repo.descriptor
            )
            guard let match = Self.match(result.name, in: found) else {
                toast = L10n.Workbench.Skills.Toast.notFoundInRepo(
                    skill: result.name, repo: result.repo.slug
                )
                return
            }
            let installed = try await service.install(match, enableFor: apps, method: method)
            toast = apps.isEmpty
                ? L10n.Workbench.Skills.Toast.installedShared(skill: installed.name)
                : L10n.Workbench.Skills.Toast.installedForApps(
                    skill: installed.name,
                    apps: apps.map(\.displayName).joined(separator: ", ")
                )
        }
    }

    func installZip(url: URL, apps: [SkillAppTarget]) {
        let method = settingsStore.settings.skillsSyncMethod
        perform(BusyKey.zip) { [self] in
            let installed = try await service.installFromZip(at: url, enableFor: apps, method: method)
            guard !installed.isEmpty else {
                toast = L10n.Workbench.Skills.Toast.archiveEmpty
                return
            }
            // The count is its own sentence: a plural noun phrase spliced
            // into a frame is not something a second language can reorder.
            let installedCount = L10n.Workbench.Skills.Toast.installedArchive(
                count: installed.count
            )
            toast = installedCount + " " + (apps.isEmpty
                ? L10n.Workbench.Skills.Toast.sharedLibraryNote
                : L10n.Workbench.Skills.Toast.enabledForApps(
                    apps: apps.map(\.displayName).joined(separator: ", ")
                ))
        }
    }

    // MARK: - Repository list

    func addRepo(_ raw: String) {
        perform(BusyKey.discover) { [self] in
            guard try await service.addDiscoverRepo(raw) else {
                toast = L10n.Workbench.Skills.Toast.invalidRepoRef(input: raw)
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
                toast = L10n.Workbench.Skills.Toast.recorded(count: recorded)
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
            toast = L10n.Workbench.Skills.Toast.restored(skill: restored.name)
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
    ///
    /// Returns the task so a long-running action can be cancelled later; `nil`
    /// means the key was already busy and nothing new was started.
    @discardableResult
    private func perform(
        _ key: String,
        _ body: @MainActor @escaping () async throws -> Void
    ) -> Task<Void, Never>? {
        guard !busy.contains(key) else { return nil }
        busy.insert(key)
        return Task {
            do {
                try await body()
            } catch is CancellationError {
                // The user asked for it; the action that was cancelled says
                // what happened, if anything needs saying at all.
            } catch {
                toast = error.localizedDescription
            }
            await reloadSkills()
            busy.remove(key)
        }
    }

    private func reloadSkills() async {
        let latest = await service.inventory()
        let counts = Dictionary(uniqueKeysWithValues: SkillAppTarget.managedHarnesses.map { ($0, latest.counts(for: $0)) })
        if counts != inventoryCounts { inventoryCounts = counts }
        if latest.builtIns != builtIns { builtIns = latest.builtIns }
        if latest.discoveredShared != discoveredShared { discoveredShared = latest.discoveredShared }
        guard latest.installed != skills else { return }
        skills = latest.installed
        let modified = latest.installed.count { $0.isLocallyModified }
        if modified != locallyModifiedCount { locallyModifiedCount = modified }
    }

    func previewSharedSkill(_ entry: SharedSkillDiscovery) {
        Task {
            do {
                let text = try await service.previewSharedSkill(entry)
                sharedPreview = SharedSkillPreview(name: entry.name, source: entry.resolvedURL ?? entry.logicalURL, text: text)
            } catch let error as SharedSkillReadError {
                switch error {
                case .changedSource: toast = L10n.Workbench.Library.Error.staleRevision
                case .invalidDirectory: toast = L10n.Workbench.Library.Error.unsafePath
                case .unavailable(let state):
                    switch state {
                    case .brokenLink: toast = L10n.Workbench.Library.brokenLink
                    case .cyclicLink: toast = L10n.Workbench.Library.cyclicLink
                    case .tooLarge: toast = L10n.Workbench.Library.tooLarge
                    case .missingSkillFile: toast = L10n.Workbench.Library.missingSkillFile
                    case .ready, .unreadable: toast = L10n.Workbench.Library.unreadable
                    }
                }
            } catch {
                toast = L10n.Workbench.Library.unreadable
            }
        }
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

struct SharedSkillPreview: Identifiable {
    let id = UUID()
    let name: String
    let source: URL
    let text: String
}
