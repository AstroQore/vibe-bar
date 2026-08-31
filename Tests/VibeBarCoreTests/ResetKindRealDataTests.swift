import XCTest
@testable import VibeBarCore

/// Classify the developer's own quota history and report what each provider
/// does when it refills early.
///
/// Ignored by default: it needs a machine that has run the app. It reads a
/// copy of the timeline and writes to a temporary store, so the real files are
/// untouched.
///
/// The same classification runs in Vibe Bar Desktop over the same observations,
/// so the two outputs should agree bucket for bucket. They are separate
/// implementations of one rule, and this is the cheapest place to notice them
/// drifting apart.
final class ResetKindRealDataTests: XCTestCase {
    func testClassifyTheDevelopersOwnHistory() async throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let timeline = home.appendingPathComponent(".vibebar/fill_timeline.sqlite3")
        guard FileManager.default.fileExists(atPath: timeline.path) else {
            throw XCTSkip("no fill timeline on this machine")
        }
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["VIBEBAR_CLASSIFY_REAL_HISTORY"] == nil,
            "set VIBEBAR_CLASSIFY_REAL_HISTORY to run"
        )

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-reset-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("fill_timeline.sqlite3")
        try FileManager.default.copyItem(at: timeline, to: copy)

        let points = await UsageFillTimelineStore(fileURL: copy).allPoints()
        XCTAssertFalse(points.isEmpty, "the timeline copy read as empty")

        // Replay every observation through the live path, so this exercises
        // what the app actually does rather than a parallel implementation.
        let store = SubscriptionHistoryStore(
            fileURL: scratch.appendingPathComponent("subscription_history.json")
        )
        let grouped = Dictionary(grouping: points) {
            SubscriptionHistoryKey(accountId: $0.accountId, bucketId: $0.bucketId)
        }
        for (key, raw) in grouped.sorted(by: { $0.key.bucketId < $1.key.bucketId }) {
            let sorted = raw.sorted { $0.sampledAt < $1.sampledAt }
            for point in sorted {
                await store.observe(
                    AccountQuota(
                        accountId: key.accountId,
                        tool: point.tool,
                        buckets: [QuotaBucket(
                            id: key.bucketId,
                            title: key.bucketId,
                            shortLabel: key.bucketId,
                            usedPercent: point.usedPercent,
                            resetAt: point.resetAt,
                            rawWindowSeconds: point.rawWindowSeconds
                        )],
                        queriedAt: point.sampledAt
                    ),
                    now: point.sampledAt,
                    retentionDays: 3_650
                )
            }
            let samples = await store
                .samples(accountId: key.accountId, bucketId: key.bucketId,
                         now: Date(), includeCurrent: false)
                .filter(\.isCompleted)
            guard samples.count >= 5 else { continue }
            func count(_ kind: SubscriptionWindowSample.ResetKind) -> Int {
                samples.filter { $0.resetKind == kind }.count
            }
            // Not every point carries the window; take the first that does.
            let window = sorted.compactMap(\.rawWindowSeconds).first.map { Double($0) / 3600 } ?? 0
            print(
                """
                \(key.bucketId): window \(Int(window))h, \(samples.count) cycles — \
                on schedule \(count(.onSchedule)), \
                early+restarted \(count(.earlyClockRestarted)), \
                early+unchanged \(count(.earlyClockUnchanged)), \
                unclear \(count(.earlyUnclear))
                """
            )
            XCTAssertEqual(
                samples.filter { $0.resetKind == nil }.count, 0,
                "\(key.bucketId) left cycles unclassified"
            )
        }
    }
}
