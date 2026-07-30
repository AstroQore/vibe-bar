import XCTest
@testable import VibeBarCore

/// `PageLayoutMode.compact` lives or dies on this being both optimal and
/// stable, so the tests pin exact partitions rather than "looks balanced":
/// a packing that changes between runs would move cards under the user.
final class PageLayoutPackerTests: XCTestCase {

    // MARK: - Helpers

    private func module(_ name: String) -> PageLayoutModuleID {
        PageLayoutModuleID(rawValue: name)
    }

    private func items(_ pairs: [(String, Double)]) -> [PageLayoutPacker.Item] {
        pairs.map { PageLayoutPacker.Item(id: module($0.0), height: $0.1) }
    }

    // MARK: - Degenerate input

    func testEmptyInputYieldsTwoEmptyColumns() {
        let packing = PageLayoutPacker.pack(items: [], spacing: 10)

        XCTAssertEqual(packing.columns, [[], []])
        XCTAssertEqual(packing.columnHeights, [0, 0])
        XCTAssertEqual(packing.pageHeight, 0)
        XCTAssertTrue(packing.isExact)
    }

    func testSingleModuleTakesTheLeftColumnAndCarriesNoSpacing() {
        let packing = PageLayoutPacker.pack(items: items([("a", 240)]), spacing: 12)

        XCTAssertEqual(packing.columns, [[module("a")], []])
        // One card in a column means no neighbour, so no gap.
        XCTAssertEqual(packing.columnHeights, [240, 0])
        XCTAssertEqual(packing.pageHeight, 240)
    }

