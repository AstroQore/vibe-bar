import Foundation
import SQLite3

/// What a Claude Code session is called.
///
/// The kit names a Claude session from its transcript alone: a pinned
/// `custom-title` line, else the first prompt, else the project folder. The
/// Claude desktop app keeps its own title — the one in its sidebar, written
/// by the app or by the user — in a metadata file beside the transcript, and
/// for a desktop session that is the name the user knows it by. The kit
/// never reads it, so about half the desktop sessions showed a raw first
/// prompt or a bare folder name instead.
///
/// The first prompt is also not always something the user typed: a turn can
/// open with an injected `<system-reminder>` block or a `<pasted_content>`
/// wrapper, and the kit's title keeps that markup.
public enum ClaudeSessionTitle {
    /// The title a row should carry: the desktop app's title when there is
    /// one, otherwise the transcript's own title with injected markup taken
    /// off. Idempotent, so running it over a row it already fixed changes
    /// nothing.
    public static func resolved(current: String?, projectDir: String?, desktopTitle: String?) -> String? {
        if let desktop = SessionParsing.display(desktopTitle, limit: SessionParsing.titleLimit) {
            return desktop
        }
        return cleaned(current, projectDir: projectDir)
    }

    static let systemReminderOpen = "<system-reminder>"
    static let systemReminderClose = "</system-reminder>"
    static let pastedOpen = "<pasted_content"
    static let pastedClose = "</pasted_content>"

