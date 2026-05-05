import XCTest
@testable import VibeBarCore

final class CodexParserTests: XCTestCase {
    func testSpecExampleProducesPrimaryAndSecondaryBuckets() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 56.0,
              "limit_window_seconds": 18000,
              "reset_at": 1760000000
            },
            "secondary_window": {
              "used_percent": 13.0,
              "limit_window_seconds": 604800,
              "reset_at": 1760000000
            }
          }
        }
        """
        let buckets = try CodexResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets.count, 2)

        let five = buckets[0]
        XCTAssertEqual(five.id, "five_hour")
        XCTAssertEqual(five.title, "5 Hours")
        XCTAssertEqual(five.shortLabel, "5h")
        XCTAssertEqual(five.usedPercent, 56)
        XCTAssertEqual(five.remainingPercent, 44)
        XCTAssertEqual(five.rawWindowSeconds, 18000)
        XCTAssertEqual(five.resetAt, Date(timeIntervalSince1970: 1_760_000_000))

        let week = buckets[1]
        XCTAssertEqual(week.id, "weekly")
        XCTAssertEqual(week.title, "Weekly")
        XCTAssertEqual(week.shortLabel, "wk")
        XCTAssertEqual(week.usedPercent, 13)
        XCTAssertEqual(week.remainingPercent, 87)
        XCTAssertEqual(week.rawWindowSeconds, 604800)
    }

    func testAdditionalRateLimitsBecomeExtraBuckets() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 11,
              "limit_window_seconds": 18000,
              "reset_at": 1760000000
            },
            "secondary_window": {
              "used_percent": 8,
              "limit_window_seconds": 604800,
              "reset_at": 1760000000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 0,
                  "limit_window_seconds": 18000,
                  "reset_at": 1760001000
                },
                "secondary_window": {
                  "used_percent": 2,
                  "limit_window_seconds": 604800,
                  "reset_at": 1760002000
                }
              }
            }
          ]
        }
        """
        let buckets = try CodexResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets.count, 4)

        let sparkFive = buckets.first { $0.id == "gpt_5_3_codex_spark_five_hour" }
        XCTAssertEqual(sparkFive?.groupTitle, "GPT-5.3 Codex Spark")
        XCTAssertEqual(sparkFive?.title, "5 Hours")
        XCTAssertEqual(sparkFive?.shortLabel, "Spark 5h")
        XCTAssertEqual(sparkFive?.usedPercent, 0)
        XCTAssertEqual(sparkFive?.resetAt, Date(timeIntervalSince1970: 1_760_001_000))

        let sparkWeek = buckets.first { $0.id == "gpt_5_3_codex_spark_weekly" }
        XCTAssertEqual(sparkWeek?.groupTitle, "GPT-5.3 Codex Spark")
        XCTAssertEqual(sparkWeek?.title, "Weekly")
        XCTAssertEqual(sparkWeek?.shortLabel, "Spark wk")
        XCTAssertEqual(sparkWeek?.usedPercent, 2)
        XCTAssertEqual(sparkWeek?.resetAt, Date(timeIntervalSince1970: 1_760_002_000))
    }

    func testUsedPercentClampsAbove100() throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 142, "limit_window_seconds": 18000}}}
        """
        let buckets = try CodexResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets[0].usedPercent, 100)
        XCTAssertEqual(buckets[0].remainingPercent, 0)
    }

    func testCustomDayWindowMappedToNDays() throws {
        let twoDays = 2 * 86400
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 25, "limit_window_seconds": \(twoDays)}}}
        """
        let buckets = try CodexResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets[0].title, "2 Days")
        XCTAssertEqual(buckets[0].shortLabel, "2d")
    }

    func testCustomHourWindowMappedToNHours() throws {
        let json = """
        {"rate_limit": {"secondary_window": {"used_percent": 40, "limit_window_seconds": 3600}}}
        """
        let buckets = try CodexResponseParser.parse(data: Data(json.utf8))
        XCTAssertEqual(buckets[0].title, "1 Hours")
        XCTAssertEqual(buckets[0].shortLabel, "1h")
    }

    func testMissingRateLimitThrowsParseFailure() {
        let data = Data("{}".utf8)
        XCTAssertThrowsError(try CodexResponseParser.parse(data: data)) { error in
            guard case QuotaError.parseFailure = error else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
        }
    }

    func testInvalidJSONThrowsParseFailure() {
        let data = Data("not json".utf8)
        XCTAssertThrowsError(try CodexResponseParser.parse(data: data)) { error in
            guard case QuotaError.parseFailure = error else {
                return XCTFail("Expected parseFailure, got \(error)")
            }
        }
    }
}
