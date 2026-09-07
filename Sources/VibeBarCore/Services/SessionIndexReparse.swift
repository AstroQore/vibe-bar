import Foundation
import SQLite3

/// Re-reads one provider's session files after a parser upgrade.
///
/// The index skips a file whose size and modification time have not moved,
/// which is what makes a refresh cheap and what makes a *parser* fix
/// invisible: nothing about the file changed, so a better reading of it is
/// never asked for. Deleting the provider's rows from `session_files` drops
/// only those cursors, and the next indexing pass reads those files again
/// and rewrites what they say.
///
/// The kit's index is derived data whose path this app chose, so trimming it
/// is the host's business — the same licence `SessionIndexCompactor` works
/// under. This deletes cursors, never sessions or messages, so nothing
/// disappears from the Workbench in the meantime.
public enum SessionIndexReparse {
    /// Bump when a kit upgrade changes what a provider's already-indexed
    /// rows should say.
    ///
    /// v1, with kit 0.8.1: an AntiGravity session takes its title from the
    /// user's own first prompt instead of falling back to the file's name,
    /// and its user steps became user messages. Every conversation already
    /// on disk was indexed under the old reading.
    public static let currentVersion = 1
    /// Providers to re-read, as `SessionSummary.provider` spells them.
    public static let providers = ["antigravity"]

    public struct Outcome: Equatable, Sendable {
        public let version: Int
        public let cursorsDropped: Int
    }

    private struct Stamp: Codable {
        var version: Int
    }

    /// Behind the maintenance gate, which is what keeps this off an
    /// indexing pass already walking the same files: that pass can skip a
    /// file on the cursor this is about to delete and finish just after,
    /// leaving the conversation on the old reading until the next refresh.
    /// A gate that cannot be claimed leaves the stamp alone, so the next
    /// launch tries again.
    @discardableResult
    public static func runIfNeededBehindGate(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexReparseStampURL,
        version: Int = SessionIndexReparse.currentVersion,
        providers: [String] = SessionIndexReparse.providers,
        gate: SessionIndexMaintenanceGate = .shared
    ) async -> Outcome? {
        do { try await gate.acquire() } catch { return nil }
        let outcome = runIfNeeded(databaseURL: databaseURL, stampURL: stampURL,
                                  version: version, providers: providers)
        await gate.release()
        return outcome
    }

    /// Run once per version. Returns what it did, or nil when the stamp is
    /// current, the index does not exist yet, or the database refused — and
    /// a refusal leaves the stamp alone, so the next launch tries again.
    @discardableResult
    public static func runIfNeeded(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexReparseStampURL,
        version: Int = SessionIndexReparse.currentVersion,
        providers: [String] = SessionIndexReparse.providers
    ) -> Outcome? {
        let applied = (try? VibeBarLocalStore.readJSON(Stamp.self, from: stampURL))?.version ?? 0
        guard applied < version else { return nil }
        // No index yet is the good case: whatever is scanned next is scanned
        // by the new parser. Stamp it so this never runs on that database.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            try? VibeBarLocalStore.writeJSON(Stamp(version: version), to: stampURL)
            return nil
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = handle
        else {
            if handle != nil { sqlite3_close_v2(handle) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 5_000)
        let before = sqlite3_total_changes64(database)
        for provider in providers {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "DELETE FROM session_files WHERE provider = ?1", -1,
                                     &statement, nil) == SQLITE_OK, let statement else { return nil }
            sqlite3_bind_text(statement, 1, provider, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let step = sqlite3_step(statement)
            sqlite3_finalize(statement)
            // A busy database is the ordinary case — an index refresh is
            // running — and it is why this must not stamp: a stamp written
            // over a delete that never happened leaves those files under the
            // old parser for good. Leave it for the next launch.
            guard step == SQLITE_DONE else {
                SafeLog.info("Session index reparse v\(version) deferred: \(provider) delete returned \(step)")
                return nil
            }
        }
        let dropped = Int(sqlite3_total_changes64(database) - before)
        // Every delete ran, so the stamp is earned. A provider with nothing
        // indexed drops nothing and is equally done.
        try? VibeBarLocalStore.writeJSON(Stamp(version: version), to: stampURL)
        SafeLog.info("Session index reparse v\(version): dropped \(dropped) cursor(s) for \(providers.joined(separator: ", "))")
        return Outcome(version: version, cursorsDropped: dropped)
    }
}
