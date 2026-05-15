import XCTest
@testable import VibeBarCore

final class WarpParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    func testHappyPathFinitePlanAndBonuses() throws {
        let json = """
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": false,
                  "nextRefreshTime": "2026-06-01T00:00:00Z",
                  "requestLimit": 1500,
                  "requestsUsedSinceLastRefresh": 600
                },
                "bonusGrants": [
                  {
                    "requestCreditsGranted": 100,
                    "requestCreditsRemaining": 30,
                    "expiration": "2026-05-30T00:00:00Z"
                  }
                ],
                "workspaces": [
                  {
                    "bonusGrantsInfo": {
                      "grants": [
                        {
                          "requestCreditsGranted": 50,
                          "requestCreditsRemaining": 20,
                          "expiration": "2026-05-21T00:00:00Z"
                        }
                      ]
                    }
                  }
                ]
              }
            }
          }
        }
        """

        let snap = try WarpResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertFalse(snap.isUnlimited)
        XCTAssertEqual(snap.requestLimit, 1500)
        XCTAssertEqual(snap.requestsUsed, 600)
        XCTAssertEqual(snap.bonusCreditsTotal, 150)
        XCTAssertEqual(snap.bonusCreditsRemaining, 50)

        // Earliest expiration is workspace grant (2026-05-21).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(snap.bonusNextExpiration, formatter.date(from: "2026-05-21T00:00:00Z"))
        XCTAssertEqual(snap.bonusNextExpirationRemaining, 20)

        let parsed = WarpResponseParser.buckets(from: snap)
        XCTAssertEqual(parsed.buckets.count, 2)

        let credits = try XCTUnwrap(parsed.buckets.first { $0.id == "warp.credits" })
        XCTAssertEqual(credits.usedPercent, 40.0, accuracy: 0.001)
        XCTAssertEqual(credits.groupTitle, "600 / 1500 credits")
        XCTAssertNil(parsed.planName)

        let bonus = try XCTUnwrap(parsed.buckets.first { $0.id == "warp.bonus" })
        let expectedBonusUsed = Double(150 - 50) / 150.0 * 100.0
        XCTAssertEqual(bonus.usedPercent, expectedBonusUsed, accuracy: 0.001)
        XCTAssertTrue(bonus.groupTitle?.contains("50 bonus") ?? false)
    }

    func testUnlimitedPlanRendersZeroAndUnlimitedLabel() throws {
        let json = """
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": true,
                  "nextRefreshTime": null,
                  "requestLimit": 0,
                  "requestsUsedSinceLastRefresh": 0
                },
                "bonusGrants": [],
                "workspaces": []
              }
            }
          }
        }
        """
        let snap = try WarpResponseParser.parse(data: Data(json.utf8), now: now)
        XCTAssertTrue(snap.isUnlimited)
        let parsed = WarpResponseParser.buckets(from: snap)
        XCTAssertEqual(parsed.planName, "Unlimited")
        let credits = try XCTUnwrap(parsed.buckets.first { $0.id == "warp.credits" })
        XCTAssertEqual(credits.usedPercent, 0)
        XCTAssertEqual(credits.groupTitle, "Unlimited")
        XCTAssertNil(parsed.buckets.first(where: { $0.id == "warp.bonus" }))
    }

    func testGraphQLErrorMapsToNeedsLoginOrParseFailure() {
        let unauthenticated = """
        {"errors": [{"message": "User must be authenticated to perform this action"}]}
        """
        XCTAssertThrowsError(try WarpResponseParser.parse(data: Data(unauthenticated.utf8), now: now)) { error in
            XCTAssertEqual(error as? QuotaError, .needsLogin)
        }

        let generic = """
        {"errors": [{"message": "Bad input"}]}
        """
        XCTAssertThrowsError(try WarpResponseParser.parse(data: Data(generic.utf8), now: now)) { error in
            if case .parseFailure(let msg) = error as? QuotaError {
                XCTAssertTrue(msg.contains("Bad input"))
            } else {
                XCTFail("expected parseFailure, got \(error)")
            }
        }
    }

    func testMissingUserOutputThrowsParseFailure() {
        let bad = """
        {"data": {"user": {"__typename": "AnonymousUser"}}}
        """
        XCTAssertThrowsError(try WarpResponseParser.parse(data: Data(bad.utf8), now: now)) { error in
            if case .parseFailure = error as? QuotaError {
                // Pass.
            } else {
                XCTFail("expected parseFailure, got \(error)")
            }
        }
    }

    /// Bonus grants whose `requestCreditsRemaining` is 0 should not
    /// drive the next-expiration date, otherwise stale grants would
    /// shadow live ones.
    func testZeroRemainingBonusGrantIgnoredForNextExpiration() throws {
        let json = """
        {
          "data": {
            "user": {
              "__typename": "UserOutput",
              "user": {
                "requestLimitInfo": {
                  "isUnlimited": false,
                  "nextRefreshTime": "2026-06-01T00:00:00Z",
                  "requestLimit": 500,
                  "requestsUsedSinceLastRefresh": 50
                },
                "bonusGrants": [
                  {
                    "requestCreditsGranted": 100,
                    "requestCreditsRemaining": 0,
                    "expiration": "2026-04-01T00:00:00Z"
                  },
                  {
                    "requestCreditsGranted": 20,
                    "requestCreditsRemaining": 15,
                    "expiration": "2026-05-15T00:00:00Z"
                  }
                ],
                "workspaces": []
              }
            }
          }
        }
        """
        let snap = try WarpResponseParser.parse(data: Data(json.utf8), now: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(snap.bonusNextExpiration, formatter.date(from: "2026-05-15T00:00:00Z"))
        XCTAssertEqual(snap.bonusNextExpirationRemaining, 15)
    }
}
