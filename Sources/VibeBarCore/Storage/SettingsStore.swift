import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            guard !isAdoptingExternalChange else { return }
            schedulePersist()
        }
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
        pendingPersist = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: Self.persistCoalesceNanoseconds)
            guard !Task.isCancelled else { return }
            Self.writeQueue.async { Self.write(snapshot, sequence: sequence) }
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
        Self.writeQueue.sync { Self.write(value, sequence: sequence) }
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
        Self.writeQueue.sync {
            Self.fileURL = url
            Self.lastWrittenSequence = 0
            Self.editedKeys = []
            Self.lastMine = [:]
            Self.baseline = SettingsDocument.read(from: url) ?? [:]
        }
        if
            let decoded = try? VibeBarLocalStore.readJSON(AppSettings.self, from: url)
        {
            let migrated = Self.migrated(decoded)
            self.settings = migrated
            if migrated != decoded {
                persist()
            }
        } else if
            let data = userDefaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        {
            self.settings = Self.migrated(decoded)
            persist()
        } else {
            self.settings = .default
            persist()
        }
        // The settings this process starts from — whatever migration or the
        // defaults just filled in — are its position, not its edits. Any
        // write above ran against an empty `lastMine` and so recorded the
        // whole document; this is where that accounting is set straight.
        let loaded = SettingsDocument.object(encoding: settings)
        Self.writeQueue.sync {
            Self.lastMine = loaded ?? [:]
            Self.editedKeys = []
        }
        startWatching(url)
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
        var adopted: (object: SettingsDocument.Object, conflicts: [String])?

        Self.writeQueue.sync {
            guard let theirs = SettingsDocument.read(from: Self.fileURL) else { return }
            // Our own write, coming back to us.
            guard !SettingsDocument.equal(theirs, Self.baseline) else { return }
            // What they changed, among the settings we chose a value for —
            // whether that choice is still sitting unsaved in memory or was
            // written out and has since been taken over.
            let unsaved = SettingsDocument.changedKeys(from: Self.lastMine, to: mine)
            let ours = Self.editedKeys.union(unsaved)
            let conflicts = SettingsDocument.changedKeys(from: Self.baseline, to: theirs)
                .intersection(ours)
                .filter { !SettingsDocument.equal(mine[$0], theirs[$0]) }
            // Their changes land on top of ours; anything we changed and they
            // did not is still unwritten here and survives to the next save.
            let object = SettingsDocument.merge(baseline: Self.baseline, mine: theirs, theirs: mine)
            Self.baseline = theirs
            adopted = (object, conflicts.sorted())
        }

        guard
            let adopted,
            let data = try? SettingsDocument.data(from: adopted.object),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return }

        isAdoptingExternalChange = true
        settings = Self.migrated(decoded)
        isAdoptingExternalChange = false

        replacedByAnotherWriter = adopted.conflicts.isEmpty
            ? nil
            : ExternalSettingsChange(replacedKeys: adopted.conflicts, observedAt: Date())
    }

    /// Dismiss the notice, once the user has seen it.
    public func acknowledgeExternalChange() {
        replacedByAnotherWriter = nil
    }

    private func persist() {
        Self.write(settings, sequence: nil)
    }

    /// `sequence == nil` (load-time migration writes) always applies.
    ///
    /// Writes what this process changed, not everything it holds. A whole-file
    /// rewrite from a decoded `AppSettings` deletes every key the writer did
    /// not know — another client's settings, or a newer build's — and the loss
    /// only shows up later as a setting that quietly reverted.
    private nonisolated static func write(_ settings: AppSettings, sequence: UInt64?) {
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
            let changed = SettingsDocument.changedKeys(
                from: baseline, to: mine, owned: ownedKeys(writing: mine)
            )
            editedKeys.formUnion(SettingsDocument.changedKeys(from: lastMine, to: mine))
            lastMine = mine
            var merged = theirs
            for key in changed {
                if let value = mine[key] { merged[key] = value } else { merged.removeValue(forKey: key) }
            }
            do {
                try VibeBarLocalStore.writeData(
                    SettingsDocument.data(from: merged), to: fileURL,
                    base: fileURL.deletingLastPathComponent()
                )
                baseline = merged
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
