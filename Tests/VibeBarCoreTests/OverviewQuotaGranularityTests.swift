import Foundation
import XCTest
@testable import VibeBarCore

final class OverviewQuotaGranularityTests: XCTestCase {
    private func bucket(_ id: String, group: String? = nil) -> QuotaBucket {
        QuotaBucket(id: id, title: id, shortLabel: id, usedPercent: 37,
                    resetAt: Date(timeIntervalSince1970: 1_900_000_000), groupTitle: group)
    }

    func testExistingSettingsDefaultToCompanyAndEveryOptionPersists() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).overviewQuotaGranularity, .company)
        for value in OverviewQuotaGranularity.allCases {
            var settings = AppSettings.default
            settings.overviewQuotaGranularity = value
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(decoded.overviewQuotaGranularity, value)
        }
    }

    func testModelWindowsStayTogetherAndNoBucketIsLost() {
        let buckets = [bucket("weekly"), bucket("astra-day", group: "Astra"),
                       bucket("astra-week", group: "Astra"), bucket("sol-week", group: "Sol")]
        let parts = OverviewQuotaPartition.partitions(tool: .codex, buckets: buckets, granularity: .model)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.filter(\.showsSharedMetadata).count, 1)
        XCTAssertEqual(parts[1].bucketIDs, ["astra-day", "astra-week"])
        XCTAssertEqual(Set(parts.flatMap(\.bucketIDs)), Set(buckets.map(\.id)))
        XCTAssertEqual(parts.flatMap(\.bucketIDs).count, buckets.count)
        XCTAssertEqual(buckets.map(\.usedPercent), [37, 37, 37, 37])
    }

    func testGrokBotIsASeparateSubProviderFromCursor() {
        let buckets = [bucket("models"), bucket("other_models"), bucket("grok_bot_weekly", group: "Grok Bot")]
        let parts = OverviewQuotaPartition.partitions(tool: .cursor, buckets: buckets, granularity: .subProvider)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.first?.bucketIDs, ["models", "other_models"])
        XCTAssertEqual(parts.last?.bucketIDs, ["grok_bot_weekly"])
        XCTAssertEqual(parts.last?.subProvider, "Grok Bot")
        XCTAssertTrue(parts.last?.suppressGroupTitles == true)
    }

    func testSubProviderIdentitySurvivesWindowOrderingAndQuotaChanges() {
        let a = bucket("five_hour"), b = bucket("weekly")
        let first = OverviewQuotaPartition.partitions(tool: .claude, buckets: [a, b], granularity: .subProvider)
        let second = OverviewQuotaPartition.partitions(tool: .claude, buckets: [b, a], granularity: .subProvider)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(PageLayoutModuleID(first[0].id).family, "overview-quota")
    }

    func testEmptyGroupTitlesMergeWithUnnamedWindowsWithoutDuplicateIDs() {
        let parts = OverviewQuotaPartition.partitions(tool: .claude,
            buckets: [bucket("daily"), bucket("weekly", group: "  ")], granularity: .model)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].bucketIDs, ["daily", "weekly"])
    }

    func testSignedOutProvidersKeepAVisiblePlaceholder() {
        let parts = OverviewQuotaPartition.partitions(tool: .gemini, buckets: [], granularity: .model)
        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].bucketIDs.isEmpty)
        XCTAssertEqual(parts[0].subProvider, ToolType.gemini.quotaSubProviderName())
    }
}
