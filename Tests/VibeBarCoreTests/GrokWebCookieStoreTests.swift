import XCTest
@testable import VibeBarCore

final class GrokWebCookieStoreTests: XCTestCase {
    func testMinimizationKeepsAuthCookiesAndDropsTrackers() {
        let raw = "sso=auth123; _ga=GA1.2.foo; sso-rw=rw456; _intercom_session=baz; cf_clearance=cf789; foo=bar"
        let minimized = GrokWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNotNil(minimized)
        let header = minimized ?? ""
        XCTAssertTrue(header.contains("sso=auth123"))
        XCTAssertTrue(header.contains("sso-rw=rw456"))
        XCTAssertTrue(header.contains("cf_clearance=cf789"))
        XCTAssertFalse(header.contains("_ga"))
        XCTAssertFalse(header.contains("_intercom_session"))
        XCTAssertFalse(header.contains("foo=bar"))
    }

    func testMinimizationAcceptsSsoOnly() {
        let raw = "sso=auth123; _ga=GA1.2.foo"
        let minimized = GrokWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertEqual(minimized, "sso=auth123")
    }

    func testMinimizationAcceptsSsoRwOnly() {
        let raw = "sso-rw=rw456; cf_clearance=cf789"
        let minimized = GrokWebCookieStore.minimizedCookieHeader(from: raw)
        XCTAssertNotNil(minimized)
        let header = minimized ?? ""
        XCTAssertTrue(header.contains("sso-rw=rw456"))
        XCTAssertTrue(header.contains("cf_clearance=cf789"))
    }

    func testMinimizationRejectsHeaderWithoutAuthCookies() {
        // No sso / sso-rw — without an auth cookie the header is
        // useless even if cf_clearance happens to be present.
        let raw = "cf_clearance=cf789; _ga=GA1.2.foo"
        XCTAssertNil(GrokWebCookieStore.minimizedCookieHeader(from: raw))
    }

    func testMinimizationRejectsEmptyAuthCookieValue() {
        // An auth cookie has to actually carry a value — an empty
        // sso= pair is the shape we'd see when the user is signed out.
        let raw = "sso=; sso-rw=; cf_clearance=cf789"
        XCTAssertNil(GrokWebCookieStore.minimizedCookieHeader(from: raw))
    }

    func testNormalizedCookieHeaderStripsLeadingCookieLabel() {
        XCTAssertEqual(
            GrokWebCookieStore.normalizedCookieHeader(from: "Cookie: sso=auth"),
            "sso=auth"
        )
        XCTAssertEqual(
            GrokWebCookieStore.normalizedCookieHeader(from: "  Cookie: sso=auth  "),
            "sso=auth"
        )
    }

    func testWriteThenReadRoundTripsViaInMemoryStore() throws {
        try SecureCookieHeaderStore.withInMemoryStoreForTesting {
            XCTAssertFalse(GrokWebCookieStore.hasCookieHeader())
            try GrokWebCookieStore.writeCookieHeader(
                "sso=auth123; cf_clearance=cf789",
                source: .browser
            )
            XCTAssertTrue(GrokWebCookieStore.hasCookieHeader())
            let header = try GrokWebCookieStore.readCookieHeader()
            XCTAssertTrue(header.contains("sso=auth123"))
            XCTAssertTrue(header.contains("cf_clearance=cf789"))
        }
    }

    func testWriteRejectsHeaderWithoutAuthCookies() throws {
        try SecureCookieHeaderStore.withInMemoryStoreForTesting {
            XCTAssertThrowsError(
                try GrokWebCookieStore.writeCookieHeader(
                    "cf_clearance=cf789; _ga=GA1.2.foo",
                    source: .browser
                )
            ) { error in
                guard let qe = error as? QuotaError else {
                    return XCTFail("Expected QuotaError, got \(error)")
                }
                guard case .noCredential = qe else {
                    return XCTFail("Expected .noCredential, got \(qe)")
                }
            }
            XCTAssertFalse(GrokWebCookieStore.hasCookieHeader())
        }
    }
}
