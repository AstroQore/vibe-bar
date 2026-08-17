import Foundation
import SQLite3

/// Read helpers for another app's SQLite store while that app is running.
///
/// AntiGravity's conversation databases and Cursor's agent stores are both
/// written by processes that may be running right now, so they routinely
/// carry a live `-wal` / `-shm` pair. That rules out `immutable=1` — the flag
/// tells SQLite there is no journal to replay, which on a live database means
/// reading a stale or torn snapshot.
///
/// The strategy is therefore: open the real file read-only with a short busy
/// timeout and, only if that fails to produce a complete read, snapshot the
/// file (plus its journal siblings) into a private temp directory and read the
/// copy. The copy is deleted before returning. Nothing here ever opens the
/// original for writing.
enum LiveSQLiteReader {
    enum ReadError: Error {
        case statement
    }

    /// Maximum rows any single query here will materialize. A conversation
    /// with more rows than this is pathological; truncating keeps a session
    /// list from allocating without bound.
    static let maxRows = 5_000
    /// Individual payload blobs are a few KB; anything past this is not a
    /// transcript and is skipped rather than copied into memory.
    static let maxBlobBytes = 4 * 1024 * 1024

    /// Run `body` against a read-only handle on `url`, falling back to a
    /// snapshot copy. Returns `nil` when neither route produced a result;
    /// `body` must build its output from scratch so a retry is clean.
    static func read<T>(at url: URL, _ body: (OpaquePointer) throws -> T) -> T? {
        if let handle = open(path: url.path) {
            defer { sqlite3_close_v2(handle) }
            if let value = try? body(handle) { return value }
        }
        guard let snapshot = snapshot(of: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }

        // The copy is ours, so a read-write open is allowed to replay the
        // copied WAL. `immutable=1` is the last resort, for a copy whose
        // journal siblings were not readable either.
        if let handle = open(path: snapshot.path, readOnly: false) {
            defer { sqlite3_close_v2(handle) }
            if let value = try? body(handle) { return value }
        }
        guard let handle = open(path: "file:\(snapshot.path)?immutable=1", uri: true) else {
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        return try? body(handle)
    }

    private static func open(path: String, readOnly: Bool = true, uri: Bool = false) -> OpaquePointer? {
        var handle: OpaquePointer?
        var flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        if uri { flags |= SQLITE_OPEN_URI }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if handle != nil { sqlite3_close_v2(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 250)
        return handle
    }

    /// Copy `url` and its `-wal` / `-shm` siblings into a fresh temp
    /// directory. The directory (not just the file) is unique so a
    /// concurrent refresh can never collide, and the caller removes it.
    private static func snapshot(of url: URL) -> URL? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("VibeBarLiveSQLiteSnapshot-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let target = directory.appendingPathComponent(url.lastPathComponent)
        guard (try? fm.copyItem(at: url, to: target)) != nil else {
            try? fm.removeItem(at: directory)
            return nil
        }
        for suffix in ["-wal", "-shm"] {
            let sibling = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix)
            guard fm.fileExists(atPath: sibling.path) else { continue }
            try? fm.copyItem(
                at: sibling,
                to: directory.appendingPathComponent(target.lastPathComponent + suffix)
            )
        }
        return target
    }

    // MARK: - Statements

    static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if statement != nil { sqlite3_finalize(statement) }
            throw ReadError.statement
        }
        return statement
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let raw = sqlite3_column_blob(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, length <= maxBlobBytes else { return nil }
        return Data(bytes: raw, count: length)
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
