import XCTest
@testable import VibeBarCore

/// Smoke tests for `GeminiQuotaAdapter`'s account-source boundary.
/// Gemini live quota is Web-only; CLI telemetry remains a cost-history
/// input, not a quota account.
final class GeminiDualFetchTests: XCTestCase {
    private func makeEmptyHomeAdapter() throws -> (GeminiQuotaAdapter, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebar-gemini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let adapter = GeminiQuotaAdapter(
            session: .shared,
            homeDirectory: temp.path,
            now: { Date() },
            cookieHeader: { throw QuotaError.noCredential }
        )
        return (adapter, temp)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func account(source: CredentialSource) -> AccountIdentity {
        AccountIdentity(
            id: source == .oauthCLI ? "stale-oauth-gemini" : "web-gemini",
            tool: .gemini,
            alias: source == .oauthCLI ? "Stale Gemini CLI" : "Gemini Web",
            source: source,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testOAuthAccountThrowsUnknownBecauseCLIQuotaIsRemoved() async throws {
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .oauthCLI))
            XCTFail("Expected throw for CLI quota source")
        } catch QuotaError.unknown {
            // Pass
        } catch {
            XCTFail("Expected .unknown, got \(error)")
        }
    }

    func testWebAccountWithoutCookiesSurfacesNoCredential() async throws {
        // With no cookies imported, the adapter should surface a
        // QuotaError without crashing. The injected loader keeps this
        // test isolated from the developer's real Gemini Keychain item.
        let (adapter, temp) = try makeEmptyHomeAdapter()
        defer { cleanup(temp) }

        do {
            _ = try await adapter.fetch(for: account(source: .webCookie))
            XCTFail("Expected noCredential without an injected cookie")
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