    func testDuplicateIdentifiersCollapseToTheFirstOccurrence() {
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("a", 900), ("b", 100)]),
            spacing: 0
        )

        XCTAssertEqual(packing.columns.flatMap { $0 }.count, 2)
        // The 900 is the duplicate and never reaches the arrangement.
        XCTAssertEqual(packing.pageHeight, 100)
    }

    func testEmptyIdentifiersAreDropped() {
        let packing = PageLayoutPacker.pack(
            items: items([("", 500), ("a", 100)]),
            spacing: 0
        )

        XCTAssertEqual(packing.columns, [[module("a")], []])
    }

    func testNonFiniteAndNegativeHeightsAreClampedToZero() {
        let packing = PageLayoutPacker.pack(
            items: [
                PageLayoutPacker.Item(id: module("nan"), height: .nan),
                PageLayoutPacker.Item(id: module("infinite"), height: .infinity),
                PageLayoutPacker.Item(id: module("negative"), height: -400)
            ],
            spacing: 0
        )

        // Nothing has a usable height, so nothing can make the page taller.
        XCTAssertEqual(packing.pageHeight, 0)
        XCTAssertEqual(packing.columns.flatMap { $0 }.count, 3)
    }

    func testNonFiniteSpacingIsTreatedAsNoGap() {
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("b", 100), ("c", 100)]),
            spacing: .nan
        )

        XCTAssertEqual(packing.pageHeight, 200)
    }

    // MARK: - The objective

    func testEqualCardsAreSplitRatherThanStacked() {
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("b", 100)]),
            spacing: 10
        )

        XCTAssertEqual(packing.columns, [[module("a")], [module("b")]])
        XCTAssertEqual(packing.pageHeight, 100)
    }

    func testSpacingIsCountedBetweenNeighboursOnly() {
        // Three cards that cannot be split evenly: two of them share a column
        // and pay exactly one gap between them.
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("b", 100), ("c", 100)]),
            spacing: 10
        )

        XCTAssertEqual(packing.columns, [[module("a"), module("b")], [module("c")]])
        XCTAssertEqual(packing.columnHeights, [210, 100])
        XCTAssertEqual(packing.pageHeight, 210)
    }

    func testFourEqualCardsSplitTwoAndTwoInInputOrder() {
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("b", 100), ("c", 100), ("d", 100)]),
            spacing: 10
        )

        XCTAssertEqual(
            packing.columns,
            [[module("a"), module("b")], [module("c"), module("d")]]
        )
        XCTAssertEqual(packing.pageHeight, 210)
    }

    func testUnevenCardsFindThePartitionThatMinimizesTheTallerColumn() {
        // 300 / 200 / 150 / 50: the only split that gets both sides to 350 is
        // {300, 50} against {200, 150}, which greedy largest-first also finds,
        // but only after rejecting the obvious {300} / {200,150,50}.
        let packing = PageLayoutPacker.pack(
            items: items([("a", 300), ("b", 200), ("c", 150), ("d", 50)]),
            spacing: 0
        )

        XCTAssertEqual(packing.pageHeight, 350)
        XCTAssertEqual(packing.columnHeights, [350, 350])
        XCTAssertEqual(
            Set(packing.columns[0]),
            Set([module("a"), module("d")])
        )
    }

    func testWithinAColumnCardsKeepTheirInputOrder() {
        // Input order is the page's default reading order, so a compact page
        // still reads top to bottom the way the user expects.
        let packing = PageLayoutPacker.pack(
            items: items([("a", 90), ("b", 10), ("c", 10), ("d", 90)]),
            spacing: 0
        )

        for column in packing.columns {
            let positions = column.map { id in
                ["a", "b", "c", "d"].firstIndex(of: id.rawValue) ?? -1
            }
            XCTAssertEqual(positions, positions.sorted())
        }
    }

    // MARK: - Tie-breaking

    func testTiesKeepTheEarliestCardsInTheLeftColumn() {
        // Every 2/1 split of three equal cards makes the same 210 pt page. The
        // winner is the one that leaves the first cards where the page's
        // default already had them.
        let packing = PageLayoutPacker.pack(
            items: items([("a", 100), ("b", 100), ("c", 100)]),
            spacing: 10
        )

        XCTAssertEqual(packing.columns[0], [module("a"), module("b")])
    }

    func testRatioBreaksTiesTowardTheWiderColumn() {
        let pairs = [("a", 100.0), ("b", 50.0)]

        // Mirror images: one card each, 100 pt page either way. With no wider
        // side to prefer, the left-first tie-break decides.
        let equal = PageLayoutPacker.pack(items: items(pairs), spacing: 0, ratio: .equal)
        XCTAssertEqual(equal.columns, [[module("a")], [module("b")]])
        XCTAssertEqual(equal.pageHeight, 100)

        // Left is the wide side, and the heavier card belongs under it.
        let wideLeft = PageLayoutPacker.pack(items: items(pairs), spacing: 0, ratio: .wideNarrow)
        XCTAssertEqual(wideLeft.columns, [[module("a")], [module("b")]])

        // Right is the wide side, so the same two cards swap.
        let wideRight = PageLayoutPacker.pack(items: items(pairs), spacing: 0, ratio: .narrowWide)
        XCTAssertEqual(wideRight.columns, [[module("b")], [module("a")]])
        XCTAssertEqual(wideRight.pageHeight, 100)
    }

    func testPackingIsDeterministic() {
        let input = items([
            ("a", 317), ("b", 208), ("c", 96), ("d", 451), ("e", 133), ("f", 274)
        ])

        let first = PageLayoutPacker.pack(items: input, spacing: 9, ratio: .wideNarrow)
        let second = PageLayoutPacker.pack(items: input, spacing: 9, ratio: .wideNarrow)

        XCTAssertEqual(first, second)
    }

    // MARK: - Why `compact` exists

    func testCompactBeatsThePhaseConstrainedBalancer() {
        // AQ's report in one test: his hand-packed Overview was shorter than
        // the auto balancer's. The balancer places every quota card before any
        // cost card, and that constraint alone costs this page 110 pt —
        // `compact` drops it and optimizes for height alone.
        let spacing = 10.0
        let heights: [(String, Double, OverviewMasonryPlanner.Phase)] = [
            ("quota-1", 300, .quota),
            ("quota-2", 300, .quota),
            ("quota-3", 120, .quota),
            ("quota-4", 120, .quota),
            ("cost-1", 500, .cost),
            ("cost-2", 260, .cost)
        ]

        let balanced = OverviewMasonryPlanner.plan(
            items: heights.map {
                OverviewMasonryPlanner.Item(id: $0.0, height: $0.1, phase: $0.2)
            },
            columns: 2,
            spacing: spacing
        )
        let packed = PageLayoutPacker.pack(
            items: items(heights.map { ($0.0, $0.1) }),
            spacing: spacing
        )

        XCTAssertEqual(balanced.columnHeights.max(), 940)
        XCTAssertEqual(packed.pageHeight, 830)
        XCTAssertLessThan(packed.pageHeight, balanced.columnHeights.max() ?? 0)

        // Every card still placed exactly once.
        XCTAssertEqual(Set(packed.columns.flatMap { $0 }).count, heights.count)
    }

    func testCompactIgnoresPhaseGroupingAndMixesQuotaWithCost() {
        let packed = PageLayoutPacker.pack(
            items: items([
                ("quota-1", 300), ("quota-2", 300), ("quota-3", 120), ("quota-4", 120),
                ("cost-1", 500), ("cost-2", 260)
            ]),
            spacing: 10
        )

        // Neither column is purely quota or purely cost — which is exactly the
        // arrangement the phased balancer cannot reach.
        for column in packed.columns {
            let families = Set(column.map { $0.rawValue.split(separator: "-").first.map(String.init) ?? "" })
            XCTAssertGreaterThan(families.count, 1)
        }
    }

    // MARK: - Search limits

    func testModuleCountsUpToTheLimitAreSearchedExactly() {
        let exact = PageLayoutPacker.pack(
            items: items((0..<PageLayoutPacker.exactSearchLimit).map { ("m\($0)", Double(10 + $0)) }),
            spacing: 4
        )

        XCTAssertTrue(exact.isExact)
    }

    func testBeyondTheLimitTheGreedyFallbackTakesOverAndStillBalances() {
        let count = PageLayoutPacker.exactSearchLimit + 1
        let ids = (0..<count).map { "m\($0)" }
        let packing = PageLayoutPacker.pack(
            items: items(ids.map { ($0, 100.0) }),
            spacing: 0
        )

        XCTAssertFalse(packing.isExact)
        // Longest-processing-time-first alternates 17 equal cards 9 / 8.
        XCTAssertEqual(packing.columns[0].count, 9)
        XCTAssertEqual(packing.columns[1].count, 8)
        XCTAssertEqual(packing.columnHeights, [900, 800])
        // Still one column each, still in input order.
        XCTAssertEqual(Set(packing.columns.flatMap { $0 }).count, count)
        XCTAssertEqual(
            packing.columns[0],
            stride(from: 0, to: count, by: 2).map { module("m\($0)") }
        )
    }

    func testGreedyFallbackNeverLosesOrDuplicatesACard() {
        let count = 24
        let packing = PageLayoutPacker.pack(
            items: items((0..<count).map { ("m\($0)", Double(20 + ($0 * 37) % 260)) }),
            spacing: 8
        )

        let placed = packing.columns.flatMap { $0 }
        XCTAssertEqual(placed.count, count)
        XCTAssertEqual(Set(placed).count, count)
    }

    // MARK: - Measuring an arrangement

    func testStackedHeightSumsCardsAndTheGapsBetweenThem() {
        let heights: [PageLayoutModuleID: Double] = [
            module("a"): 100,
            module("b"): 50,
            module("c"): 25
        ]

        XCTAssertEqual(
            PageLayoutPacker.stackedHeight(
                [module("a"), module("b"), module("c")],
                heights: heights,
                spacing: 10
            ),
            195
        )
        XCTAssertEqual(
            PageLayoutPacker.stackedHeight([module("a")], heights: heights, spacing: 10),
            100
        )
        XCTAssertEqual(
            PageLayoutPacker.stackedHeight([], heights: heights, spacing: 10),
            0
        )
        // A card the page has never measured contributes no height, but it is
        // still a card, so the gap on either side of it is real.
        XCTAssertEqual(
            PageLayoutPacker.stackedHeight(
                [module("a"), module("unmeasured")],
                heights: heights,
                spacing: 10
            ),
            110
        )
    }

    func testPageHeightIsTheTallerColumn() {
        let heights: [PageLayoutModuleID: Double] = [
            module("a"): 100,
            module("b"): 50,
            module("c"): 25
        ]

        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                columns: [[module("a"), module("b")], [module("c")]],
                heights: heights,
                spacing: 10
            ),
            160
        )
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(columns: [[], []], heights: heights, spacing: 10),
            0
        )
    }

    func testPageHeightMeasuresTheArrangementThePackerChose() {
        let input = items([("a", 300), ("b", 200), ("c", 150), ("d", 50)])
        let packing = PageLayoutPacker.pack(items: input, spacing: 7)
        let heights = Dictionary(uniqueKeysWithValues: input.map { ($0.id, $0.height) })

        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                columns: packing.columns,
                heights: heights,
                spacing: 7
            ),
            packing.pageHeight
        )
    }

    // MARK: - Config bridge

    func testPackedConfigCarriesTheRatioColumnsAndHeights() {
        let input = items([("a", 300), ("b", 200), ("c", 150), ("d", 50)])
        let measured: [PageLayoutModuleID: Double] = [module("a"): 300]

        let config = PageLayoutPacker.packedConfig(
            items: input,
            spacing: 6,
            ratio: .wideNarrow,
            measuredHeights: measured
        )

        XCTAssertEqual(config.ratio, .wideNarrow)
        XCTAssertEqual(config.columns.count, PageLayoutConfig.columnCount)
        XCTAssertEqual(
            config.columns,
            PageLayoutPacker.pack(items: input, spacing: 6, ratio: .wideNarrow).columns
        )
        XCTAssertEqual(config.measuredHeight(for: module("a")), 300)
        // Straight through `PageLayoutConfig`, so the invariants hold.
        XCTAssertEqual(Set(config.moduleIDs).count, config.moduleIDs.count)
    }

    // MARK: - Segments

    func testALaterSegmentFlowsUpIntoTheColumnAnEarlierOneLeftShort() {
        // The bug segments used to have, in one test. Segment 0 is lopsided:
        // 400 pt on the left, 100 pt on the right. Packed as independent bands,
        // segment 1 split its two cards one per column and both waited for the
        // 400 pt column to finish — a 300 pt hole under `short`, and a page of
        // 400 + 10 + 50 = 460 pt. As a relay, segment 1 starts from (400, 100)
        // and puts *both* its cards in the short column, filling the hole and
        // leaving the page exactly as tall as segment 0 already made it.
        let packed = PageLayoutPacker.pack(
            segments: [
                items([("tall", 400), ("short", 100)]),
                items([("a", 50), ("b", 50)])
            ],
            spacing: 10
        )

        XCTAssertEqual(packed.count, 2)
        XCTAssertEqual(packed[0].columns, [[module("tall")], [module("short")]])
        XCTAssertEqual(packed[0].columnHeights, [400, 100])
        XCTAssertEqual(packed[1].columns, [[], [module("a"), module("b")]])
        // Seeds included, so the last segment's heights are the page's.
        XCTAssertEqual(packed[1].columnHeights, [400, 220])
        XCTAssertEqual(packed[1].pageHeight, 400)
        XCTAssertLessThan(packed[1].pageHeight, 460)

        // Membership still never crosses a segment: that is the constraint the
        // relay preserves while removing the gap.
        XCTAssertEqual(
            Set(packed[0].columns.flatMap { $0 }),
            [module("tall"), module("short")]
        )
        XCTAssertEqual(Set(packed[1].columns.flatMap { $0 }), [module("a"), module("b")])
    }

    func testSegmentingCanStillCostHeightBecauseEarlierSegmentsChooseFirst() {
        // The relay is greedy across segments, not globally optimal, so
        // segmenting is still a trade — it just no longer pays for a gap.
        // Free, {a,b} and {c} pair off into a 20 pt page. Segment 0 has only its
        // own two cards to balance, splits them one each, and leaves segment 1's
        // single 20 pt card nowhere better than a 30 pt column.
        let first = items([("a", 10), ("b", 10)])
        let second = items([("c", 20)])
        let heights = Dictionary(
            uniqueKeysWithValues: (first + second).map { ($0.id, $0.height) }
        )

        let free = PageLayoutPacker.pack(items: first + second, spacing: 0)
        let relayed = PageLayoutPacker.pageHeight(
            segments: PageLayoutPacker.packedSegmentColumns(
                segments: [first, second],
                spacing: 0
            ),
            heights: heights,
            spacing: 0
        )

        XCTAssertEqual(free.pageHeight, 20)
        XCTAssertEqual(relayed, 30)
    }

    func testSegmentPackingIsTheSameAnswerAsPackingThatBandAlone() {
        let band = items([("a", 300), ("b", 200), ("c", 150), ("d", 50)])

        XCTAssertEqual(
            PageLayoutPacker.pack(segments: [band], spacing: 8, ratio: .wideNarrow)[0].columns,
            PageLayoutPacker.pack(items: band, spacing: 8, ratio: .wideNarrow).columns
        )
    }

    func testAnIdentifierInTwoSegmentsIsKeptOnlyInTheFirst() {
        // A hand-edited file must not make one card render twice.
        let packed = PageLayoutPacker.pack(
            segments: [items([("a", 100)]), items([("a", 100), ("b", 40)])],
            spacing: 10
        )

        XCTAssertEqual(packed[0].columns.flatMap { $0 }, [module("a")])
        XCTAssertEqual(packed[1].columns.flatMap { $0 }, [module("b")])
    }

    func testAnEmptySegmentPacksToEmptyColumnsAndHandsTheRelayOnUntouched() {
        let packed = PageLayoutPacker.pack(
            segments: [items([("a", 100)]), [], items([("b", 100)])],
            spacing: 10
        )

        XCTAssertEqual(packed[1].columns, [[], []])
        // A segment with nothing in it must not reset the columns to zero, or
        // everything below it would be planned against a page that does not
        // exist.
        XCTAssertEqual(packed[1].columnHeights, packed[0].columnHeights)
        XCTAssertEqual(packed[0].columnHeights, [100, 0])
        // `b` still lands beside `a` rather than under it.
        XCTAssertEqual(packed[2].columns, [[], [module("b")]])
        XCTAssertEqual(packed[2].columnHeights, [100, 100])
    }

    func testSeedsShiftWhereThePackerStartsAndCountTowardsTheAnswer() {
        // The relay's primitive, on its own: with the left column already 300 pt
        // tall and occupied, a 100 pt card belongs on the right even though the
        // right column would be the taller one considered in isolation.
        let seeded = PageLayoutPacker.pack(
            items: items([("a", 100)]),
            spacing: 10,
            seeds: [
                PageLayoutPacker.ColumnSeed(height: 300, isOccupied: true),
                PageLayoutPacker.ColumnSeed(height: 0, isOccupied: false)
            ]
        )

        XCTAssertEqual(seeded.columns, [[], [module("a")]])
        // The right column was empty, so the card pays no gap; the left column's
        // seed rides through untouched.
        XCTAssertEqual(seeded.columnHeights, [300, 100])
        XCTAssertEqual(seeded.pageHeight, 300)

        // Occupied but zero-height is not the same as empty: the gap is owed to
        // the card that is there, not to the height it happens to measure.
        let occupiedButEmptyLooking = PageLayoutPacker.pack(
            items: items([("a", 100)]),
            spacing: 10,
            seeds: [
                PageLayoutPacker.ColumnSeed(height: 0, isOccupied: true),
                PageLayoutPacker.ColumnSeed(height: 0, isOccupied: true)
            ]
        )
        XCTAssertEqual(occupiedButEmptyLooking.columnHeights, [110, 0])
    }

    func testFlowColumnsConcatenateEachColumnInSegmentOrder() {
        let flowed = PageLayoutPacker.flowColumns(
            segments: [
                [[module("a")], [module("b")]],
                [[], [module("c")]],
                [[module("d")], []]
            ]
        )

        XCTAssertEqual(flowed, [[module("a"), module("d")], [module("b"), module("c")]])
    }

    func testSegmentedPageHeightIsTheTallerColumnOnceEverySegmentHasFlowedIn() {
        let heights: [PageLayoutModuleID: Double] = [
            module("a"): 100,
            module("b"): 50,
            module("c"): 200
        ]

        // The left column holds only `a`; the right holds `b` then `c` with one
        // gap between them. Nothing lines up at the boundary, so the page is
        // 260 pt — not the 100 + 10 + 200 = 310 pt a stack of rigid bands cost,
        // which is the 50 pt hole the user was looking at.
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                segments: [
                    [[module("a")], [module("b")]],
                    [[], [module("c")]]
                ],
                heights: heights,
                spacing: 10
            ),
            260
        )
        // One segment is a plain page.
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                segments: [[[module("a")], [module("b")]]],
                heights: heights,
                spacing: 10
            ),
            100
        )
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(segments: [], heights: heights, spacing: 10),
            0
        )
    }

    func testSegmentedPageHeightMeasuresWhatTheSegmentedPackerChose() {
        let bands = [items([("a", 300), ("b", 200)]), items([("c", 150), ("d", 50)])]
        let packed = PageLayoutPacker.pack(segments: bands, spacing: 7)
        let heights = Dictionary(
            uniqueKeysWithValues: bands.flatMap { $0 }.map { ($0.id, $0.height) }
        )

        // Segment 0 splits 300 / 200; segment 1 then puts the 150 under the 200
        // and the 50 under the 300, landing both columns on 357.
        XCTAssertEqual(packed[1].columns, [[module("d")], [module("c")]])
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                segments: packed.map(\.columns),
                heights: heights,
                spacing: 7
            ),
            357
        )
        // The measurement and the packer agree, and the last segment's own
        // heights already carry the whole page.
        XCTAssertEqual(
            PageLayoutPacker.pageHeight(
                segments: packed.map(\.columns),
                heights: heights,
                spacing: 7
            ),
            packed[packed.count - 1].pageHeight
        )
    }
}
