import XCTest
@testable import VibeBarCore

/// Smoke tests for `GeminiQuotaAdapter`'s account-source dispatch.
/// After the split-cards refactor each Gemini source has its own
/// `AccountIdentity`, and the adapter routes by `account.source` —
/// no fallback chain, no bucket merging.
final class GeminiDualFetchTests: XCTestCase {
    private func makeEmptyHomeAdapter() throws -> (GeminiQuotaAdapter, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let adapter = GeminiQuotaAdapter(
            session: .shared,
            homeDirectory: temp.path,
            now: { Date() }
        )
        return (adapter, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func account(source: CredentialSource) -> AccountIdentity {
        AccountIdentity(
            id: source == .oauthCLI ? "oauth-gemini" : "web-gemini",
            tool: .gemini,
            alias: source == .oauthCLI ? "Gemini CLI" : "Gemini Web",
            source: source,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testOAuthAccountThrowsNoCredentialWhenCredsMissing() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .oauthCLI))
            XCTFail("Expected throw with no oauth_creds.json present")
        } catch QuotaError.noCredential {
            // Pass
        } catch {
            XCTFail("Expected .noCredential, got \(error)")
        }
    }

    func testWebAccountSurfacesSpikePendingError() async throws {
        // The Web fetcher is spike-pending and always throws either
        // .noCredential (no cookies imported) or .parseFailure
        // (cookies present, but the wire shape isn't decoded yet).
        // The adapter must propagate whichever happens — never crash.
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .webCookie))
            // If this ever succeeds, the spike has landed —
            // tighten the assertion in a follow-up PR to verify the
            // expected current/weekly bucket pair.
        } catch is QuotaError {
            // Pass — any QuotaError variant is acceptable here.
        } catch {
            XCTFail("Expected a QuotaError, got \(error)")
        }
    }

    func testUnsupportedSourceThrowsUnknown() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        // A Gemini account that somehow got registered with the wrong
        // source (e.g. a stale persisted snapshot) must surface a
        // clear error instead of silently doing nothing.
        let oddAccount = AccountIdentity(
            id: "stale-gemini",
            tool: .gemini,
            alias: "Stale",
            source: .cliDetected,
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            _ = try await adapter.fetch(for: oddAccount)
            XCTFail("Expected throw for unsupported source")
        } catch QuotaError.unknown {
            // Pass
        } catch {
            XCTFail("Expected .unknown, got \(error)")
        }
    }
}