    /// The transcript title without a leading injected block. A system
    /// reminder is dropped whole — it is never the user's words — and when
    /// nothing of the prompt survives the title's length cut, the folder
    /// name stands in, as the kit's own fallback does. A paste is the user's
    /// own text, so only its wrapper goes.
    static func cleaned(_ title: String?, projectDir: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(systemReminderOpen) {
            if let close = trimmed.range(of: systemReminderClose) {
                let rest = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return cleaned(rest, projectDir: projectDir) }
            }
            return folderName(projectDir)
        }
        if trimmed.hasPrefix(pastedOpen), let close = trimmed.firstIndex(of: ">") {
            let rest = String(trimmed[trimmed.index(after: close)...])
                .replacingOccurrences(of: pastedClose, with: " ")
                .trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? folderName(projectDir) : SessionParsing.display(rest, limit: SessionParsing.titleLimit)
        }
        return title
    }

    private static func folderName(_ projectDir: String?) -> String? {
        guard let projectDir, !projectDir.isEmpty else { return nil }
        let name = URL(fileURLWithPath: projectDir).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

/// The Claude desktop app's session titles, by Claude Code session id.
///
/// The app writes one `local_<id>.json` per session under
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`.
/// Only three fields are taken from it: `cliSessionId` and
/// `lastAssistantCliSessionId` (the transcript ids the session has run
/// under) and `title`. Nothing is written there.
///
/// A couple of thousand files, some of them hundreds of kilobytes, so they
/// are parsed once and then again only when their modification date moves;
/// a rescan inside `minimumInterval` returns the last answer without
/// touching the disk.
public final class ClaudeDesktopTitleLookup: @unchecked Sendable {
    public static let shared = ClaudeDesktopTitleLookup()

    public static var defaultRoot: URL {
        RealHomeDirectory.url
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    struct Entry: Equatable {
        let modified: Date
        let ids: [String]
        let title: String?
    }

    private let root: URL
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var titles: [String: String] = [:]
    private var scannedAt: Date?
    private var generation: UInt64 = 0

    public init(root: URL = ClaudeDesktopTitleLookup.defaultRoot, minimumInterval: TimeInterval = 30) {
        self.root = root
        self.minimumInterval = minimumInterval
    }

    /// The desktop title of one Claude Code session, if the app has one.
    public func title(forSessionID sessionID: String) -> String? {
        snapshot().titles[sessionID.lowercased()]
    }

    /// Every known title, keyed by lowercased session id, with a counter
    /// that moves whenever any of them changed.
    public func snapshot(now: Date = Date()) -> (generation: UInt64, titles: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        if let scannedAt, now.timeIntervalSince(scannedAt) < minimumInterval {
            return (generation, titles)
        }
        rescan()
        scannedAt = now
        return (generation, titles)
    }

    /// Lock held. Stats every metadata file; parses the new and the moved.
    private func rescan() {
        var next: [String: Entry] = [:]
        for file in Self.metadataFiles(under: root) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let known = entries[file.path], known.modified == modified {
                next[file.path] = known
            } else if let parsed = Self.parse(file, modified: modified) {
                next[file.path] = parsed
            }
        }
        guard next != entries else { return }
        entries = next
        // A transcript id that two desktop sessions both name (a fork that
        // kept its parent's id) takes the more recently written title.
        var byID: [String: (title: String, modified: Date)] = [:]
        for entry in next.values {
            guard let title = entry.title else { continue }
            for id in entry.ids where (byID[id]?.modified ?? .distantPast) <= entry.modified {
                byID[id] = (title, entry.modified)
            }
        }
        let rebuilt = byID.mapValues(\.title)
        if rebuilt != titles {
            titles = rebuilt
            generation &+= 1
        }
    }

    /// `<root>/<account>/<org>/local_*.json`, without following symlinks.
    static func metadataFiles(under root: URL) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        func children(_ url: URL) -> [URL] {
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        func isPlainDirectory(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
        var out: [URL] = []
        for account in children(root) where isPlainDirectory(account) {
            for org in children(account) where isPlainDirectory(org) {
                for file in children(org)
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    let link = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                    if !link { out.append(file) }
                }
            }
        }
        return out
    }

    static func parse(_ file: URL, modified: Date) -> Entry? {
        guard let object = SessionParsing.jsonObject(at: file) else { return nil }
        let ids = [object["cliSessionId"], object["lastAssistantCliSessionId"]]
            .compactMap { SessionParsing.string($0)?.lowercased() }
        guard !ids.isEmpty else { return nil }
        let title = SessionParsing.string(object["title"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(
            modified: modified,
            ids: Array(Set(ids)).sorted(),
            title: (title?.isEmpty ?? true) ? nil : title
        )
    }
}

/// The index-time half: a Claude row read from its transcript gets the
/// resolved title before it is written, so a re-index never undoes what the
/// sync pass set.
public enum ClaudeTitleRepair {
    public static func repaired(
        _ summary: SessionSummary,
        lookup: ClaudeDesktopTitleLookup = .shared
    ) -> SessionSummary {
        guard summary.provider == .claude else { return summary }
        let title = ClaudeSessionTitle.resolved(
            current: summary.title,
            projectDir: summary.projectDir,
            desktopTitle: lookup.title(forSessionID: summary.sessionID)
        )
        return title == summary.title ? summary : summary.replacingTitle(title)
    }
}

/// The after-refresh half: rows already in the index are brought in line
/// with the desktop app's current titles, including ones the app named or
/// the user renamed after the transcript was last read — a rename does not
/// touch the transcript, so the indexer would never look again.
///
/// Rewrites `sessions.title` only, and only where it differs. Title search
/// reads that column directly (`LIKE`), so a renamed session is found by its
/// new name at once. Runs behind the maintenance gate, inside the refresh
/// pass, like the other host-side trims of the kit's index.
public enum ClaudeTitleSync {
    @discardableResult
    public static func run(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        titles: [String: String]
    ) -> Int {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            return 0
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 5_000)

        var changes: [(row: Int64, title: String?)] = []
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                                 "SELECT id, session_id, title, project_dir FROM sessions WHERE provider = 'claude'",
                                 -1, &select, nil) == SQLITE_OK, let select
        else { return 0 }
        while sqlite3_step(select) == SQLITE_ROW {
            let row = sqlite3_column_int64(select, 0)
            guard let sessionID = text(select, 1) else { continue }
            let current = text(select, 2)
            let wanted = ClaudeSessionTitle.resolved(
                current: current,
                projectDir: text(select, 3),
                desktopTitle: titles[sessionID.lowercased()]
            )
            if wanted != current { changes.append((row, wanted)) }
        }
        sqlite3_finalize(select)
        guard !changes.isEmpty else { return 0 }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return 0 }
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE sessions SET title = ?1 WHERE id = ?2", -1, &update, nil) == SQLITE_OK,
              let update
        else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            return 0
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var written = 0
        for change in changes {
            sqlite3_reset(update)
            if let title = change.title {
                sqlite3_bind_text(update, 1, title, -1, transient)
            } else {
                sqlite3_bind_null(update, 1)
            }
            sqlite3_bind_int64(update, 2, change.row)
            guard sqlite3_step(update) == SQLITE_DONE else {
                sqlite3_finalize(update)
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                return 0
            }
            written += 1
        }
        sqlite3_finalize(update)
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            return 0
        }
        SafeLog.info("Claude title sync: \(written) row(s) retitled")
        return written
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}

extension SessionSummary {
    /// The same row under another title. Field-by-field for the same reason
    /// as `replacingProviderVariant`.
    func replacingTitle(_ newTitle: String?) -> SessionSummary {
        SessionSummary(
            provider: provider,
            sessionID: sessionID,
            providerVariant: providerVariant,
            harness: harness,
            model: model,
            title: newTitle,
            summary: summary,
            projectDir: projectDir,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sourcePath: sourcePath,
            sizeBytes: sizeBytes,
            messageCount: messageCount
        )
    }
}
