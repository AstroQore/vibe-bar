import Foundation

public enum VibeBarLocalStore {
    public static let directoryName = ".vibebar"

    public static var baseDirectory: URL {
        RealHomeDirectory.url
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static var settingsURL: URL {
        baseDirectory.appendingPathComponent("settings.json")
    }

    // Legacy plaintext cookie paths from short-lived builds. Current code
    // migrates these into Keychain and deletes them; do not write new cookies
    // here.
    public static var claudeCookieURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("claude-web.txt")
    }

    public static var claudeWebViewCookieURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("claude-webview.txt")
    }

    public static var claudeBrowserCookieURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("claude-browser.txt")
    }

    public static var openAIWebViewCookieURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("openai-webview.txt")
    }

    public static var openAIBrowserCookieURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("openai-browser.txt")
    }

    public static var claudeOrganizationIDURL: URL {
        baseDirectory
            .appendingPathComponent("cookies", isDirectory: true)
            .appendingPathComponent("claude-organization-id.txt")
    }

    public static var quotaDirectory: URL {
        baseDirectory.appendingPathComponent("quotas", isDirectory: true)
    }

    public static var costSnapshotDirectory: URL {
        baseDirectory.appendingPathComponent("cost_snapshots", isDirectory: true)
    }

    public static var costHistoryURL: URL {
        baseDirectory.appendingPathComponent("cost_history.json")
    }

    public static var subscriptionHistoryURL: URL {
        baseDirectory.appendingPathComponent("subscription_history.json")
    }

    public static var fillTimelineURL: URL {
        baseDirectory.appendingPathComponent("fill_timeline.json")
    }

    /// Companion to `fillTimelineURL`: what the pace forecast predicted at each
    /// observation, so the history chart can draw the projection that was
    /// actually shown instead of recomputing it with hindsight.
    public static var forecastTimelineURL: URL {
        baseDirectory.appendingPathComponent("forecast_timeline.json")
    }

    /// Per-page card layout chosen in the layout editor: column ratio, the two
    /// ordered module columns, and last-known measured card heights. Kept out
    /// of `AppSettings` because render-time height measurement writes here.
    public static var pageLayoutURL: URL {
        baseDirectory.appendingPathComponent("layout.json")
    }

    /// Mini-window geometry is persisted out-of-band from `AppSettings` so a
    /// drag-to-move (which fires didMove repeatedly) doesn't rewrite the
    /// whole settings JSON or fan out through every Combine subscriber on
    /// `SettingsStore.$settings`.
    public static var miniWindowGeometryURL: URL {
        baseDirectory.appendingPathComponent("mini_window_geometry.json")
    }

    /// Non-secret workspace, Relay, and registered Probe metadata. Relay
    /// bearer credentials and Core private keys live in the credential Vault.
    public static var remoteCoreConfigURL: URL {
        baseDirectory.appendingPathComponent("remote_core.json")
    }

    /// Source-aware remote event ledger and consumer cursor. This is separate
    /// from `cost_history.json`: max-merged daily totals cannot represent
    /// multiple producers or replay safely.
    public static var remoteUsageLedgerURL: URL {
        baseDirectory.appendingPathComponent("remote_usage.sqlite3")
    }

    /// Per-request local usage ledger written by `UsageEventLedger`. Kept
    /// apart from `remote_usage.sqlite3` (other machines' facts) and from
    /// the per-file scan cache (parse results, not query-able history).
    public static var usageEventsLedgerURL: URL {
        baseDirectory.appendingPathComponent("usage_events.sqlite3")
    }

    public static func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public static func writeData(_ data: Data, to url: URL) throws {
        try ensureBaseDirectory()
        let parent = url.deletingLastPathComponent()
        if parent.path != baseDirectory.path {
            try ensureDirectory(parent)
        }
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func readString(from url: URL) throws -> String {
        let data = try readData(from: url)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return string
    }

    public static func writeString(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeData(data, to: url)
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try readData(from: url)
        return try JSONDecoder().decode(type, from: data)
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try writeData(data, to: url)
    }

    public static func deleteFile(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    public static func ensureBaseDirectory() throws {
        try ensureDirectory(baseDirectory)
    }

    public static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func safeFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return cleaned.isEmpty ? "default" : cleaned
    }
}
