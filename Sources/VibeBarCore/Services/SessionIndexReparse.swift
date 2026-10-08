import Foundation
import SQLite3

/// Re-reads already-indexed session files after a parser upgrade.
///
/// The index skips a file whose size and modification time have not moved,
/// which is what makes a refresh cheap and what makes a *parser* fix
/// invisible: nothing about the file changed, so a better reading of it is
/// never asked for. Deleting rows from `session_files` — a provider's, or
/// just the ones a fix concerns — drops only those cursors, and the next
/// indexing pass reads those files again and rewrites what they say.
///
/// The kit's index is derived data whose path this app chose, so trimming it
/// is the host's business — the same licence `SessionIndexCompactor` works
/// under. This deletes cursors, never sessions or messages, so nothing
/// disappears from the Workbench in the meantime.
public enum SessionIndexReparse {
    /// Bump when a kit upgrade — or a host-side correction of what an adapter
    /// returns — changes what already-indexed rows should say, and add the
    /// matching entry to `steps`.
    ///
    /// v1, with kit 0.8.1: an AntiGravity session takes its title from the
    /// user's own first prompt instead of falling back to the file's name,
    /// and its user steps became user messages. Every conversation already
    /// on disk was indexed under the old reading.
    ///
    /// v2: `CodexReviewLinkRepair` re-points Auto Review rollouts that the
    /// kit linked to themselves (Codex before 0.142). Only those rows are
    /// re-read — a few hundred files, not the whole Codex tree.
    public static let currentVersion = 2
    /// Providers re-read whole by v1, as `SessionSummary.provider` spells them.
    public static let providers = ["antigravity"]

    /// Cursors to drop that are picked out by what the row says rather than
    /// by provider.
    public enum TargetedDrop: String, Sendable, Equatable {
        /// Codex rows whose Auto Review variant names the row itself.
        case codexSelfLinkedAutoReviews

        /// One `DELETE` whose only parameter is a `LIKE` pattern. Joined
        /// through `session_files.session_row`, which every cursor the kit
        /// writes carries.
        var sql: String {
            switch self {
            case .codexSelfLinkedAutoReviews:
                """
                DELETE FROM session_files WHERE session_row IN (
                    SELECT id FROM sessions
                     WHERE provider = 'codex'
                       AND provider_variant LIKE ?1 ESCAPE '\\'
                       AND substr(provider_variant, \(CodexSessionAdapter.autoReviewVariantPrefix.utf8.count + 1))
                           = session_id)
                """
            }
        }

        var pattern: String {
            switch self {
            case .codexSelfLinkedAutoReviews:
                SessionReviewIndex.likePrefix(CodexSessionAdapter.autoReviewVariantPrefix)
            }
        }
    }

    /// One version's worth of re-reading.
    public struct Step: Sendable, Equatable {
        public let version: Int
        /// Providers whose every cursor goes.
        public let providers: [String]
        /// Narrower drops, for a fix that touches a few rows of a large tree.
        public let targeted: [TargetedDrop]

        public init(version: Int, providers: [String] = [], targeted: [TargetedDrop] = []) {
            self.version = version
            self.providers = providers
            self.targeted = targeted
        }
    }

    /// Every version, in order. A launch runs the ones newer than its stamp.
    public static let steps: [Step] = [
        Step(version: 1, providers: providers),
        Step(version: 2, targeted: [.codexSelfLinkedAutoReviews])
    ]

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
        steps: [Step] = SessionIndexReparse.steps,
        gate: SessionIndexMaintenanceGate = .shared
    ) async -> Outcome? {
        do { try await gate.acquire() } catch { return nil }
        let outcome = runIfNeeded(databaseURL: databaseURL, stampURL: stampURL, steps: steps)
        await gate.release()
        return outcome
    }

    /// A single whole-provider step, for callers that name one version.
    @discardableResult
    public static func runIfNeededBehindGate(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexReparseStampURL,
        version: Int,
        providers: [String] = SessionIndexReparse.providers,
        gate: SessionIndexMaintenanceGate = .shared
    ) async -> Outcome? {
        await runIfNeededBehindGate(
            databaseURL: databaseURL,
            stampURL: stampURL,
            steps: [Step(version: version, providers: providers)],
            gate: gate
        )
    }

    /// A single whole-provider step, for callers that name one version.
    @discardableResult
    public static func runIfNeeded(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexReparseStampURL,
        version: Int,
        providers: [String] = SessionIndexReparse.providers
    ) -> Outcome? {
        runIfNeeded(
            databaseURL: databaseURL,
            stampURL: stampURL,
            steps: [Step(version: version, providers: providers)]
        )
    }

    /// Run every step newer than the stamp, once. Returns what it did, or nil
    /// when the stamp is current, the index does not exist yet, or the
    /// database refused before any step completed. Each step is stamped as it
    /// completes, so a refusal part-way leaves only the remaining steps for
    /// the next launch — and never stamps over a delete that did not run.
    @discardableResult
    public static func runIfNeeded(
        databaseURL: URL = VibeBarLocalStore.sessionIndexURL,
        stampURL: URL = VibeBarLocalStore.sessionIndexReparseStampURL,
        steps: [Step] = SessionIndexReparse.steps
    ) -> Outcome? {
        let applied = (try? VibeBarLocalStore.readJSON(Stamp.self, from: stampURL))?.version ?? 0
        let pending = steps.filter { $0.version > applied }.sorted { $0.version < $1.version }
        guard let target = pending.last?.version else { return nil }
        // No index yet is the good case: whatever is scanned next is scanned
        // by the new parser. Stamp it so this never runs on that database.
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            try? VibeBarLocalStore.writeJSON(Stamp(version: target), to: stampURL)
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
        var dropped = 0
        var reached: Int?
        for step in pending {
            let before = sqlite3_total_changes64(database)
            guard run(step, on: database) else { break }
            let stepDropped = Int(sqlite3_total_changes64(database) - before)
            dropped += stepDropped
            reached = step.version
            // Every delete of this step ran, so its stamp is earned. A
            // provider with nothing indexed drops nothing and is equally done.
            try? VibeBarLocalStore.writeJSON(Stamp(version: step.version), to: stampURL)
            let what = (step.providers + step.targeted.map(\.rawValue)).joined(separator: ", ")
            SafeLog.info("Session index reparse v\(step.version): dropped \(stepDropped) cursor(s) for \(what)")
        }
        guard let reached else { return nil }
        return Outcome(version: reached, cursorsDropped: dropped)
    }

    /// One step's deletes. False as soon as one does not report
    /// `SQLITE_DONE`: a busy database is the ordinary case — an index refresh
    /// is running — and it is why the step must not be stamped, since a stamp
    /// written over a delete that never happened leaves those files under the
    /// old reading for good.
    private static func run(_ step: Step, on database: OpaquePointer) -> Bool {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var statements: [(sql: String, text: String, label: String)] = step.providers.map {
            ("DELETE FROM session_files WHERE provider = ?1", $0, $0)
        }
        statements += step.targeted.map { ($0.sql, $0.pattern, $0.rawValue) }
        for entry in statements {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, entry.sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                if statement != nil { sqlite3_finalize(statement) }
                SafeLog.info("Session index reparse v\(step.version) deferred: \(entry.label) did not prepare")
                return false
            }
            sqlite3_bind_text(statement, 1, entry.text, -1, transient)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else {
                SafeLog.info("Session index reparse v\(step.version) deferred: \(entry.label) delete returned \(result)")
                return false
            }
        }
        return true
    }
}
