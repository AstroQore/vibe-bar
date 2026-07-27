import Foundation

/// Persists the *measured height* of every card the popover has drawn, per
/// page.
///
/// This is render-time telemetry, not a preference: it changes whenever a card
/// grows a row, a chart gains a series, or the popover is resized. It lives in
/// its own file for the same reason mini-window geometry does (`AGENTS.md`
/// § 11) — every `AppSettings` write fans out to every Combine subscriber, and
/// this one churns. The user's actual layout *intent* — column order and width
/// split — belongs to the user, so it rides in `AppSettings.pageLayouts`.
///
/// The layout editor is why the heights are persisted at all: it draws each
/// card as a proportional block, and a page the user has not opened this
/// session has reported nothing. Without a last-known value every card would be
/// the same featureless rectangle.
///
/// Writes are throttled — a resizing popover must not rewrite the file on every
/// layout pass — and values within 0.5 pt of what is already stored are not
/// even considered a change. An explicit reset persists immediately.
///
/// File: `~/.vibebar/layout.json` (mode 0600).
public actor PageLayoutStore {
    public static let shared = PageLayoutStore()

    /// One page's measurements.
    ///
    /// Decoding ignores every other key, which is what makes a file written by
    /// the build that also kept `ratio` / `columns` here still readable: those
    /// fields moved to `AppSettings` and are dropped on the next write. The
    /// feature is unreleased, so there is nothing to migrate — this is
    /// tolerance for a developer's stale file, not a migration.
    private struct PageEntry: Codable {
        var measuredHeights: [PageLayoutModuleID: Double]

        init(measuredHeights: [PageLayoutModuleID: Double] = [:]) {
            self.measuredHeights = Self.sanitized(measuredHeights)
        }

        private enum CodingKeys: String, CodingKey {
            case measuredHeights
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let heights = (try? container.decode(
                [PageLayoutModuleID: Double].self,
                forKey: .measuredHeights
            )) ?? [:]
            self.init(measuredHeights: heights)
        }

        var isEmpty: Bool { measuredHeights.isEmpty }

        static func sanitized(
            _ heights: [PageLayoutModuleID: Double]
        ) -> [PageLayoutModuleID: Double] {
            heights.filter { $0.value.isFinite && $0.value > 0 }
        }
    }

    private struct Storage: Codable {
        var schemaVersion: Int
        var pages: [PageLayoutPageID: PageEntry]

        init(
            schemaVersion: Int = PageLayoutStore.storageSchemaVersion,
            pages: [PageLayoutPageID: PageEntry] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.pages = pages
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case pages
        }

        /// Decoded page by page so one unreadable entry costs that page only,
        /// not the whole file. `PageEntry`'s own decoder is already tolerant,
        /// so this is belt-and-braces for a hand-edited file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1

            var pages: [PageLayoutPageID: PageEntry] = [:]
            if let pagesContainer = try? container.nestedContainer(
                keyedBy: PageLayoutStringCodingKey.self,
                forKey: .pages
            ) {
                for key in pagesContainer.allKeys {
                    guard let entry = try? pagesContainer.decode(PageEntry.self, forKey: key) else {
                        continue
                    }
                    pages[PageLayoutPageID(rawValue: key.stringValue)] = entry
                }
            }
            self.pages = pages
        }
    }

    private let fileURL: URL
    private var cachedStorage: Storage?
    private var lastSavedAt: Date?
    private var pendingFlushTask: Task<Void, Never>?
    private var pendingStorage: Storage?

    static let storageSchemaVersion = 1
    /// Height churn only. An explicit reset bypasses this entirely.
    private static let saveThrottleInterval: TimeInterval = 5
    /// Sub-pixel wobble from SwiftUI's measurement is noise, not a layout
    /// change; ignoring it keeps the file from being rewritten every render.
    private static let heightChangeEpsilon: Double = 0.5
    /// Defensive cap only. A real layout file is a few kilobytes; anything past
    /// this is corruption, not a legitimate record.
    private static let maxFileBytes = 4 * 1024 * 1024

    public init(fileURL: URL = PageLayoutStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.pageLayoutURL
    }

    // MARK: - Public API

    /// Last-known rendered height of every card on a page. Empty for a page
    /// that has never been drawn.
    public func measuredHeights(for page: PageLayoutPageID) -> [PageLayoutModuleID: Double] {
        load().pages[page]?.measuredHeights ?? [:]
    }

    public func allMeasuredHeights() -> [PageLayoutPageID: [PageLayoutModuleID: Double]] {
        load().pages.compactMapValues { $0.isEmpty ? nil : $0.measuredHeights }
    }

    /// Merge freshly measured card heights into a page's record. Non-positive
    /// and non-finite values are ignored, as are changes of 0.5 pt or less.
    public func updateMeasuredHeights(
        _ heights: [PageLayoutModuleID: Double],
        for page: PageLayoutPageID
    ) {
        let sanitized = PageEntry.sanitized(heights)
        guard !sanitized.isEmpty else { return }

        var storage = load()
        var entry = storage.pages[page] ?? PageEntry()
        var changed = false
        for (moduleID, height) in sanitized {
            if let existing = entry.measuredHeights[moduleID],
               abs(existing - height) <= Self.heightChangeEpsilon {
                continue
            }
            entry.measuredHeights[moduleID] = height
            changed = true
        }
        guard changed else { return }
        storage.pages[page] = entry
        save(storage, immediate: false)
    }

    /// Forget one page's measurements, so the editor falls back to per-family
    /// stand-in heights until the page is drawn again. Paired with dropping the
    /// page from `AppSettings.pageLayouts` by "Restore Defaults".
    public func clearMeasuredHeights(for page: PageLayoutPageID) {
        var storage = load()
        guard storage.pages.removeValue(forKey: page) != nil else { return }
        save(storage, immediate: true)
    }

    public func eraseAll() {
        cachedStorage = Storage()
        pendingStorage = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        lastSavedAt = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func flushPendingWrites() async {
        if let storage = pendingStorage {
            persist(storage)
            pendingStorage = nil
            lastSavedAt = Date()
        }
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
    }

    // MARK: - Private

    private func load() -> Storage {
        if let cached = cachedStorage { return cached }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = (attributes[.size] as? NSNumber)?.intValue,
           size > Self.maxFileBytes {
            let empty = Storage()
            cachedStorage = empty
            return empty
        }
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            let empty = Storage()
            cachedStorage = empty
            return empty
        }
        if storage.schemaVersion > Self.storageSchemaVersion {
            // Written by a newer build. Its page entries may mean something
            // else entirely; start clean rather than guess.
            let empty = Storage()
            persist(empty)
            cachedStorage = empty
            return empty
        }
        var migrated = storage
        if migrated.schemaVersion < Self.storageSchemaVersion {
            migrated.schemaVersion = Self.storageSchemaVersion
            persist(migrated)
        }
        cachedStorage = migrated
        return migrated
    }

    private func save(_ storage: Storage, immediate: Bool) {
        cachedStorage = storage
        let now = Date()
        if !immediate,
           let last = lastSavedAt,
           now.timeIntervalSince(last) < Self.saveThrottleInterval {
            pendingStorage = storage
            scheduleFlush(after: Self.saveThrottleInterval - now.timeIntervalSince(last))
            return
        }
        persist(storage)
        pendingStorage = nil
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        lastSavedAt = now
    }

    private func persist(_ storage: Storage) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(storage) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func scheduleFlush(after delay: TimeInterval) {
        if pendingFlushTask != nil { return }
        let nanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.flushPendingWrites()
        }
    }
}
