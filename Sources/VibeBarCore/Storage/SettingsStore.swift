import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            // The language override is mirrored on *every* assignment,
            // including one adopted from another writer's file: a second
            // client that changed the language is describing the same
            // preference, and a surface that kept rendering the old one
            // would be showing a setting the file no longer holds.
            applyLanguage()
            guard !isAdoptingExternalChange else { return }
            schedulePersist()
        }
    }

    /// Push `settings.language` into `L10n`, which is what every lookup
    /// reads.
    ///
    /// Here rather than in the App target because Core resolves strings
    /// too — an adapter's error message, the MCP surface — and because
    /// this store is the one place the value is ever set. Views re-render
    /// on their own: the assignment that changed the language already
    /// published to every `$settings` subscriber, so the same pass that
    /// redraws the picker redraws the labels around it. No relaunch.
    private func applyLanguage() {
        AppLocalization.languageOverride = settings.language
    }

    /// Set when a setting this process had changed was replaced by another
    /// writer's value. Nil at every other time, including for the far more
    /// common case of an external edit to a setting nobody here touched —
    /// that one is adopted silently, because nothing was lost.
    @Published public private(set) var replacedByAnotherWriter: ExternalSettingsChange?

    /// True while the file's values are being copied into `settings`, so the
    /// adoption does not schedule a write of what was just read.
    private var isAdoptingExternalChange = false
    private var watcher: FileChangeWatcher?

    private let defaultsKey = "VibeBar.settings.v1"

    /// Settings edits arrive one keystroke / one toggle at a time, and every
    /// one used to encode and atomically rewrite the file on the main thread
    /// before the view could redraw. Coalesce: one write per burst, off the
    /// main actor; `flush()` writes synchronously (quit, refresh triggers).
    ///
    /// Every snapshot carries a sequence number and the writer only applies a
    /// snapshot newer than the last one it wrote, so a coalesced task that
    /// resumes late can never overwrite a `flush()` that beat it.
    private var pendingPersist: Task<Void, Never>?
    private var persistSequence: UInt64 = 0
    private static let persistCoalesceNanoseconds: UInt64 = 250_000_000
    private static let writeQueue = DispatchQueue(
        label: "com.astroqore.VibeBar.settings.persist", qos: .utility
    )
    /// Only ever touched on `writeQueue`.
    private nonisolated(unsafe) static var lastWrittenSequence: UInt64 = 0
    /// Where this store reads and writes. A parameter rather than a constant
    /// so the merge can be exercised against a real file: the whole point of
    /// this class is what it does to one that changed underneath it.
    private nonisolated(unsafe) static var fileURL: URL = VibeBarLocalStore.settingsURL
    /// The file as this process last saw it, which is what a write measures
    /// its own edits against. Only ever touched on `writeQueue`.
    private nonisolated(unsafe) static var baseline: SettingsDocument.Object = [:]

    /// The settings this process has actually changed since it launched.
    ///
    /// Without it there is no way to tell "someone replaced the value I chose"
    /// from "someone changed a setting I have never touched" — by the time the
    /// other writer's file arrives, our own edit is long since saved and looks
    /// exactly like the value that was always there. Only ever touched on
    /// `writeQueue`.
    private nonisolated(unsafe) static var editedKeys: Set<String> = []

    /// This process's own settings as of its last write.
    ///
    /// Deliberately not the file: measuring our edits against the file counts
    /// every default the file did not happen to carry as something the user
    /// chose, and the first save then claims authorship of the entire
    /// document. What we changed is what changed *here*. Only ever touched on
    /// `writeQueue`.
    private nonisolated(unsafe) static var lastMine: SettingsDocument.Object = [:]

    /// The keys a default document has, which is the part of this build's
    /// vocabulary that does not depend on the current value.
    private nonisolated static let defaultKeys: Set<String> =
        Set(SettingsDocument.object(encoding: AppSettings.default)?.keys ?? [:].keys)

    /// Every top-level key this build could write, so a merge can tell a
    /// setting the user removed from one it has never heard of.
    ///
    /// The union of what is being written and what a default document holds:
    /// an optional field that is nil right now is absent from the first and
    /// present in the second, and it is still ours to remove.
    private nonisolated static func ownedKeys(writing mine: SettingsDocument.Object) -> Set<String> {
        defaultKeys.union(mine.keys)
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        persistSequence += 1
        let sequence = persistSequence
        let snapshot = settings
        let fold = foldHandler()
        pendingPersist = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: Self.persistCoalesceNanoseconds)
            guard !Task.isCancelled else { return }
            Self.writeQueue.async {
                Self.write(snapshot, sequence: sequence, foldedExternalChange: fold)
            }
        }
    }

    /// Write `snapshot` (default: the current settings) now, ordered after
    /// any write already in flight and ahead of any stale coalesced task.
    /// Callers that hand settings to something reading `settings.json` from
    /// disk pass the value they were just given — `@Published` emits during
    /// `willSet`, so `self.settings` may still be the previous value there.
    public func flush(_ snapshot: AppSettings? = nil) {
        pendingPersist?.cancel()
        pendingPersist = nil
        persistSequence += 1
        let sequence = persistSequence
        let value = snapshot ?? settings
        let fold = foldHandler()
        Self.writeQueue.sync {
            Self.write(value, sequence: sequence, foldedExternalChange: fold)
        }
    }

    /// What another writer took over, for the user to be told about.
    public struct ExternalSettingsChange: Equatable, Sendable {
        /// The settings whose values this process had changed and which now
        /// hold someone else's value instead.
        public let replacedKeys: [String]
        public let observedAt: Date

        public init(replacedKeys: [String], observedAt: Date) {
            self.replacedKeys = replacedKeys
            self.observedAt = observedAt
        }

        /// One sentence naming what was taken over.
        ///
        /// Settings are named by their JSON key, which is the only name that
        /// exists for every one of them — a hand-kept table of prettier
        /// labels would be wrong for whichever setting was added last.
        public var summary: String {
            let names = replacedKeys.map(Self.humanised(_:))
            guard !names.isEmpty else { return "" }
            let listed = names.prefix(3).joined(separator: ", ")
            if names.count > 3 {
                let rest = names.count - 3
                return "\(listed) and \(rest) more settings now hold the other copy's value."
            }
            let verb = names.count == 1 ? "holds" : "hold"
            return "\(listed) now \(verb) the other copy's value."
        }

        /// `refreshIntervalSeconds` reads as "Refresh interval seconds".
        static func humanised(_ key: String) -> String {
            var words: [String] = []
            var current = ""
            for character in key {
                if character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = String(character).lowercased()
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { words.append(current) }
            guard let first = words.first else { return key }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
                .joined(separator: " ")
        }
    }

    public init(userDefaults: UserDefaults = .standard, settingsURL: URL? = nil) {
        let url = settingsURL ?? VibeBarLocalStore.settingsURL
        // The raw object as well as the decoded value: a write puts back only
        // what changed, so it needs to know what was there to begin with.
        var existing: SettingsDocument.Object?
        Self.writeQueue.sync {
            Self.fileURL = url
            Self.lastWrittenSequence = 0
            Self.editedKeys = []
            Self.lastMine = [:]
            existing = SettingsDocument.read(from: url)
            Self.baseline = existing ?? [:]
        }

        if let decoded = try? VibeBarLocalStore.readJSON(AppSettings.self, from: url) {
            let migrated = Self.migrated(decoded)
            self.settings = migrated
            // What was loaded is this process's starting position. A migration
            // that follows is a real change and writes only what it changed.
            Self.setLastMine(encoding: decoded)
            if migrated != decoded {
                persist()
            }
        } else if
            let data = userDefaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            self.settings = Self.migrated(decoded)
            adoptStartingPosition(writingOver: existing)
        } else {
            self.settings = .default
            adoptStartingPosition(writingOver: existing)
        }
        // `didSet` does not run for assignments made inside `init`, so the
        // language chosen in a previous session has to be installed here.
        applyLanguage()
        startWatching(url)
    }

    /// The fallback branches, which run both when there is no file and when
    /// there is one this build cannot decode. Those are opposite situations.
    ///
    /// No file: write, so the settings exist somewhere. A file that is a valid
    /// object but does not decode is a *newer* client's — a settings value with
    /// a case added since this build — and saving defaults over it destroys
    /// exactly what the merge exists to protect. Hold the defaults in memory so
    /// there is something to show, take them as the starting position so a
    /// later write carries only what the user actually changes, and leave the
    /// file alone.
    private func adoptStartingPosition(writingOver existing: SettingsDocument.Object?) {
        Self.setLastMine(encoding: existing == nil ? nil : settings)
        if existing == nil {
            persist()
        }
    }

    /// `nil` means "nothing written yet", so the first write carries the whole
    /// document — which is right when there is no file to carry it.
    private nonisolated static func setLastMine<T: Encodable>(encoding value: T?) {
        let object = value.flatMap { SettingsDocument.object(encoding: $0) } ?? [:]
        writeQueue.sync { lastMine = object }
    }

    /// The file is shared — with Vibe Bar Desktop, and with a second copy of
    /// this app — so a change to it is news, not an error. Adopt it while it
    /// is happening rather than at the next launch.
    private func startWatching(_ url: URL) {
        let watcher = FileChangeWatcher(url: url) { [weak self] in
            // Our own saves come back through this watcher too, and they are
            // the common case by a wide margin. Settle that here, on the
            // watcher's own queue, rather than waking the main actor to
            // re-encode the settings and find nothing has changed.
            guard Self.fileDiffersFromBaseline() else { return }
            Task { @MainActor [weak self] in self?.adoptExternalChange() }
        }
        watcher.start()
        self.watcher = watcher
    }

    private nonisolated static func fileDiffersFromBaseline() -> Bool {
        writeQueue.sync {
            guard let theirs = SettingsDocument.read(from: fileURL) else { return false }
            return !SettingsDocument.equal(theirs, baseline)
        }
    }

    /// Take on whatever another writer changed, and report only what it cost.
    ///
    /// The file wins where both sides moved the same setting: it is the shared
    /// state, and the alternative — quietly keeping a value the file no longer
    /// holds — is the stale-UI bug this watching exists to end. The user is
    /// told, which is the part that makes the file winning acceptable.
    private func adoptExternalChange() {
        guard let mine = SettingsDocument.object(encoding: settings) else { return }
        var adopted: (settings: AppSettings, conflicts: [String])?

        // One block: the decode decides whether any of this is adopted at all,
        // and a write landing between deciding and recording would leave the
        // baseline describing a file this store never actually took on.
        Self.writeQueue.sync {
            guard let theirs = SettingsDocument.read(from: Self.fileURL) else { return }
            // Our own write, coming back to us.
            guard !SettingsDocument.equal(theirs, Self.baseline) else { return }
            let theirChanges = SettingsDocument.changedKeys(from: Self.baseline, to: theirs)
            // What they changed, among the settings we chose a value for —
            // whether that choice is still sitting unsaved in memory or was
            // written out and has since been taken over.
            let unsaved = SettingsDocument.changedKeys(from: Self.lastMine, to: mine)
            let conflicts = theirChanges
                .intersection(Self.editedKeys.union(unsaved))
                .filter { !SettingsDocument.equal(mine[$0], theirs[$0]) }
            // Their changes land on top of ours; anything we changed and they
            // did not is still unwritten here and survives to the next save.
            let object = SettingsDocument.merge(baseline: Self.baseline, mine: theirs, theirs: mine)

            // A file this build cannot read is one it must not claim to have
            // seen. Advancing the baseline here would let the next save diff
            // our old values against it and write them over a newer writer's
            // — losing exactly what the merge exists to keep.
            guard
                let data = try? SettingsDocument.data(from: object),
                let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
            else { return }

            Self.baseline = theirs
            // Their value is our position now, not our edit: leaving `lastMine`
            // behind would make the next save claim their key as ours and
            // report it as lost the next time they touched it.
            for key in theirChanges {
                if let value = theirs[key] {
                    Self.lastMine[key] = value
                } else {
                    Self.lastMine.removeValue(forKey: key)
                }
            }
            Self.editedKeys.subtract(theirChanges)
            adopted = (Self.migrated(decoded), conflicts.sorted())
        }

        guard let adopted else { return }

        // A coalesced save may be in flight, holding a snapshot taken before
        // any of this. Left alone it would write those values back and undo
        // the change just adopted, so it is replaced rather than cancelled:
        // the snapshot is stale, the edits in it are not.
        let hadUnsavedEdits = pendingPersist != nil
        pendingPersist?.cancel()
        pendingPersist = nil

        isAdoptingExternalChange = true
        settings = adopted.settings
        isAdoptingExternalChange = false
        if hadUnsavedEdits { schedulePersist() }

        report(replaced: adopted.conflicts)
    }

    /// Install a file this process has just written on top of an external
    /// change, so what is on screen matches what is on disk.
    private func install(_ object: SettingsDocument.Object, replaced: [String]) {
        guard
            let data = try? SettingsDocument.data(from: object),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }
        isAdoptingExternalChange = true
        settings = Self.migrated(decoded)
        isAdoptingExternalChange = false
        report(replaced: replaced)
    }

    /// Add to the standing notice rather than replacing it.
    ///
    /// A later external write that costs nothing is not news that the first
    /// one cost nothing, and a second one that costs something does not undo
    /// the first. Only `acknowledgeExternalChange()` clears this.
    private func report(replaced keys: [String]) {
        guard !keys.isEmpty else { return }
        let combined = Set(replacedByAnotherWriter?.replacedKeys ?? []).union(keys)
        replacedByAnotherWriter = ExternalSettingsChange(
            replacedKeys: combined.sorted(), observedAt: Date()
        )
    }

    /// Dismiss the notice, once the user has seen it.
    public func acknowledgeExternalChange() {
        replacedByAnotherWriter = nil
    }

    private func persist() {
        Self.write(settings, sequence: nil, foldedExternalChange: foldHandler())
    }

    /// A write can find the file already changed, fold it in, and record the
    /// result as seen. The watcher then has nothing left to notice, so the
    /// write says so itself.
    private func foldHandler() -> @Sendable (SettingsDocument.Object, [String]) -> Void {
        { [weak self] object, replaced in
            Task { @MainActor in self?.install(object, replaced: replaced) }
        }
    }

    /// `sequence == nil` (load-time migration writes) always applies.
    ///
    /// Writes what this process changed, not everything it holds. A whole-file
    /// rewrite from a decoded `AppSettings` deletes every key the writer did
    /// not know — another client's settings, or a newer build's — and the loss
    /// only shows up later as a setting that quietly reverted.
    private nonisolated static func write(
        _ settings: AppSettings,
        sequence: UInt64?,
        foldedExternalChange: (@Sendable (SettingsDocument.Object, [String]) -> Void)? = nil
    ) {
        if let sequence {
            guard sequence > lastWrittenSequence else { return }
            lastWrittenSequence = sequence
        }
        guard let mine = SettingsDocument.object(encoding: settings) else {
            SafeLog.warn("Saving settings failed: settings did not encode to an object")
            return
        }
        // Re-read and write under one lock: the re-read is what lets the
        // other writer's keys survive, and without the lock another writer
        // can land between the two and have its whole merge undone.
        SharedFileLock.withLock(named: "settings", in: fileURL.deletingLastPathComponent()) {
            // Re-read rather than trusting the baseline: something else may have
            // written since, and its keys have to survive this write.
            let theirs = SettingsDocument.read(from: fileURL) ?? baseline
            // Against this process's own previous value, never against the
            // file. A settings file written by an older version is missing
            // keys that decoding materialises as defaults here; measured
            // against the file those defaults look like edits, and the next
            // save writes them over whatever the other client had put there.
            let changed = SettingsDocument.changedKeys(
                from: lastMine, to: mine, owned: ownedKeys(writing: mine)
            )
            // The other writer got there first, and this write is about to put
            // its own keys on top and record the result as the file we have
            // seen. Without saying so, the watcher that follows compares the
            // file against a baseline that already contains their change,
            // finds nothing, and this process goes on showing stale settings
            // until the next external write or a restart.
            let theirChanges = SettingsDocument.changedKeys(from: baseline, to: theirs)
            // Not the keys this write is applying: ours is the value that
            // reaches the file, so nothing of ours was replaced there. Saying
            // otherwise puts "another Vibe Bar replaced your change" in front
            // of someone whose change is the one that won.
            let conflicts = theirChanges
                .subtracting(changed)
                .intersection(editedKeys)
                .filter { !SettingsDocument.equal(mine[$0], theirs[$0]) }
                .sorted()

            var merged = theirs
            for key in changed {
                if let value = mine[key] { merged[key] = value } else { merged.removeValue(forKey: key) }
            }

            // Whether this build can read back what it is about to write. It
            // writes either way — the file is correct, and their value is in
            // it — but a merged object it cannot decode is one whose values it
            // has *not* taken on, and recording otherwise would let the next
            // save treat its own fallback as an edit and overwrite them.
            let readable = (try? SettingsDocument.data(from: merged))
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } != nil

            do {
                try VibeBarLocalStore.writeData(
                    SettingsDocument.data(from: merged), to: fileURL,
                    base: fileURL.deletingLastPathComponent()
                )
                // Only now: a write that failed has changed nothing, and a
                // process that recorded these as written would leave them out
                // of the next merge and off the disk until it restarted.
                baseline = merged
                editedKeys.formUnion(changed)
                lastMine = mine
                guard readable else { return }
                // Their value is our position now for anything we are not
                // writing ourselves.
                for key in theirChanges where !changed.contains(key) {
                    if let value = theirs[key] {
                        lastMine[key] = value
                    } else {
                        lastMine.removeValue(forKey: key)
                    }
                    editedKeys.remove(key)
                }
                if !theirChanges.isEmpty {
                    foldedExternalChange?(merged, conflicts)
                }
            } catch {
                SafeLog.warn("Saving settings failed: \(SafeLog.sanitize(error.localizedDescription))")
            }
        }
    }

    static func migrated(_ settings: AppSettings) -> AppSettings {
        var migrated = settings
        migrated.mockEnabled = false
        // Claude bucket IDs were renamed when Daily Routines moved out of the
        // headline weekly group. Rewrite stale field IDs in-place so the user
        // doesn't have to re-pick everything in Settings.
        let bucketIdMigrations: [String: String?] = [
            "claude.weekly_cowork":      "claude.daily_routines",
            "claude.design_promotional": nil,    // dropped — never showed up in real responses
            "claude.extra_usage":        nil,    // promoted out of buckets, surfaced as ProviderExtras now
            "grok.monthly":              "grok.weekly"
        ]
        var menuItems = migrated.menuBarItems
        for index in menuItems.indices {
            menuItems[index].selectedFieldIds = renameOrDropFieldIds(menuItems[index].selectedFieldIds, mapping: bucketIdMigrations)
            for (oldId, newId) in bucketIdMigrations {
                if let label = menuItems[index].customLabels.removeValue(forKey: oldId), let newId {
                    menuItems[index].customLabels[newId] = label
                }
            }
        }
        migrated.menuBarItems = menuItems
        migrated.miniWindow.selectedFieldIds = renameOrDropFieldIds(migrated.miniWindow.selectedFieldIds, mapping: bucketIdMigrations)
        migrated.miniWindow.compactSelectedFieldIds = renameOrDropFieldIds(
            migrated.miniWindow.compactSelectedFieldIds,
            mapping: bucketIdMigrations
        )
        for (oldId, newId) in bucketIdMigrations {
            if let label = migrated.miniWindow.customLabels.removeValue(forKey: oldId), let newId {
                migrated.miniWindow.customLabels[newId] = label
            }
        }
        for index in migrated.miniWindow.windows.indices {
            migrated.miniWindow.windows[index].fieldIds = renameOrDropFieldIds(
                migrated.miniWindow.windows[index].fieldIds,
                mapping: bucketIdMigrations
            )
        }
        let legacyMiniDefaults = [
            "codex.five_hour",
            "codex.weekly",
            "claude.five_hour",
            "claude.weekly"
        ]
        if migrated.miniWindow.selectedFieldIds == legacyMiniDefaults {
            migrated.miniWindow.selectedFieldIds = AppSettings.defaultMiniWindow.selectedFieldIds
        }
        if migrated.miniWindow.compactSelectedFieldIds == legacyMiniDefaults {
            migrated.miniWindow.compactSelectedFieldIds = AppSettings.defaultMiniWindow.compactSelectedFieldIds
        }
        for index in migrated.miniWindow.windows.indices
        where migrated.miniWindow.windows[index].fieldIds == legacyMiniDefaults {
            migrated.miniWindow.windows[index].fieldIds = AppSettings.defaultMiniWindow.selectedFieldIds
        }
        return migrated
    }

    private static func renameOrDropFieldIds(_ ids: [String], mapping: [String: String?]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in ids {
            let resolved: String?
            if mapping.keys.contains(id) {
                resolved = mapping[id] ?? nil
            } else {
                resolved = id
            }
            guard let resolved else { continue }
            if seen.insert(resolved).inserted { out.append(resolved) }
        }
        return out
    }

    // MARK: - Convenience accessors used by views

    public var displayMode: DisplayMode {
        get { settings.displayMode }
        set { settings.displayMode = newValue }
    }
    public var menuBarTextEnabled: Bool {
        get { settings.menuBarTextEnabled }
        set { settings.menuBarTextEnabled = newValue }
    }
    public var refreshIntervalSeconds: Int {
        get { settings.refreshIntervalSeconds }
        set { settings.refreshIntervalSeconds = max(60, newValue) }
    }
    public var refreshOnPopoverOpen: Bool {
        get { settings.refreshOnPopoverOpen }
        set { settings.refreshOnPopoverOpen = newValue }
    }
    public var popoverOpenRefreshCooldownSeconds: Int {
        get { settings.popoverOpenRefreshCooldownSeconds }
        set { settings.popoverOpenRefreshCooldownSeconds = max(60, newValue) }
    }
    public var mockEnabled: Bool {
        get { settings.mockEnabled }
        set { settings.mockEnabled = false }
    }
    public var codexUsageMode: CodexUsageMode {
        get { settings.codexUsageMode }
        set { settings.codexUsageMode = newValue }
    }
    public var claudeUsageMode: ClaudeUsageMode {
        get { settings.claudeUsageMode }
        set { settings.claudeUsageMode = newValue }
    }
    public var geminiUsageMode: GeminiUsageMode {
        get { settings.geminiUsageMode }
        set { settings.geminiUsageMode = newValue }
    }
    public var antigravityUsageMode: AntigravityUsageMode {
        get { settings.antigravityUsageMode }
        set { settings.antigravityUsageMode = newValue }
    }
    public var launchAtLogin: Bool {
        get { settings.launchAtLogin }
        set { settings.launchAtLogin = newValue }
    }
    public var costData: CostDataSettings {
        get { settings.costData }
        set { settings.costData = newValue }
    }
    public var preferredTerminal: PreferredTerminal {
        get { settings.preferredTerminal }
        set { settings.preferredTerminal = newValue }
    }
    public var sessionBodyIndexingEnabled: Bool {
        get { settings.sessionBodyIndexingEnabled }
        set { settings.sessionBodyIndexingEnabled = newValue }
    }
}
