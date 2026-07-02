import XCTest
@testable import VibeBarCore

/// Parity guardrail for Claude's per-model usage limits — the self-enforcing
/// half of the "Adding a new Claude usage-limit model" checklist in
/// `AGENTS.md` § 11.1.
///
/// `ClaudeResponseParser.knownBuckets` is the single source of truth for which
/// Claude usage dimensions become `QuotaBucket`s. Every per-model dimension
/// (a `knownBuckets` entry carrying a `groupTitle`) must also have a
/// `MenuBarFieldCatalog.claudeFields` entry, or it can never be selected for
/// the menu bar / mini window. This suite fails `swift test` when the two
/// drift, so adding a new Claude usage limit to the parser without wiring the
/// menu-bar field is caught here instead of silently shipping a half-added
/// model.
final class ClaudeModelBucketParityTests: XCTestCase {
    func testEveryPerModelBucketHasMenuBarField() {
        let fieldBucketIDs = Set(MenuBarFieldCatalog.claudeFields.map { $0.bucketId })
        for bucketID in ClaudeResponseParser.perModelBucketIDs {
            XCTAssertTrue(
                fieldBucketIDs.contains(bucketID),
                """
                Claude per-model bucket '\(bucketID)' from \
                ClaudeResponseParser.knownBuckets has no matching \
                MenuBarFieldCatalog.claudeFields entry. Add \
                `option(.claude, "\(bucketID)", ...)` plus the mini-window \
                label sites listed in AGENTS.md § 11.1 when introducing a new \
                Claude usage limit.
                """
            )
        }
    }

    func testFableBucketIsRegisteredAsPerModel() {
        XCTAssertTrue(ClaudeResponseParser.perModelBucketIDs.contains("weekly_fable"))
    }
}
