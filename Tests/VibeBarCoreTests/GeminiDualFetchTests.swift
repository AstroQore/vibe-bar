import XCTest
@testable import VibeBarCore

/// Smoke tests for the dual-fetch dispatch in `GeminiQuotaAdapter`.
/// The adapter's helpers are private, so these tests focus on the
/// observable behaviour: which sources get attempted for each mode,
/// and how failures from both halves are surfaced.
///
/// The Web parser is currently spike-pending and always throws
/// `parseFailure`; in `.auto` mode that side is silently dropped when
/// OAuth succeeds, and is the dominant error only when OAuth also
/// fails.
final class GeminiDualFetchTests: XCTestCase {
    private func makeEmptyHomeAdapter(mode: GeminiUsageMode) throws -> (GeminiQuotaAdapter, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let adapter = GeminiQuotaAdapter(
            session: .shared,
            homeDirectory: temp.path,
            now: { Date() },
            usageMode: { mode }
        )
        return (adapter, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private var fixtureAccount: AccountIdentity {
        AccountIdentity(
            id: "test-gemini",
            tool: .gemini,
            alias: "Gemini Test",
            source: .oauthCLI,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testOAuthOnlyModeThrowsNoCredentialWhenCredsMissing() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter(mode: .oauthOnly)
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: fixtureAccount)
            XCTFail("Expected throw with no oauth_creds.json present")
        } catch QuotaError.noCredential {
            // Pass
        } catch {
            XCTFail("Expected .noCredential, got \(error)")
        }
    }

    func testAutoModeThrowsWhenBothSourcesUnconfigured() async throws {
        // With no `~/.gemini/oauth_creds.json` and no imported cookies,
        // the adapter should surface an error rather than returning an
        // empty bucket list. The Web side always parseFailures while
        // the spike is incomplete, so the merged error is OAuth's
        // .noCredential (the more diagnostic of the two).
        let (adapter, temp) = try makeEmptyHomeAdapter(mode: .auto)
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: fixtureAccount)
            XCTFail("Expected throw with no sources configured")
        } catch QuotaError.noCredential {
            // Pass — OAuth's noCredential dominates the merger.
        } catch QuotaError.parseFailure {
            // Acceptable fallback if the local keychain still has
            // imported cookies from a previous session: the Web
            // side then surfaces its spike-pending parseFailure.
        } catch QuotaError.network {
            // Acceptable if the spike Web fetcher made a real call.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWebOnlyModeSurfacesSpikePendingError() async throws {
        // `.webOnly` always exercises the Web path. With the spike
        // incomplete the fetcher returns `parseFailure` (or
        // `noCredential` if no cookies are imported). Either is
        // acceptable here — the test guarantees no crash and a
        // QuotaError reaching the caller.
        let (adapter, temp) = try makeEmptyHomeAdapter(mode: .webOnly)
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: fixtureAccount)
            // If this ever succeeds it means the spike landed —
            // tighten the assertion to verify bucket shape.
        } catch is QuotaError {
            // Pass — any QuotaError is fine for this smoke test.
        } catch {
            XCTFail("Expected a QuotaError, got \(error)")
        }
    }
}
