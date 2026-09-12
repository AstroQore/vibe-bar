import XCTest
@testable import VibeBarCore

/// The naming the owner asked for after round 1: a slot says *which* bucket
/// it is, in the same three tiers the mini window shows, written out.
final class EInkSlotLabelTests: XCTestCase {
    private func bucket(_ id: String, title: String, group: String? = nil) -> QuotaBucket {
        QuotaBucket(id: id, title: title, shortLabel: "x", usedPercent: 10, groupTitle: group)
    }

    func testAHeadlineBucketNamesItsSubProviderAndWindowAndNothingElse() {
        // "All Models" is the catch-all lane, not a name: printing it would
        // claim three tiers where the bucket has two.
        XCTAssertEqual(EInkSlotLabel.default(for: "codex.weekly"), "ChatGPT Agentic · Weekly")
        XCTAssertEqual(EInkSlotLabel.default(for: "codex.five_hour"), "ChatGPT Agentic · 5 Hours")
        XCTAssertEqual(EInkSlotLabel.default(for: "claude.weekly"), "Claude · Weekly")
        XCTAssertEqual(EInkSlotLabel.default(for: "claude.five_hour"), "Claude · 5 Hours")
    }

    func testABranchBucketNamesItsQuotaGroupBetweenTheOtherTwo() {
        XCTAssertEqual(EInkSlotLabel.default(for: "claude.weekly_fable"), "Claude · Fable · Weekly")
        XCTAssertEqual(EInkSlotLabel.default(for: "claude.weekly_opus"), "Claude · Opus · Weekly")
        XCTAssertEqual(
            EInkSlotLabel.default(for: "codex.gpt_5_3_codex_spark_weekly"),
            "ChatGPT Agentic · GPT-5.3 Codex Spark · Weekly"
        )
        XCTAssertEqual(
            EInkSlotLabel.default(for: "antigravity.claude_gpt_weekly"),
            "AntiGravity · Claude and GPT Models · Weekly"
        )
    }

    /// Grok Bot rides Cursor's adapter but is its own SubProvider, and Cursor's
    /// own groups restate the product. Neither may be printed twice.
    func testATierThatRestatesAnEarlierOneIsDropped() {
        XCTAssertEqual(EInkSlotLabel.default(for: "cursor.grok_bot_weekly"), "Grok Bot · Weekly")
        XCTAssertEqual(EInkSlotLabel.default(for: "cursor.models"), "Cursor · Monthly")
        XCTAssertEqual(EInkSlotLabel.default(for: "cursor.other_models"), "Cursor · Other Models · Monthly")
    }

    /// The live bucket wins when it has one: a provider that renamed a window
    /// should be named by what it actually returned.
    func testTheLiveBucketOverridesTheCatalogTitle() {
        XCTAssertEqual(
            EInkSlotLabel.default(for: "claude.weekly_fable", bucket: bucket("weekly_fable", title: "Seven Days", group: "Fable")),
            "Claude · Fable · Seven Days"
        )
    }

    /// A bucket the static catalog has never heard of is named from the
    /// registry rather than printed as a raw field id.
    func testADiscoveredBucketIsNamedFromTheRegistry() {
        let registry = QuotaFieldRegistry(fields: [
            DiscoveredQuotaField(
                tool: .chatgptChat,
                bucketId: "reserve_weekly",
                title: "Weekly",
                groupTitle: "Reserve Pool",
                shortLabel: "Reserve",
                firstSeen: EInkFixtures.referenceDate,
                lastSeen: EInkFixtures.referenceDate
            )
        ])
        XCTAssertEqual(
            EInkSlotLabel.default(for: "chatgptChat.reserve_weekly", registry: registry),
            "ChatGPT Chat · Reserve Pool · Weekly"
        )
    }

