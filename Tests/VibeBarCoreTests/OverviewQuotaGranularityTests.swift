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

    func testChatGPTSubProviderIsOneStableCardAndModelGroupsRemainSeparate() {
        let chat = [bucket("image_gen", group: "Image Generation"), bucket("deep_research", group: "Deep Research")]
        let codex = [bucket("weekly"), bucket("spark_weekly", group: "Spark")]
        let sources: [ToolType: [QuotaBucket]] = [.codex: codex, .chatgptChat: chat]

        func cards(_ granularity: OverviewQuotaGranularity, _ buckets: [ToolType: [QuotaBucket]],
                   includeChat: Bool = true) -> [OverviewQuotaPartition] {
            ToolType.chatGPTQuotaSources(includeChat: includeChat).flatMap { tool in
                OverviewQuotaPartition.partitions(tool: tool, buckets: buckets[tool] ?? [], granularity: granularity)
            }
        }

        for quotas in [sources, [.chatgptChat: chat], [.codex: codex], [:]] {
            let parts = cards(.subProvider, quotas)
            XCTAssertEqual(parts.map(\.displayTitle), ["ChatGPT"])
            XCTAssertEqual(parts.map(\.isCombinedChatGPT), [true])
            XCTAssertEqual(parts.map(\.id), [OverviewQuotaPartition.combinedChatGPTModuleID.rawValue])
        }
        XCTAssertEqual(cards(.subProvider, sources, includeChat: false).map(\.id),
                       cards(.subProvider, sources).map(\.id))

        let models = cards(.model, sources)
        XCTAssertEqual(models.map(\.tool), [.chatgptChat, .chatgptChat, .codex, .codex])
        XCTAssertEqual(models.flatMap(\.bucketIDs), ["image_gen", "deep_research", "weekly", "spark_weekly"])
        XCTAssertEqual(models.compactMap(\.groupTitle), ["Image Generation", "Deep Research", "Spark"])
        XCTAssertTrue(models.allSatisfy { $0.displayTitle == "ChatGPT" && !$0.isCombinedChatGPT })
        XCTAssertEqual(models.map(\.id), [
            "overview-quota:chatgptChat:model:Q2hhdEdQVCBDaGF0AEltYWdlIEdlbmVyYXRpb24=",
            "overview-quota:chatgptChat:model:Q2hhdEdQVCBDaGF0AERlZXAgUmVzZWFyY2g=",
            "overview-quota:codex:model:Q2hhdEdQVCBBZ2VudGljAA==",
            "overview-quota:codex:model:Q2hhdEdQVCBBZ2VudGljAFNwYXJr"
        ])
        XCTAssertEqual(ToolType.chatGPTQuotaSources(includeChat: true), [.chatgptChat, .codex])
        XCTAssertEqual(ToolType.chatGPTQuotaSources(includeChat: false), [.codex])
    }

    // Literal IDs match persisted v1.9.1 data; deriving them from the new
    // partition builder would let the migration tests miss an ID change.
    private let oldChat = PageLayoutModuleID("overview-quota:chatgptChat:subprovider:Q2hhdEdQVCBDaGF0AA==")
    private let oldCodex = PageLayoutModuleID("overview-quota:codex:subprovider:Q2hhdEdQVCBBZ2VudGljAA==")

    private func roundTrip(_ settings: AppSettings) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    }

    func testChatGPTOverviewMigratesLegacyVisibilityWithoutMaterializedLayout() throws {
        let combined = OverviewQuotaPartition.combinedChatGPTModuleID
        XCTAssertNotEqual(combined, oldChat)
        XCTAssertNotEqual(combined, oldCodex)
        let unrelated = PageLayoutModuleID.custom("overview-quota:codex")
        let cases: [(saved: [PageLayoutModuleID], expected: [PageLayoutModuleID])] = [
            ([oldCodex, unrelated], [unrelated]),
            ([oldChat, unrelated], [unrelated]),
            ([oldChat, oldCodex, unrelated], [unrelated, combined]),
            ([combined, unrelated], [combined, unrelated]),
            ([combined, oldCodex, unrelated], [combined, unrelated])
        ]

        for entry in cases {
            var settings = AppSettings.default
            settings.pageLayouts[.overview] = StoredPageLayout(hidden: entry.saved)
            let decoded = try roundTrip(settings)
            let layout = try XCTUnwrap(decoded.pageLayouts[.overview])
            XCTAssertEqual(layout.mode, .auto)
            XCTAssertEqual(layout.columns, [[], []])
            XCTAssertEqual(layout.segments, [])
            XCTAssertEqual(layout.hidden, entry.expected, "Saved hidden IDs: \(entry.saved)")
            XCTAssertEqual(try roundTrip(decoded), decoded)
        }
    }

    func testChatGPTOverviewMigratesPositionsInLayoutsPresetsAndStudioGroups() throws {
        let combined = OverviewQuotaPartition.combinedChatGPTModuleID
        let untouched = PageLayoutModuleID.custom("untouched")
        let other = PageLayoutModuleID.custom("other")
        let chatOnly = StoredPageLayout(mode: .manual, ratio: .wideNarrow,
                                        columns: [[], [untouched, oldChat]], segments: [[oldChat], [untouched]])
        let both = StoredPageLayout(mode: .manual, columns: [[oldChat, untouched], [oldCodex]],
                                    segments: [[oldChat], [oldCodex, untouched]])
        let alreadyPlaced = StoredPageLayout(mode: .manual,
                                             columns: [[oldChat, untouched], [oldCodex, other, combined]],
                                             hidden: [oldChat, oldCodex])
        var settings = AppSettings.default
        settings.pageLayouts[.overview] = both.settingHidden(oldCodex, true)
        settings.pageLayoutPresets[.overview] = [
            .init(name: "Chat only", layout: chatOnly),
            .init(name: "Both hidden", layout: both.settingHidden(oldCodex, true).settingHidden(oldChat, true)),
            .init(name: "Already placed", layout: alreadyPlaced)
        ]
        let overviewKey = PageLayoutPageID.overview.rawValue
        settings.studioCardGroups[overviewKey] = [[oldChat.rawValue, untouched.rawValue], [oldCodex.rawValue, other.rawValue]]

        let decoded = try roundTrip(settings)
        let overview = try XCTUnwrap(decoded.pageLayouts[.overview])
        XCTAssertEqual(overview.columns, [[untouched], [combined]])
        XCTAssertEqual(overview.segments, [[combined, untouched]])
        XCTAssertFalse(overview.isHidden(combined))
        let presets = try XCTUnwrap(decoded.pageLayoutPresets[.overview])
        XCTAssertEqual(presets[0].layout.columns, [[], [untouched, combined]])
        XCTAssertEqual(presets[0].layout.segments, [[combined], [untouched]])
        XCTAssertEqual(presets[0].layout.ratio, .wideNarrow)
        XCTAssertTrue(presets[1].layout.isHidden(combined))
        XCTAssertEqual(presets[2].layout.columns, [[untouched], [other, combined]])
        XCTAssertFalse(presets[2].layout.isHidden(combined))
        XCTAssertEqual(decoded.studioCardGroups[overviewKey], [[combined.rawValue, other.rawValue]])
        XCTAssertEqual(try roundTrip(decoded), decoded)

        settings.studioCardGroups[overviewKey] = [[oldChat.rawValue, untouched.rawValue]]
        XCTAssertEqual(try roundTrip(settings).studioCardGroups[overviewKey], [[combined.rawValue, untouched.rawValue]])
    }

    func testChatGPTBadgeDescribesMatchingPlansWithoutHidingDifferences() {
        XCTAssertEqual(ProviderPlanDisplay.chatGPTQuotaBadge(sources: [("pro", "Pro 200"), ("pro200", "Pro 200")]), "Pro 200")
        XCTAssertEqual(ProviderPlanDisplay.chatGPTQuotaBadge(sources: [("plus", "Plus")]), "Plus")
        XCTAssertNil(ProviderPlanDisplay.chatGPTQuotaBadge(sources: [("pro", "Custom"), ("plus", "Custom")]))
        XCTAssertNil(ProviderPlanDisplay.chatGPTQuotaBadge(sources: [("pro", "A"), ("pro200", "B")]))
        XCTAssertNil(ProviderPlanDisplay.chatGPTQuotaBadge(sources: [("pro", "Pro 200"), (nil, nil)]))
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
