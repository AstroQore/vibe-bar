import XCTest
@testable import VibeBarCore

/// Tests the `WIZ_global_data.SNlM0e` XSRF token extractor used by
/// `GeminiWebQuotaFetcher` to authenticate against the live quota
/// endpoint. The 2026-05-23 spike confirmed Google ships the token
/// inline in the SSR HTML of `https://gemini.google.com/usage?pli=1`
/// under that exact key name.
final class GeminiWebXsrfExtractionTests: XCTestCase {
    func testExtractTokenFromCanonicalWizGlobalData() throws {
        let html = """
        <html><head><script>
        window.WIZ_global_data = {"SNlM0e":"AOOh0PsyntheticTokenValueXYZ","FdrFJe":"12345"};
        </script></head><body></body></html>
        """
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "AOOh0PsyntheticTokenValueXYZ")
    }

    func testExtractTokenWithExtraWhitespaceAroundColon() throws {
        // Some Google internal builders pretty-print the inline blob —
        // the regex must tolerate whitespace around the `:`.
        let html = "<script>WIZ_global_data = {\"SNlM0e\"  :   \"tok-1\"}</script>"
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "tok-1")
    }

    func testExtractTokenPicksFirstSNlM0eIfMultiplePresent() throws {
        // If, for any reason, the page ships two SNlM0e literals, the
        // first one wins — that's the one the upstream Angular code
        // also reads at boot time.
        let html = "<script>{\"SNlM0e\":\"first-token\"} ... {\"SNlM0e\":\"second-token\"}</script>"
        let token = try GeminiWebQuotaFetcher.extractXsrfToken(from: html)
        XCTAssertEqual(token, "first-token")
    }

    func testMissingTokenSurfaceAsNeedsLogin() {
        // A logged-out shell strips WIZ_global_data entirely. The
        // extractor must distinguish that case as `.needsLogin`
        // rather than `.parseFailure` so the UI can prompt the
        // user to re-import cookies instead of pretending the
        // wire shape changed.
        let html = "<html><body>Sign in to Gemini</body></html>"
        XCTAssertThrowsError(try GeminiWebQuotaFetcher.extractXsrfToken(from: html)) { error in
            guard case QuotaError.needsLogin = error else {
                XCTFail("Expected needsLogin, got \(error)")
                return
            }
        }
    }
}
