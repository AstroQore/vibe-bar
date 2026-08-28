import XCTest
@testable import VibeBarCore

final class QuotaFieldRegistryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func reserveBucket(title: String = "Weekly", group: String? = "GPT-reserve") -> QuotaBucket {
        QuotaBucket(
            id: "gpt_reserve_weekly",
            title: title,
            shortLabel: "gpt-reserve Weekly",
            usedPercent: 0,
            resetAt: now.addingTimeInterval(604_800),
            rawWindowSeconds: 604_800,
            groupTitle: group
        )
    }

    func testRecordsCatalogExternalBucket() {
        var registry = QuotaFieldRegistry()
        let changed = registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        XCTAssertTrue(changed)
        let field = registry.field(id: "codex.gpt_reserve_weekly")
        XCTAssertEqual(field?.groupTitle, "GPT-reserve")
        XCTAssertEqual(field?.title, "Weekly")
        XCTAssertEqual(field?.firstSeen, now)
    }

    func testIgnoresBucketsTheStaticCatalogAlreadyLists() {
        var registry = QuotaFieldRegistry()
        let known = QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "wk", usedPercent: 10)
        XCTAssertFalse(registry.record(tool: .codex, buckets: [known], now: now))
        XCTAssertTrue(registry.fields.isEmpty)
    }

    func testRepeatSightingWithinADayDoesNotChurnTheFile() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        let changed = registry.record(
            tool: .codex,
            buckets: [reserveBucket()],
            now: now.addingTimeInterval(120)
        )
        XCTAssertFalse(changed)
        // A day later the sighting is worth persisting.
        let dayLater = registry.record(
            tool: .codex,
            buckets: [reserveBucket()],
            now: now.addingTimeInterval(2 * 86_400)
        )
        XCTAssertTrue(dayLater)
    }

    func testMetadataDriftUpdatesTheEntry() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        let changed = registry.record(
            tool: .codex,
            buckets: [reserveBucket(group: "Luna Reserve")],
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(registry.field(id: "codex.gpt_reserve_weekly")?.groupTitle, "Luna Reserve")
    }

    func testCapDropsOldestSeenEntries() {
        var registry = QuotaFieldRegistry()
        for index in 0..<(QuotaFieldRegistry.maximumFields + 10) {
            let bucket = QuotaBucket(
                id: "invented_\(index)",
                title: "Weekly",
                shortLabel: "wk",
                usedPercent: 0
            )
            registry.record(
                tool: .codex,
                buckets: [bucket],
                now: now.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(registry.fields.count, QuotaFieldRegistry.maximumFields)
        // The newest sightings survive.
        XCTAssertNotNil(registry.field(id: "codex.invented_\(QuotaFieldRegistry.maximumFields + 9)"))
        XCTAssertNil(registry.field(id: "codex.invented_0"))
    }

    func testPruneForgetsOnlyUnreferencedDeadEntries() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        let dead = QuotaBucket(id: "gone_bucket", title: "Weekly", shortLabel: "wk", usedPercent: 0)
        registry.record(tool: .codex, buckets: [dead], now: now)
        let named = QuotaBucket(id: "named_gone", title: "Weekly", shortLabel: "wk", usedPercent: 0)
        registry.record(tool: .codex, buckets: [named], now: now)
        // Another tool's entry is out of scope for this tool's prune.
        let other = QuotaBucket(id: "ag_extra", title: "Weekly", shortLabel: "wk", usedPercent: 0)
        registry.record(tool: .antigravity, buckets: [other], now: now)

        let changed = registry.prune(
            tool: .codex,
            liveBucketIds: ["gpt_reserve_weekly"],
            keeping: ["codex.named_gone"]
        )
        XCTAssertTrue(changed)
        XCTAssertNotNil(registry.field(id: "codex.gpt_reserve_weekly"), "live entry stays")
        XCTAssertNotNil(registry.field(id: "codex.named_gone"), "referenced entry stays")
        XCTAssertNil(registry.field(id: "codex.gone_bucket"), "unreferenced dead entry drops")
        XCTAssertNotNil(registry.field(id: "antigravity.ag_extra"), "other tools untouched")
        XCTAssertFalse(
            registry.prune(
                tool: .codex,
                liveBucketIds: ["gpt_reserve_weekly"],
                keeping: ["codex.named_gone"]
            ),
            "second prune is a no-op"
        )
    }

    func testForgetDropsOneEntry() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        XCTAssertTrue(registry.forget(id: "codex.gpt_reserve_weekly"))
        XCTAssertNil(registry.field(id: "codex.gpt_reserve_weekly"))
        XCTAssertFalse(registry.forget(id: "codex.gpt_reserve_weekly"))
    }

    func testMergedFieldsAppendDynamicOptionsWithComposedTitle() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        let merged = MenuBarFieldCatalog.mergedFields(registry: registry)
        XCTAssertEqual(merged.count, MenuBarFieldCatalog.allFields.count + 1)
        let dynamic = merged.first { $0.id == "codex.gpt_reserve_weekly" }
        XCTAssertEqual(dynamic?.title, "GPT-reserve · Weekly")
        XCTAssertEqual(dynamic?.isDynamic, true)
        XCTAssertEqual(dynamic?.dynamicGroupTitle, "GPT-reserve")
        // Static resolution is unchanged and dynamic lookup works.
        XCTAssertNil(MenuBarFieldCatalog.field(id: "codex.gpt_reserve_weekly"))
        XCTAssertNotNil(MenuBarFieldCatalog.field(id: "codex.gpt_reserve_weekly", registry: registry))
    }

    func testBucketGroupStemStripsWindowSuffixes() {
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("gpt_reserve_weekly"), "gpt_reserve")
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("gpt_reserve_five_hour"), "gpt_reserve")
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("luna_30d_window"), "luna")
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("luna_12h_window"), "luna")
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("weekly"), "weekly")
        XCTAssertEqual(MenuBarFieldCatalog.bucketGroupStem("plain"), "plain")
    }

    func testOrderedSubProviderGroupsFollowFieldOrderAndFoldVendors() {
        var registry = QuotaFieldRegistry()
        registry.record(tool: .codex, buckets: [reserveBucket()], now: now)
        // Claude first, then Codex (including the discovered field), then the
        // two Google AI SubProviders back to back — they must fold into one
        // company while honoring the given order.
        let groups = MenuBarFieldCatalog.orderedSubProviderGroups(
            fieldIds: [
                "claude.five_hour",
                "codex.weekly",
                "codex.gpt_reserve_weekly",
                "gemini.weekly",
                "antigravity.gemini_weekly"
            ],
            registry: registry
        )
        XCTAssertEqual(groups.map(\.company), ["Anthropic", "OpenAI", "Google AI"])
        XCTAssertEqual(groups[1].subProviders.count, 1)
        XCTAssertEqual(
            groups[1].subProviders[0].fields.map(\.bucketId),
            ["weekly", "gpt_reserve_weekly"]
        )
        XCTAssertEqual(groups[2].subProviders.map(\.name), ["Gemini Web", "AntiGravity"])
    }

    func testOrderedSubProviderGroupsSkipUnknownIds() {
        let groups = MenuBarFieldCatalog.orderedSubProviderGroups(
            fieldIds: ["codex.weekly", "codex.someday_bucket"],
            registry: .empty
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].subProviders[0].fields.map(\.bucketId), ["weekly"])
    }
}
