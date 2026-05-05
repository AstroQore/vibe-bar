import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet { persist() }
    }

    private let defaultsKey = "VibeBar.settings.v1"

    public init(userDefaults: UserDefaults = .standard) {
        if
            let decoded = try? VibeBarLocalStore.readJSON(AppSettings.self, from: VibeBarLocalStore.settingsURL)
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
    }

    private func persist() {
        do {
            try VibeBarLocalStore.writeJSON(settings, to: VibeBarLocalStore.settingsURL)
        } catch {
            SafeLog.warn("Saving settings failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }

    private static func migrated(_ settings: AppSettings) -> AppSettings {
        var migrated = settings
        migrated.mockEnabled = false
        if migrated.refreshIntervalSeconds == 300 {
            migrated.refreshIntervalSeconds = AppSettings.default.refreshIntervalSeconds
        }
        // Claude bucket IDs were renamed when Daily Routines moved out of the
        // headline weekly group. Rewrite stale field IDs in-place so the user
        // doesn't have to re-pick everything in Settings.
        let bucketIdMigrations: [String: String?] = [
            "claude.weekly_cowork":      "claude.daily_routines",
            "claude.design_promotional": nil,    // dropped — never showed up in real responses
            "claude.extra_usage":        nil     // promoted out of buckets, surfaced as ProviderExtras now
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
    public var mockEnabled: Bool {
        get { settings.mockEnabled }
        set { settings.mockEnabled = false }
    }
    public var claudeUsageMode: ClaudeUsageMode {
        get { settings.claudeUsageMode }
        set { settings.claudeUsageMode = newValue }
    }
    public var launchAtLogin: Bool {
        get { settings.launchAtLogin }
        set { settings.launchAtLogin = newValue }
    }
}
