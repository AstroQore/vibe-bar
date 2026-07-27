import Foundation

/// Persists the per-page card layout the user built in the layout editor.
///
/// One entry per page; pages the user never touched simply have no entry and
/// keep the built-in arrangement (see `PageLayoutResolver`). Two write paths
/// with deliberately different urgency:
///
/// - `setConfig` / `resetConfig` are explicit user edits and persist
///   immediately, so quitting right after a drag cannot lose the change.
/// - `updateMeasuredHeights` fires from render-time measurement and is
///   throttled, so a resizing popover does not rewrite the file on every
///   layout pass. Values within 0.5 pt of what is already stored are not even
///   considered a change.
///
/// File: `~/.vibebar/layout.json` (mode 0600).
public actor PageLayoutStore {
    public static let shared = PageLayoutStore()

    private struct Storage: Codable {
        var schemaVersion: Int
        var pages: [PageLayoutPageID: PageLayoutConfig]

        init(
            schemaVersion: Int = PageLayoutStore.storageSchemaVersion,
            pages: [PageLayoutPageID: PageLayoutConfig] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.pages = pages
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case pages
        }

        /// Decoded page by page so one unreadable entry costs that page only,
        /// not the whole file. `PageLayoutConfig`'s own decoder is already
        /// field-tolerant, so this is belt-and-braces for a hand-edited file.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1

            var pages: [PageLayoutPageID: PageLayoutConfig] = [:]
            if let pagesContainer = try? container.nestedContainer(
                keyedBy: PageLayoutStringCodingKey.self,
                forKey: .pages
            ) {
                for key in pagesContainer.allKeys {
                    guard let config = try? pagesContainer.decode(PageLayoutConfig.self, forKey: key) else {
                        continue
                    }
                    pages[PageLayoutPageID(rawValue: key.stringValue)] = config
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
    /// Height churn only. Explicit edits bypass this entirely.
    private static let saveThrottleInterval: TimeInterval = 5
    /// Sub-pixel wobble from SwiftUI's measurement is noise, not a layout
    /// change; ignoring it keeps the file from being rewritten every render.
    private static let heightChangeEpsilon: Double = 0.5
    /// Defensive cap only. A real layout file is a few kilobytes; anything past
    /// this is corruption, not a legitimate arrangement.
    private static let maxFileBytes = 4 * 1024 * 1024

    public init(fileURL: URL = PageLayoutStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        try? VibeBarLocalStore.ensureBaseDirectory()
        return VibeBarLocalStore.pageLayoutURL
    }

    // MARK: - Public API

    /// The saved entry for a page, or `nil` when the user has never customized
    /// it. Note that an entry can exist with empty columns — that is a
    /// heights-only record; `PageLayoutConfig.isEmpty` distinguishes it.
    public func config(for page: PageLayoutPageID) -> PageLayoutConfig? {
        load().pages[page]
    }

    public func setConfig(_ config: PageLayoutConfig, for page: PageLayoutPageID) {
        let normalized = PageLayoutConfig(
            ratio: config.ratio,
            columns: config.columns,
            measuredHeights: config.measuredHeights
        )
        var storage = load()
        guard storage.pages[page] != normalized else { return }
        storage.pages[page] = normalized
        save(storage, immediate: true)
    }

    /// Merge freshly measured card heights into a page's record, creating a
    /// heights-only entry if the page has no saved layout yet. Non-positive and
    /// non-finite values are ignored, as are changes of 0.5 pt or less.
    public func updateMeasuredHeights(
        _ heights: [PageLayoutModuleID: Double],
        for page: PageLayoutPageID
    ) {
        let sanitized = heights.filter { $0.value.isFinite && $0.value > 0 }
        guard !sanitized.isEmpty else { return }

        var storage = load()
        var config = storage.pages[page] ?? PageLayoutConfig()
        var changed = false
        for (moduleID, height) in sanitized {
            if let existing = config.measuredHeights[moduleID],
               abs(existing - height) <= Self.heightChangeEpsilon {
                continue
            }
            config.measuredHeights[moduleID] = height
            changed = true
        }
        guard changed else { return }
        storage.pages[page] = config
        save(storage, immediate: false)
    }

    /// Forget everything saved for one page — layout and measured heights — so
    /// it falls back to the built-in arrangement.
    public func resetConfig(for page: PageLayoutPageID) {
        var storage = load()
        guard storage.pages.removeValue(forKey: page) != nil else { return }
        save(storage, immediate: true)
    }

    public func allConfigs() -> [PageLayoutPageID: PageLayoutConfig] {
        load().pages
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
