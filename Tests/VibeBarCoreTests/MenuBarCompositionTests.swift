import XCTest
@testable import VibeBarCore

/// The composed menu-bar strip: what each block renders, when a block is on
/// screen, what colour it ends up asking for, and what survives a settings
/// file round trip.
final class MenuBarCompositionTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private func quota(
        _ fieldId: String = "claude.five_hour",
        tool: ToolType = .claude,
        label: String = "5 Hours",
        used: Double = 73,
        display: Double? = nil,
        resetAt: Date? = nil,
        pace: Double? = nil,
        forecast: MenuBarQuotaSnapshot.Forecast? = nil
    ) -> MenuBarQuotaSnapshot {
        MenuBarQuotaSnapshot(
            fieldId: fieldId,
            tool: tool,
            label: label,
            usedPercent: used,
            displayPercent: display ?? used,
            resetAt: resetAt,
            paceDeltaPercent: pace,
            forecast: forecast
        )
    }

    private func composition(
        _ tokens: [MenuBarToken],
        template: MenuBarComposition.Template = .roomy
    ) -> MenuBarComposition {
        MenuBarComposition(isEnabled: true, template: template, tokens: tokens)
    }

    private func plan(
        _ tokens: [MenuBarToken],
        quotas: [MenuBarQuotaSnapshot],
        displayMode: DisplayMode = .used,
        colorBasis: MenuBarColorBasis = .actual,
        now: Date? = nil
    ) -> MenuBarRenderPlan {
        composition(tokens).plan(
            quotas: quotas,
            displayMode: displayMode,
            colorBasis: colorBasis,
            now: now ?? reference
        )
    }

    private func texts(_ plan: MenuBarRenderPlan) -> [[String]] {
        plan.rows.map { $0.tokens.compactMap(\.text) }
    }

    // MARK: - Metric formats

    func testPercentMetricsRenderRoundedWholePercentages() {
        let snapshot = quota(used: 72.6, display: 27.4)
        XCTAssertEqual(metric(.usedPercent, snapshot), "73%")
        XCTAssertEqual(metric(.remainingPercent, snapshot), "27%")
        XCTAssertEqual(metric(.displayPercent, snapshot), "27%")
    }

    func testRemainingIsDerivedFromTheRawObservationAndClamped() {
        XCTAssertEqual(metric(.remainingPercent, quota(used: 0)), "100%")
        XCTAssertEqual(metric(.remainingPercent, quota(used: 100)), "0%")
    }

    func testPaceRendersASignedDelta() {
        XCTAssertEqual(metric(.pace, quota(pace: 12.4)), "+12%")
        XCTAssertEqual(metric(.pace, quota(pace: -8)), "-8%")
        XCTAssertEqual(metric(.pace, quota(pace: 0.2)), "±0%")
        // No window, no reset date, or a cycle past its grace: nothing to say.
        XCTAssertNil(metric(.pace, quota(pace: nil)))
    }

    func testForecastMetricsReadTheProjection() {
        let forecast = MenuBarQuotaSnapshot.Forecast(
            verdict: .watch,
            projectedRemainingPercent: 18.4,
            runOutAt: reference.addingTimeInterval(3600 * 52)
        )
        XCTAssertEqual(metric(.forecastPercent, quota(forecast: forecast)), "18%")
        XCTAssertEqual(metric(.runsOutIn, quota(forecast: forecast)), "2d 4h")
        // A quota with no forecast yet prints neither rather than guessing.
        XCTAssertNil(metric(.forecastPercent, quota()))
        XCTAssertNil(metric(.runsOutIn, quota()))
        // A forecast that does not predict exhaustion has no ETA to print.
        XCTAssertNil(metric(.runsOutIn, quota(forecast: MenuBarQuotaSnapshot.Forecast(
            verdict: .enough,
            projectedRemainingPercent: 40
        ))))
    }

    func testResetMetricsUseTheSharedCountdownFormatter() {
        let resetAt = reference.addingTimeInterval(3600 * 3 + 60 * 16)
        XCTAssertEqual(metric(.resetsIn, quota(resetAt: resetAt)), "3h 16m")
        XCTAssertNil(metric(.resetsIn, quota(resetAt: nil)))
        XCTAssertNil(metric(.resetAt, quota(resetAt: nil)))

        // `resetAt` is the local wall time, so derive the expectation from the
        // same calendar the formatter uses rather than hard-coding a zone.
        let parts = Calendar.current.dateComponents([.hour, .minute], from: resetAt)
        XCTAssertEqual(
            metric(.resetAt, quota(resetAt: resetAt)),
            String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        )
    }

    func testLabelMetricPrintsTheQuotasOwnName() {
        XCTAssertEqual(metric(.label, quota(label: "Weekly")), "Weekly")
        XCTAssertNil(metric(.label, quota(label: "   ")))
    }

    private func metric(_ metric: MenuBarQuotaMetric, _ snapshot: MenuBarQuotaSnapshot) -> String? {
        MenuBarComposition.value(
            of: metric,
            in: snapshot,
            displayMode: .remaining,
            now: reference
        )
    }

    // MARK: - Visibility

    func testAlwaysAndThresholdRules() {
        let snapshot = quota(used: 80)
        XCTAssertTrue(MenuBarComposition.isVisible(.always, quotas: [snapshot]))
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenUsedAtLeast(fieldId: snapshot.fieldId, percent: 80), quotas: [snapshot]
        ))
        XCTAssertFalse(MenuBarComposition.isVisible(
            .whenUsedAtLeast(fieldId: snapshot.fieldId, percent: 81), quotas: [snapshot]
        ))
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenRemainingAtMost(fieldId: snapshot.fieldId, percent: 20), quotas: [snapshot]
        ))
        XCTAssertFalse(MenuBarComposition.isVisible(
            .whenRemainingAtMost(fieldId: snapshot.fieldId, percent: 19), quotas: [snapshot]
        ))
    }

    func testARuleThatCannotBeEvaluatedNeverHidesItsBlock() {
        // The quota was removed from the catalog, or the provider stopped
        // returning it: hiding the block would leave the user no way to find
        // it again, and looks exactly like a broken app.
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenUsedAtLeast(fieldId: "gone.bucket", percent: 90), quotas: [quota()]
        ))
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenRemainingAtMost(fieldId: "gone.bucket", percent: 5), quotas: [quota()]
        ))
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenForecast(fieldId: "gone.bucket", verdicts: [.atRisk]), quotas: [quota()]
        ))
        // Same reasoning while the forecast is still learning: the rule has no
        // verdict to test, so it does not get to suppress the block.
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenForecast(fieldId: "claude.five_hour", verdicts: [.atRisk]),
            quotas: [quota(forecast: nil)]
        ))
    }

    func testForecastRuleMatchesOnlyItsVerdicts() {
        let atRisk = quota(forecast: .init(verdict: .atRisk, projectedRemainingPercent: 0))
        let enough = quota(forecast: .init(verdict: .enough, projectedRemainingPercent: 40))
        XCTAssertTrue(MenuBarComposition.isVisible(
            .whenForecast(fieldId: atRisk.fieldId, verdicts: [.atRisk, .watch]), quotas: [atRisk]
        ))
        XCTAssertFalse(MenuBarComposition.isVisible(
            .whenForecast(fieldId: enough.fieldId, verdicts: [.atRisk, .watch]), quotas: [enough]
        ))
    }

    func testHiddenBlocksLeaveTheStrip() {
        let snapshot = quota(used: 10)
        let rendered = plan(
            [
                MenuBarToken(kind: .text("A")),
                MenuBarToken(
                    kind: .text("B"),
                    visibility: .whenUsedAtLeast(fieldId: snapshot.fieldId, percent: 90)
                ),
                MenuBarToken(kind: .text("C"))
            ],
            quotas: [snapshot]
        )
        XCTAssertEqual(texts(rendered), [["A", "C"]])
    }

    // MARK: - Plan

    func testRowsSplitOnLineBreak() {
        let rendered = plan(
            [
                MenuBarToken(kind: .text("top")),
                MenuBarToken(kind: .lineBreak),
                MenuBarToken(kind: .text("bottom"))
            ],
            quotas: []
        )
        XCTAssertEqual(texts(rendered), [["top"], ["bottom"]])
    }

    func testAThirdRowFoldsBackIntoTheSecond() {
        // The status item cannot draw a third band; its blocks stay visible on
        // the second row rather than disappearing.
        let rendered = plan(
            [
                MenuBarToken(kind: .text("one")),
                MenuBarToken(kind: .lineBreak),
                MenuBarToken(kind: .text("two")),
                MenuBarToken(kind: .lineBreak),
                MenuBarToken(kind: .text("three"))
            ],
            quotas: []
        )
        XCTAssertEqual(rendered.rows.count, MenuBarComposition.maximumRows)
        XCTAssertEqual(texts(rendered), [["one"], ["two", "three"]])
    }

    func testAnUnavailableQuotaDropsOnlyItsOwnBlock() {
        let rendered = plan(
            [
                MenuBarToken(kind: .text("Claude")),
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent)),
                MenuBarToken(kind: .separator("/"), style: .divider),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .displayPercent))
            ],
            quotas: [quota("claude.five_hour", used: 40)]
        )
        XCTAssertEqual(texts(rendered), [["Claude", "40%", "/"]])
        XCTAssertFalse(rendered.isEmpty)
    }

    func testAStripWhoseQuotasAreAllMissingIsEmpty() {
        let rendered = plan(
            [MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))],
            quotas: []
        )
        XCTAssertTrue(rendered.isEmpty)
    }

    func testTemplateSuppliesSpacingAndScaleUnlessOverridden() {
        let roomy = MenuBarComposition(template: .roomy)
        XCTAssertEqual(roomy.effectiveTokenSpacing, MenuBarComposition.Template.roomy.tokenSpacing)
        XCTAssertEqual(roomy.effectiveFontScale, MenuBarComposition.Template.roomy.fontScale)

        let tuned = MenuBarComposition(template: .roomy, fontScale: 9, tokenSpacing: -3)
        // Clamped rather than rejected: a bad number should not be able to
        // render the menu bar unusable.
        XCTAssertEqual(tuned.effectiveFontScale, MenuBarComposition.fontScaleRange.upperBound)
        XCTAssertEqual(tuned.effectiveTokenSpacing, MenuBarComposition.tokenSpacingRange.lowerBound)
    }

    func testSizeStepScalesOnTopOfTheTemplate() {
        let rendered = MenuBarComposition(
            isEnabled: true,
            template: .compact,
            tokens: [
                MenuBarToken(kind: .text("s"), style: .init(size: .small)),
                MenuBarToken(kind: .text("l"), style: .init(size: .large))
            ]
        ).plan(quotas: [], displayMode: .used, colorBasis: .actual, now: reference)
        let scale = MenuBarComposition.Template.compact.fontScale
        XCTAssertEqual(rendered.rows[0].tokens[0].fontScale, scale * 0.85, accuracy: 1e-9)
        XCTAssertEqual(rendered.rows[0].tokens[1].fontScale, scale * 1.2, accuracy: 1e-9)
    }

    // MARK: - Colour

    func testAutomaticFollowsTheAppWideBasisForTheBlocksOwnQuota() {
        let token = MenuBarToken(
            kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent),
            style: .percent
        )
        let actual = plan([token], quotas: [quota()], colorBasis: .actual)
        XCTAssertEqual(
            actual.rows[0].tokens[0].color,
            .quota(fieldId: "claude.five_hour", basis: .actual)
        )
        let forecast = plan([token], quotas: [quota()], colorBasis: .forecast)
        XCTAssertEqual(
            forecast.rows[0].tokens[0].color,
            .quota(fieldId: "claude.five_hour", basis: .forecast)
        )
    }

    func testAutomaticOnABlockWithNoQuotaIsPrimary() {
        let rendered = plan(
            [MenuBarToken(kind: .text("hi"), style: .init(color: .automatic))],
            quotas: [quota()]
        )
        XCTAssertEqual(rendered.rows[0].tokens[0].color, .primary)
    }

    func testAnyBlockCanFollowAnotherQuotasColour() {
        let rendered = plan(
            [MenuBarToken(
                kind: .text("Claude"),
                style: .init(color: .followsQuota(fieldId: "claude.five_hour", basis: .forecast))
            )],
            quotas: [quota()]
        )
        XCTAssertEqual(
            rendered.rows[0].tokens[0].color,
            .quota(fieldId: "claude.five_hour", basis: .forecast)
        )
    }

    func testFollowingAMissingQuotaFallsBackWithoutHidingTheBlock() {
        let rendered = plan(
            [MenuBarToken(
                kind: .text("Claude"),
                style: .init(color: .followsQuota(fieldId: "gone.bucket", basis: .actual))
            )],
            quotas: [quota()]
        )
        XCTAssertEqual(texts(rendered), [["Claude"]])
        XCTAssertEqual(rendered.rows[0].tokens[0].color, .primary)
    }

    func testForcedForecastColourIgnoresTheAppWideBasis() {
        let rendered = plan(
            [MenuBarToken(
                kind: .quota(fieldId: "claude.five_hour", metric: .usedPercent),
                style: .init(color: .forecast)
            )],
            quotas: [quota()],
            colorBasis: .actual
        )
        XCTAssertEqual(
            rendered.rows[0].tokens[0].color,
            .quota(fieldId: "claude.five_hour", basis: .forecast)
        )
    }

    func testFixedColoursNormalizeAndBadOnesFallBack() {
        XCTAssertEqual(MenuBarHexColor.normalized("#F0A"), "#ff00aa")
        XCTAssertEqual(MenuBarHexColor.normalized("00FF00"), "#00ff00")
        XCTAssertEqual(MenuBarHexColor.normalized("#11223344"), "#11223344")
        XCTAssertNil(MenuBarHexColor.normalized("cornflower"))
        XCTAssertNil(MenuBarHexColor.normalized("#12345"))

        // `hex(_:)` canonicalizes at construction, so a picked swatch and a
        // hand-typed value are one stored value rather than two.
        XCTAssertEqual(MenuBarToken.ColorSource.hex("#F0A"), .fixed("#ff00aa"))
        XCTAssertEqual(MenuBarToken.ColorSource.hex("nope"), .primary)

        let good = plan(
            [MenuBarToken(kind: .text("x"), style: .init(color: .hex("#F0A")))],
            quotas: []
        )
        XCTAssertEqual(good.rows[0].tokens[0].color, .fixed(hex: "#ff00aa"))

        // Even a raw case that skipped the factory degrades rather than
        // painting something arbitrary.
        let bad = plan(
            [MenuBarToken(kind: .text("x"), style: .init(color: .fixed("nope")))],
            quotas: []
        )
        XCTAssertEqual(bad.rows[0].tokens[0].color, .primary)

        let parts = MenuBarHexColor.components("#ff8000")
        XCTAssertEqual(parts?.r ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(parts?.g ?? 0, 128.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(parts?.b ?? 0, 0.0, accuracy: 1e-9)
        XCTAssertEqual(parts?.a ?? 0, 1.0, accuracy: 1e-9)
    }

    // MARK: - Requirements

    func testReferencedFieldsAreDeduplicatedInFirstAppearanceOrder() {
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .label)),
            MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent)),
            MenuBarToken(
                kind: .text("!"),
                style: .init(color: .followsQuota(fieldId: "codex.weekly", basis: .actual))
            ),
            MenuBarToken(
                kind: .logo(.claude),
                visibility: .whenUsedAtLeast(fieldId: "gemini.weekly", percent: 50)
            )
        ])
        XCTAssertEqual(
            composed.referencedFieldIds,
            ["claude.five_hour", "codex.weekly", "gemini.weekly"]
        )
    }

    func testOnlyBlocksThatReadAForecastAskForOne() {
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .displayPercent)),
            MenuBarToken(kind: .quota(fieldId: "b.x", metric: .runsOutIn)),
            MenuBarToken(kind: .quota(fieldId: "c.x", metric: .pace)),
            MenuBarToken(kind: .text("!"), style: .init(color: .forecast))
        ])
        let byField = Dictionary(
            uniqueKeysWithValues: composed.quotaRequirements.map { ($0.fieldId, $0) }
        )
        XCTAssertEqual(byField["a.x"]?.needsForecast, false)
        XCTAssertEqual(byField["a.x"]?.needsPace, false)
        XCTAssertEqual(byField["b.x"]?.needsForecast, true)
        XCTAssertEqual(byField["c.x"]?.needsPace, true)
        XCTAssertEqual(byField["c.x"]?.needsForecast, false)
    }

    func testRequirementsMergeAcrossBlocksNamingTheSameQuota() {
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .displayPercent)),
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .pace)),
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .forecastPercent))
        ])
        XCTAssertEqual(composed.quotaRequirements.count, 1)
        XCTAssertEqual(composed.quotaRequirements[0].needsPace, true)
        XCTAssertEqual(composed.quotaRequirements[0].needsForecast, true)
    }

    // MARK: - Spoken description

    func testTheStripIsDescribedInWordsNotInTheDrawnShorthand() {
        let rendered = plan(
            [
                MenuBarToken(kind: .logo(.claude)),
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent)),
                MenuBarToken(kind: .separator("/"), style: .divider),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .resetsIn)),
                MenuBarToken(kind: .lineBreak),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .forecastPercent))
            ],
            quotas: [
                quota("claude.five_hour", used: 5, display: 5),
                quota(
                    "claude.weekly",
                    label: "Weekly",
                    used: 100,
                    display: 100,
                    resetAt: reference.addingTimeInterval(3600 * 3),
                    forecast: .init(verdict: .atRisk, projectedRemainingPercent: 0)
                )
            ]
        )
        XCTAssertEqual(
            rendered.spokenDescription,
            "Claude, 5 Hours 5% used, Weekly resets in 3h · Weekly forecast 0% left at reset"
        )
        // Separators and spaces are drawing, not words.
        XCTAssertFalse(rendered.spokenDescription.contains("/"))
    }

    func testDisplayPercentIsSpokenWithTheModeTheUserPicked() {
        let used = plan(
            [MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))],
            quotas: [quota(used: 73, display: 73)],
            displayMode: .used
        )
        XCTAssertEqual(used.spokenDescription, "5 Hours 73% used")
        let remaining = plan(
            [MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))],
            quotas: [quota(used: 73, display: 27)],
            displayMode: .remaining
        )
        XCTAssertEqual(remaining.spokenDescription, "5 Hours 27% remaining")
    }

    // MARK: - Seeding

    private func fieldItem(
        merging: Bool = false,
        showTitle: Bool = false,
        styles: [String: MenuBarFieldStyle] = [:],
        labels: [String: String] = [:]
    ) -> MenuBarItemSettings {
        MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: showTitle,
            layout: .singleLine,
            selectedFieldIds: ["claude.five_hour", "claude.weekly"],
            customLabels: labels,
            fieldStyles: styles,
            mergesGroupWindows: merging
        )
    }

    func testSeedingReproducesTodaysUnmergedStrip() {
        let seeded = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        XCTAssertEqual(seeded.tokens.map(\.kind), [
            .text("5 Hours"),
            .quota(fieldId: "claude.five_hour", metric: .displayPercent),
            .separator(" · "),
            .text("Weekly"),
            .quota(fieldId: "claude.weekly", metric: .displayPercent)
        ])
        // Seeding never switches the mode on by itself.
        XCTAssertFalse(seeded.isEnabled)
    }

    func testSeedingFollowsTheGroupMergeAndTheFieldStyles() {
        let seeded = MenuBarComposition.seeded(
            template: .roomy,
            from: fieldItem(merging: true, styles: ["claude.five_hour": .logoLabelAndPercent])
        )
        XCTAssertEqual(seeded.tokens.map(\.kind), [
            .logo(.claude),
            .text("Claude"),
            .quota(fieldId: "claude.five_hour", metric: .displayPercent),
            .separator("/"),
            .quota(fieldId: "claude.weekly", metric: .displayPercent)
        ])
    }

    func testSeedingHonoursCustomLabelsAndTheTitleToggle() {
        let seeded = MenuBarComposition.seeded(
            template: .roomy,
            from: fieldItem(showTitle: true, labels: ["claude.five_hour": "C5"])
        )
        XCTAssertEqual(seeded.tokens.first?.kind, .text(MenuBarItemKind.compact.title))
        XCTAssertTrue(seeded.tokens.contains { $0.kind == .text("C5") })
    }

    func testTwoColumnTemplateSeedsALineBreak() {
        let seeded = MenuBarComposition.seeded(template: .twoColumn, from: fieldItem())
        XCTAssertTrue(seeded.tokens.contains { $0.kind == .lineBreak })
        let rendered = seeded.plan(
            quotas: [quota("claude.five_hour"), quota("claude.weekly", label: "Weekly")],
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        XCTAssertEqual(rendered.rows.count, 2)
        XCTAssertFalse(rendered.rows[1].isEmpty)
    }

    func testSeededPercentagesKeepTodaysColourAndFace() {
        let seeded = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        let percent = seeded.tokens.first { $0.metric == .displayPercent }
        XCTAssertEqual(percent?.style.color, .automatic)
        XCTAssertEqual(percent?.style.weight, .semibold)
        XCTAssertEqual(percent?.style.monospacedDigits, true)
    }

    // MARK: - Mode switching

    func testTurningCustomModeOnSeedsOnceAndTurningItOffKeepsEverything() {
        var item = fieldItem(labels: ["claude.five_hour": "C5"])
        XCTAssertNil(item.composition)
        XCTAssertFalse(item.usesComposedStrip)

        item.setComposedStripEnabled(true)
        XCTAssertTrue(item.usesComposedStrip)
        let seededKinds = item.composition?.tokens.map(\.kind)
        XCTAssertFalse(seededKinds?.isEmpty ?? true)

        // The user edits their strip.
        item.composition?.tokens.append(MenuBarToken(kind: .text("!")))
        let edited = item.composition?.tokens.map(\.kind)

        item.setComposedStripEnabled(false)
        XCTAssertFalse(item.usesComposedStrip)
        // Field mode is exactly as it was — the two modes never overwrite
        // each other.
        XCTAssertEqual(item.selectedFieldIds, ["claude.five_hour", "claude.weekly"])
        XCTAssertEqual(item.customLabels, ["claude.five_hour": "C5"])
        // ...and the composed arrangement survived being switched off.
        XCTAssertEqual(item.composition?.tokens.map(\.kind), edited)

        item.setComposedStripEnabled(true)
        XCTAssertTrue(item.usesComposedStrip)
        XCTAssertEqual(item.composition?.tokens.map(\.kind), edited, "re-enabling must not reseed")
    }

    func testReseedIsTheOnlyThingThatReplacesAStrip() {
        var item = fieldItem()
        item.setComposedStripEnabled(true)
        item.composition?.tokens = [MenuBarToken(kind: .text("mine"))]
        item.reseedComposedStrip(template: .twoColumn)
        XCTAssertNotEqual(item.composition?.tokens.map(\.kind), [.text("mine")])
        XCTAssertEqual(item.composition?.template, .twoColumn)
        // Reseeding does not change whether custom mode is on.
        XCTAssertTrue(item.usesComposedStrip)
    }

    // MARK: - Editing

    private func editable() -> MenuBarComposition {
        composition([
            MenuBarToken(kind: .text("a")),
            MenuBarToken(kind: .text("b")),
            MenuBarToken(kind: .text("c"))
        ])
    }

    func testInsertClampsInsteadOfTrapping() {
        var composed = editable()
        composed.insert(MenuBarToken(kind: .text("front")), at: -5)
        composed.insert(MenuBarToken(kind: .text("back")), at: 999)
        XCTAssertEqual(
            composed.tokens.map(\.kind),
            [.text("front"), .text("a"), .text("b"), .text("c"), .text("back")]
        )
    }

    func testRemoveReportsWhetherItFoundAnything() {
        var composed = editable()
        let id = composed.tokens[1].id
        XCTAssertTrue(composed.remove(id))
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("a"), .text("c")])
        XCTAssertFalse(composed.remove(id))
    }

    func testDuplicateCopiesInPlaceWithAFreshIdentity() {
        var composed = editable()
        let source = composed.tokens[1]
        let copyId = composed.duplicate(source.id)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("a"), .text("b"), .text("b"), .text("c")])
        XCTAssertNotNil(copyId)
        XCTAssertNotEqual(copyId, source.id)
        XCTAssertEqual(composed.tokens[2].id, copyId)
        // Two blocks that render identically are still two blocks.
        XCTAssertEqual(Set(composed.tokens.map(\.id)).count, 4)
        XCTAssertNil(composed.duplicate(UUID()))
    }

    func testMoveIsStatedInTermsOfTheResultingList() {
        var composed = editable()
        let a = composed.tokens[0].id
        composed.move(a, to: 2)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("b"), .text("c"), .text("a")])
        composed.move(a, to: 0)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("a"), .text("b"), .text("c")])
        // Out of range clamps to the ends rather than trapping.
        composed.move(a, to: 99)
        XCTAssertEqual(composed.tokens.last?.kind, .text("a"))
    }

    func testMoveBeforeWorksInBothDragDirections() {
        var composed = editable()
        let a = composed.tokens[0].id
        let c = composed.tokens[2].id
        // Rightwards: A lands where C was.
        composed.move(a, before: c)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("b"), .text("a"), .text("c")])
        // Leftwards: C lands in front of B.
        let b = composed.tokens[0].id
        composed.move(c, before: b)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("c"), .text("b"), .text("a")])
        // Dropping a block on itself changes nothing.
        composed.move(c, before: c)
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("c"), .text("b"), .text("a")])
    }

    func testLineBreaksStopBeingOfferedAtTheRowCap() {
        var composed = composition([MenuBarToken(kind: .text("a"))])
        XCTAssertTrue(composed.canAddLineBreak)
        composed.append(MenuBarToken(kind: .lineBreak))
        XCTAssertEqual(composed.lineBreakCount, 1)
        // One break is two rows, which is all the status item can draw.
        XCTAssertFalse(composed.canAddLineBreak)
    }

    // MARK: - Availability

    func testAvailabilitySeparatesSilentBlocksFromDegradedOnes() {
        let silent = MenuBarToken(kind: .quota(fieldId: "gone.bucket", metric: .displayPercent))
        let degradedColor = MenuBarToken(
            kind: .text("Claude"),
            style: .init(color: .followsQuota(fieldId: "gone.bucket", basis: .actual))
        )
        let degradedRule = MenuBarToken(
            kind: .logo(.claude),
            visibility: .whenUsedAtLeast(fieldId: "also.gone", percent: 50)
        )
        let fine = MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .label))
        let composed = composition([silent, degradedColor, degradedRule, fine])

        let availability = composed.availability(liveFieldIds: ["claude.five_hour"])
        XCTAssertEqual(availability.silentTokenIds, [silent.id])
        XCTAssertEqual(availability.degradedTokenIds, [degradedColor.id, degradedRule.id])
        XCTAssertEqual(availability.missingFieldIds, ["gone.bucket", "also.gone"])
        XCTAssertFalse(availability.isFullyAvailable)
    }

    func testASilentBlockIsNotAlsoReportedAsDegraded() {
        // One cause, one warning: a quota block whose own bucket is gone would
        // otherwise light up twice when its colour follows the same bucket.
        let token = MenuBarToken(
            kind: .quota(fieldId: "gone.bucket", metric: .displayPercent),
            style: .init(color: .followsQuota(fieldId: "gone.bucket", basis: .actual))
        )
        let availability = composition([token]).availability(liveFieldIds: [])
        XCTAssertEqual(availability.silentTokenIds, [token.id])
        XCTAssertTrue(availability.degradedTokenIds.isEmpty)
        XCTAssertEqual(availability.missingFieldIds, ["gone.bucket"])
    }

    func testEverythingLiveIsFullyAvailable() {
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent)),
            MenuBarToken(kind: .text("x"))
        ])
        XCTAssertTrue(composed.availability(liveFieldIds: ["claude.five_hour"]).isFullyAvailable)
    }

    // MARK: - Truncation

    func testALongTextBlockIsCutShortWithAnEllipsisButStillSpokenInFull() {
        let long = String(repeating: "x", count: 40)
        let rendered = plan([MenuBarToken(kind: .text(long))], quotas: [])
        let drawn = rendered.rows[0].tokens[0].text ?? ""
        XCTAssertEqual(drawn.count, MenuBarToken.maximumTextLength)
        XCTAssertTrue(drawn.hasSuffix("…"))
        XCTAssertEqual(rendered.spokenDescription, long)
    }

    func testTextAtTheLimitIsLeftAlone() {
        let exact = String(repeating: "y", count: MenuBarToken.maximumTextLength)
        let rendered = plan([MenuBarToken(kind: .text(exact))], quotas: [])
        XCTAssertEqual(rendered.rows[0].tokens[0].text, exact)
    }

    // MARK: - Persistence

    func testCompositionRoundTripsThroughTheSettingsFile() throws {
        let tokens = [
            MenuBarToken(kind: .logo(.codex), style: .init(color: .brand(.codex), size: .large)),
            MenuBarToken(kind: .text("Codex"), style: .label),
            MenuBarToken(
                kind: .quota(fieldId: "codex.weekly", metric: .runsOutIn),
                style: .init(color: .hex("#FF8000"), size: .small, weight: .regular, monospacedDigits: true),
                visibility: .whenForecast(fieldId: "codex.weekly", verdicts: [.atRisk, .watch])
            ),
            MenuBarToken(kind: .space),
            MenuBarToken(kind: .separator(" · "), style: .divider),
            MenuBarToken(kind: .lineBreak),
            MenuBarToken(
                kind: .quota(fieldId: "codex.five_hour", metric: .pace),
                style: .init(color: .followsQuota(fieldId: "codex.five_hour", basis: .forecast)),
                visibility: .whenRemainingAtMost(fieldId: "codex.five_hour", percent: 25)
            )
        ]
        let composed = MenuBarComposition(
            isEnabled: true,
            template: .twoColumn,
            tokens: tokens,
            fontScale: 1.1,
            tokenSpacing: 0.5
        )
        let data = try JSONEncoder().encode(composed)
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: data)
        XCTAssertEqual(decoded, composed)
    }

    func testItemDefaultsToNoCompositionAndOldFilesStillDecode() throws {
        let json = """
        {"kind":"compact","isVisible":true,"showTitle":true,"layout":"singleLine",
         "selectedFieldIds":["claude.five_hour"],"customLabels":{},"fieldStyles":{}}
        """
        let decoded = try JSONDecoder().decode(MenuBarItemSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.composition)
        XCTAssertFalse(decoded.usesComposedStrip)
    }

    func testCompositionSurvivesAnAppSettingsRoundTrip() throws {
        var settings = AppSettings(
            displayMode: .remaining,
            refreshIntervalSeconds: 600,
            launchAtLogin: false,
            menuBarTextEnabled: true,
            mockEnabled: false
        )
        var item = settings.menuBarItem(.compact)
        item.setComposedStripEnabled(true, template: .compact)
        item.composition?.tokens.append(MenuBarToken(kind: .text("tail")))
        settings.setMenuBarItem(item)

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        let restored = decoded.menuBarItem(.compact)
        XCTAssertTrue(restored.usesComposedStrip)
        XCTAssertEqual(restored.composition?.template, .compact)
        XCTAssertEqual(restored.composition?.tokens.last?.kind, .text("tail"))
    }

    func testAnUnreadableBlockDropsWithoutTakingTheStripDown() throws {
        let json = """
        {"isEnabled":true,"template":"roomy","tokens":[
          {"id":"11111111-1111-1111-1111-111111111111",
           "kind":{"type":"text","text":"keep"},
           "style":{"color":{"type":"primary"},"size":"regular","weight":"medium","monospacedDigits":false},
           "visibility":{"type":"always"}},
          {"id":"22222222-2222-2222-2222-222222222222",
           "kind":{"type":"sparkline","fieldId":"claude.weekly"},
           "style":{"color":{"type":"primary"},"size":"regular","weight":"medium","monospacedDigits":false},
           "visibility":{"type":"always"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tokens.map(\.kind), [.text("keep")])
    }

    func testUnreadableStyleAndRuleDegradeInsteadOfFailing() throws {
        let json = """
        {"isEnabled":true,"template":"kaleidoscope","tokens":[
          {"id":"33333333-3333-3333-3333-333333333333",
           "kind":{"type":"text","text":"x"},
           "style":{"color":{"type":"plaid"},"size":"regular","weight":"medium","monospacedDigits":false},
           "visibility":{"type":"whenTheMoonIsFull","fieldId":"claude.weekly"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        // An unknown template is the default one, not a decode failure.
        XCTAssertEqual(decoded.template, .roomy)
        XCTAssertEqual(decoded.tokens.count, 1)
        XCTAssertEqual(decoded.tokens[0].style.color, .primary)
        XCTAssertEqual(decoded.tokens[0].visibility, .always)
    }

    func testAnEmptyForecastRuleWouldHideForeverSoItDecodesToAlways() throws {
        let json = """
        {"isEnabled":true,"template":"roomy","tokens":[
          {"id":"44444444-4444-4444-4444-444444444444",
           "kind":{"type":"text","text":"x"},
           "style":{"color":{"type":"primary"},"size":"regular","weight":"medium","monospacedDigits":false},
           "visibility":{"type":"whenForecast","fieldId":"claude.weekly","verdicts":[]}}
        ]}
        """
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tokens[0].visibility, .always)
    }
}
