import Foundation
import XCTest
@testable import VibeBarCore

final class RemoteSyncErrorTests: XCTestCase {
    func testTransportErrorsNormalizeIntoActionableStableCodes() {
        XCTAssertEqual(
            RemoteSyncError.normalized(URLError(.timedOut)),
            .networkTimeout
        )
        XCTAssertEqual(
            RemoteSyncError.normalized(URLError(.cannotFindHost)),
            .hostLookupFailed
        )
        XCTAssertEqual(
            RemoteSyncError.normalized(URLError(.secureConnectionFailed)),
            .secureConnectionFailed
        )
        XCTAssertEqual(
            RemoteSyncError.normalized(CocoaError(.fileReadUnknown)),
            .invalidResponse
        )
        XCTAssertEqual(
            RemoteSyncError.normalized(
                HTTPResponseLimit.BoundedError.responseTooLarge(limit: 1024)
            ),
            .invalidResponse
        )
    }

    func testOnlyRecoverableRemoteErrorsAreRetried() {
        XCTAssertTrue(RemoteSyncError.networkTimeout.isTransient)
        XCTAssertTrue(RemoteSyncError.http(429).isTransient)
        XCTAssertTrue(RemoteSyncError.http(503).isTransient)
        XCTAssertFalse(RemoteSyncError.http(401).isTransient)
        XCTAssertFalse(RemoteSyncError.invalidSignature.isTransient)
    }

    func testHTTPStatusRemainsVisibleInTheDiagnosticCode() {
        XCTAssertEqual(RemoteSyncError.http(502).code, "relay_http_502")
    }
}