    func testASlideLabelOverridesTheDefault() {
        var options = EInkSlideOptions.default
        options.customLabels = ["claude.weekly_fable": "  Story Weekly  "]
        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "claude.weekly_fable", options: options),
            "Story Weekly"
        )
        // An empty override is not an override.
        options.customLabels = ["claude.weekly_fable": "   "]
        XCTAssertEqual(
            EInkSlotLabel.resolved(for: "claude.weekly_fable", options: options),
            "Claude · Fable · Weekly"
        )
    }

    func testTheTwoLineFormSplitsAfterTheSubProvider() {
        let split = EInkSlotLabel.twoLines("Claude · Fable · Weekly")
        XCTAssertEqual(split.first, "Claude")
        XCTAssertEqual(split.second, "Fable · Weekly")
        // A one-part name has no second line to invent.
        XCTAssertEqual(EInkSlotLabel.twoLines("Claude").second, "")
    }

    func testALabelWiderThanItsColumnAsksForTwoLines() {
        let long = EInkSlotLabel.default(for: "antigravity.claude_gpt_weekly")
        XCTAssertTrue(EInkSlotLabel.needsTwoLines(long, columnWidth: 126))
        XCTAssertFalse(EInkSlotLabel.needsTwoLines("Claude · Weekly", columnWidth: 126))
    }

    /// The ledger's label column grows before anything else gives way, and
    /// only then does the slot split in two.
    func testTheLedgerGrowsItsLabelColumnBeforeSplittingTheSlot() throws {
        func drawn(_ labels: [(String, String)]) throws -> [EInkDrawBox] {
            var snapshot = EInkFixtures.snapshot()
            snapshot.quota = labels.enumerated().map { index, pair in
                EInkQuotaRow(
                    fieldID: "tool.bucket\(index)",
                    providerDisplayName: pair.0,
                    windowTitle: pair.1,
                    remainingPercent: 50,
                    resetAt: EInkFixtures.referenceDate.addingTimeInterval(3_600),
                    countdown: "1h 00m"
                )
            }
            let slide = EInkFixtures.slide(preset: .quotaLedger, fieldIDs: snapshot.quota.map(\.fieldID))
            return EInkBoxLayout.resolve(
                try EInkRenderer.tree(slide: slide, orientation: .degrees0, snapshot: snapshot),
                in: EInkRect(x: 0, y: 0, width: 296, height: 152)
            )
        }

        // Short names keep the shipped 126 px column.
        let short = try drawn([("Claude", "Weekly"), ("Grok", "Weekly")])
        let shortLabel = try XCTUnwrap(short.first { box in
            if case let .text(value, _, _) = box.content { return value == "Claude · Weekly" }
            return false
        })
        XCTAssertEqual(shortLabel.frame.width, 126)

        // A longer name grows the column instead of clipping in it.
        let long = try drawn([("AntiGravity", "Claude and GPT Models · Weekly"), ("Grok", "Weekly")])
        let grown = try XCTUnwrap(long.first { box in
            if case let .text(value, _, _) = box.content { return value.hasPrefix("AntiGravity") }
            return false
        })
        XCTAssertEqual(grown.frame.width, 153, "the column grows to everything the row can spare")

        // Two rows leave enough height for the slot to take two lines.
        let firstLines = long.compactMap { box -> String? in
            if case let .text(value, _, _) = box.content { return value }
            return nil
        }
        XCTAssertTrue(firstLines.contains("AntiGravity"))
        XCTAssertTrue(firstLines.contains("Claude and GPT Models · Weekly"))
    }

    /// The panel never abbreviates, and the naming change is where an
    /// abbreviation would most easily creep back in.
    func testNoDefaultLabelIsAnAbbreviation() {
        let banned: Set<String> = ["WK", "5H", "7D", "30D", "GPT+", "Claude+"]
        for field in MenuBarFieldCatalog.allFields {
            let label = EInkSlotLabel.default(for: field.id)
            for word in label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
                XCTAssertFalse(banned.contains(word), "\(field.id) prints \"\(label)\"")
            }
            XCTAssertFalse(label.contains(" + "), "\(field.id) prints \"\(label)\"")
        }
    }
}
