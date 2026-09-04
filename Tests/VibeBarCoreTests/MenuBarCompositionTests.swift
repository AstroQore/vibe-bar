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
        windowSeconds: Int? = nil,
        forecast: MenuBarQuotaSnapshot.Forecast? = nil
    ) -> MenuBarQuotaSnapshot {
        MenuBarQuotaSnapshot(
            fieldId: fieldId,
            tool: tool,
            label: label,
            usedPercent: used,
            displayPercent: display ?? used,
            resetAt: resetAt,
            rawWindowSeconds: windowSeconds,
            forecast: forecast
        )
    }

    /// A bucket halfway through its window, so the linear expectation is 50%
    /// and pace is `used - 50`.
    private func halfwayQuota(
        _ fieldId: String = "claude.five_hour",
        label: String = "5 Hours",
        used: Double
    ) -> MenuBarQuotaSnapshot {
        quota(
            fieldId,
            label: label,
            used: used,
            resetAt: reference.addingTimeInterval(1800),
            windowSeconds: 3600
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

    /// A one-group strip whose column stacks. What a `.lineBreak` in the
    /// middle of a flat list used to describe, said in the model that
    /// replaced it.
    private func stacked(
        top: [MenuBarToken],
        bottom: [MenuBarToken],
        template: MenuBarComposition.Template = .roomy
    ) -> MenuBarComposition {
        MenuBarComposition(
            isEnabled: true,
            template: template,
            segments: [MenuBarSegment(top: top, bottom: bottom)]
        )
    }

    private func planStacked(
        top: [MenuBarToken],
        bottom: [MenuBarToken],
        quotas: [MenuBarQuotaSnapshot],
        displayMode: DisplayMode = .used,
        colorBasis: MenuBarColorBasis = .actual
    ) -> MenuBarRenderPlan {
        stacked(top: top, bottom: bottom).plan(
            quotas: quotas,
            displayMode: displayMode,
            colorBasis: colorBasis,
            now: reference
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
        // Halfway through the window, so the linear expectation is 50%.
        XCTAssertEqual(metric(.pace, halfwayQuota(used: 62)), "+12%")
        XCTAssertEqual(metric(.pace, halfwayQuota(used: 42)), "-8%")
        XCTAssertEqual(metric(.pace, halfwayQuota(used: 50)), "±0%")
        // No window or no reset date: nothing to say.
        XCTAssertNil(metric(.pace, quota()))
        XCTAssertNil(metric(.pace, quota(resetAt: reference.addingTimeInterval(60))))
    }

    func testPaceIsComputedAtDrawTimeSoItAdvancesWithTheClock() {
        // The same snapshot, read a quarter of an hour later: the expectation
        // it is measured against has moved, so the figure has to move with it.
        // Freezing pace into the snapshot is what made it stale between
        // refreshes — and made the preview and the bar disagree.
        let snapshot = quota(
            used: 50,
            resetAt: reference.addingTimeInterval(1800),
            windowSeconds: 3600
        )
        XCTAssertEqual(
            MenuBarComposition.value(
                of: .pace,
                in: snapshot,
                displayMode: .used,
                resetFormat: .default,
                now: reference
            ),
            "±0%"
        )
        XCTAssertEqual(
            MenuBarComposition.value(
                of: .pace,
                in: snapshot,
                displayMode: .used,
                resetFormat: .default,
                now: reference.addingTimeInterval(900)
            ),
            "-25%"
        )
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
        let wallTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        // Default is `.automatic`, and this reset is still today, so the block
        // prints the bare time — the same width it printed before weekdays
        // existed.
        XCTAssertEqual(metric(.resetAt, quota(resetAt: resetAt)), wallTime)
        XCTAssertEqual(metric(.resetAt, quota(resetAt: resetAt), format: .time), wallTime)
    }

    /// The per-block format is read from the block's own style, so two blocks
    /// on the same quota can print the same reset differently.
    func testTheResetAtBlockPrintsTheFormatItsOwnStyleAsksFor() {
        let resetAt = reference.addingTimeInterval(3600 * 30)
        let snapshot = quota(resetAt: resetAt)
        let weekday = AppLocale.string(resetAt, template: "EEE")

        XCTAssertEqual(metric(.resetAt, snapshot, format: .weekdayTime)?.contains(weekday), true)
        XCTAssertEqual(metric(.resetAt, snapshot, format: .dateTime)?.contains(weekday), false)
        // Date only prints no clock time at all.
        XCTAssertEqual(
            metric(.resetAt, snapshot, format: .date),
            AppLocale.string(resetAt, template: "MMMd")
        )
    }

    func testAStyleFromANewerBuildKeepsItsBlockAndFallsBackToTheDefaultFormat() {
        // A format this build has never heard of is a cosmetic unknown, not a
        // reason to lose the block: the strip keeps the quota and prints it in
        // the default shape. `Kind.metric` is the opposite call on purpose —
        // an unknown *metric* would silently show the wrong number.
        let json = """
        {"id":"\(UUID().uuidString)",
         "kind":{"type":"quota","fieldId":"claude.weekly","metric":"resetAt"},
         "style":{"color":{"type":"primary"},"size":"regular","weight":"medium",
                  "monospacedDigits":false,"resetFormat":"stardate"}}
        """
        let token = try? JSONDecoder().decode(MenuBarToken.self, from: Data(json.utf8))
        XCTAssertEqual(token?.kind, .quota(fieldId: "claude.weekly", metric: .resetAt))
        XCTAssertEqual(token?.style.resetFormat, .default)
    }

    func testAResetFormatSurvivesASettingsRoundTrip() {
        let token = MenuBarToken(
            kind: .quota(fieldId: "claude.weekly", metric: .resetAt),
            style: MenuBarToken.Style(resetFormat: .weekdayDateTime)
        )
        let data = try? JSONEncoder().encode(token)
        let restored = data.flatMap { try? JSONDecoder().decode(MenuBarToken.self, from: $0) }
        XCTAssertEqual(restored?.style.resetFormat, .weekdayDateTime)
    }

    func testLabelMetricPrintsTheQuotasOwnName() {
        XCTAssertEqual(metric(.label, quota(label: "Weekly")), "Weekly")
        XCTAssertNil(metric(.label, quota(label: "   ")))
    }

    private func metric(
        _ metric: MenuBarQuotaMetric,
        _ snapshot: MenuBarQuotaSnapshot,
        format: ResetTimeFormat = .default
    ) -> String? {
        MenuBarComposition.value(
            of: metric,
            in: snapshot,
            displayMode: .remaining,
            resetFormat: format,
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

    func testAStackedGroupDrawsOneRowPerContainer() {
        let rendered = planStacked(
            top: [MenuBarToken(kind: .text("top"))],
            bottom: [MenuBarToken(kind: .text("bottom"))],
            quotas: []
        )
        XCTAssertEqual(rendered.rows.count, MenuBarComposition.maximumRows)
        XCTAssertEqual(texts(rendered), [["top"], ["bottom"]])
    }

    func testAGroupWithNoSecondRowDrawsOne() {
        let rendered = plan([MenuBarToken(kind: .text("only"))], quotas: [])
        XCTAssertEqual(texts(rendered), [["only"]])
        XCTAssertNil(rendered.columns.first?.bottom)
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
        XCTAssertEqual(byField["b.x"]?.needsForecast, true)
        // Pace is arithmetic over what the snapshot already carries, so it
        // asks for nothing and stays free.
        XCTAssertEqual(byField["c.x"]?.needsForecast, false)
    }

    func testRequirementsMergeAcrossBlocksNamingTheSameQuota() {
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .displayPercent)),
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .pace)),
            MenuBarToken(kind: .quota(fieldId: "a.x", metric: .forecastPercent))
        ])
        XCTAssertEqual(composed.quotaRequirements.count, 1)
        XCTAssertEqual(composed.quotaRequirements[0].needsForecast, true)
    }

    // MARK: - Spoken description

    func testTheStripIsDescribedInWordsNotInTheDrawnShorthand() {
        let rendered = planStacked(
            top: [
                MenuBarToken(kind: .logo(.claude)),
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent)),
                MenuBarToken(kind: .separator("/"), style: .divider),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .resetsIn))
            ],
            bottom: [
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
        // The name is a *reference*, not the words: resolved when the strip is
        // drawn, so it follows the app's language.
        XCTAssertEqual(seeded.tokens.map(\.kind), [
            .quota(fieldId: "claude.five_hour", metric: .label),
            .quota(fieldId: "claude.five_hour", metric: .displayPercent),
            .separator("·"),
            .quota(fieldId: "claude.weekly", metric: .label),
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
        // Roomy seeds from Single line, which draws words only and has never
        // honoured the per-field style — so the saved logo style is dropped
        // here exactly as the renderer drops it.
        XCTAssertEqual(seeded.tokens.map(\.kind), [
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

    func testTwoColumnTemplateSeedsASecondRow() {
        let seeded = MenuBarComposition.seeded(template: .twoColumn, from: fieldItem())
        XCTAssertTrue(seeded.segments.contains(where: \.isStacked))
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
        item.composition?.append(MenuBarToken(kind: .text("!")))
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
        item.composition?.setSingleSegment([MenuBarToken(kind: .text("mine"))])
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

    func testAppendLandsAtTheEndOfTheStripInReadingOrder() {
        var composed = editable()
        composed.addRow(toSegment: composed.segments[0].id)
        composed.append(MenuBarToken(kind: .text("under")))
        // The end of a stacked column is its lower cell, not the end of its
        // upper one.
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [.text("under")])
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

    func testASecondRowIsOfferedOnceAndOpensEmpty() {
        var composed = composition([MenuBarToken(kind: .text("a"))])
        let group = composed.segments[0].id
        XCTAssertTrue(composed.canAddRow(toSegment: group))
        XCTAssertTrue(composed.addRow(toSegment: group))
        // Opened, not filled: the row is a place blocks are dragged into.
        XCTAssertEqual(composed.segments[0].bottom, [])
        // Two rows is all the status item can draw, and all the type can hold.
        XCTAssertFalse(composed.canAddRow(toSegment: group))
        XCTAssertFalse(composed.addRow(toSegment: group))
    }

    func testClosingARowKeepsItsBlocksOnTheRowAbove() {
        var composed = stacked(
            top: [MenuBarToken(kind: .text("a"))],
            bottom: [MenuBarToken(kind: .text("b"))]
        )
        let group = composed.segments[0].id
        XCTAssertTrue(composed.removeRow(fromSegment: group))
        XCTAssertFalse(composed.segments[0].isStacked)
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [.text("a"), .text("b")])
        XCTAssertFalse(composed.removeRow(fromSegment: group))
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

    // MARK: - Own-quota forecast colour (review thread 1)

    func testForecastColourRequestsItsOwnBlocksForecastUnderEitherBasis() {
        // `.forecast` names no field — it means "this block's own quota" — so
        // the requirement walk has to attribute it, or the renderer supplies
        // no verdict and the explicitly chosen forecast colour silently falls
        // back to the percentage thresholds.
        let composed = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent),
                style: .init(color: .forecast)
            )
        ])
        let requirements = composed.quotaRequirements
        XCTAssertEqual(requirements.count, 1)
        XCTAssertEqual(requirements[0].fieldId, "claude.five_hour")
        XCTAssertTrue(
            requirements[0].needsForecast,
            "a block asking for the forecast colour must get a forecast computed for it"
        )

        // And the resolved role is the forecast one whichever basis the app is
        // set to — the block asked explicitly.
        for basis in MenuBarColorBasis.allCases {
            let rendered = composed.plan(
                quotas: [quota()],
                displayMode: .used,
                colorBasis: basis,
                now: reference
            )
            XCTAssertEqual(
                rendered.rows[0].tokens[0].color,
                .quota(fieldId: "claude.five_hour", basis: .forecast),
                "basis \(basis)"
            )
        }
    }

    func testAutomaticColourDoesNotForceAForecastOfItsOwn() {
        // `.automatic` follows the app-wide basis, which the renderer already
        // resolves for every quota it draws; it must not add a forecast the
        // plain field strip would never have computed.
        let composed = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent),
                style: .percent
            )
        ])
        XCTAssertEqual(composed.quotaRequirements[0].needsForecast, false)
    }

    func testForecastColourOnATextBlockAsksForNothing() {
        // No own quota to follow, so it resolves to `.primary` and needs no
        // forecast.
        let composed = composition([
            MenuBarToken(kind: .text("hi"), style: .init(color: .forecast))
        ])
        XCTAssertTrue(composed.quotaRequirements.isEmpty)
    }

    // MARK: - Countdown clock (review thread 2)

    func testOnlyTimeBasedMetricsAskForAClock() {
        for metric in MenuBarQuotaMetric.allCases {
            let expected = [.resetsIn, .resetAt, .runsOutIn, .pace].contains(metric)
            XCTAssertEqual(metric.isTimeBased, expected, "\(metric)")
            let composed = composition([
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: metric))
            ])
            XCTAssertEqual(composed.hasTimeBasedBlock, expected, "\(metric)")
        }
        // A strip of words and logos must not start a timer at all.
        XCTAssertFalse(composition([
            MenuBarToken(kind: .text("Claude")),
            MenuBarToken(kind: .logo(.claude))
        ]).hasTimeBasedBlock)
    }

    func testCountdownTicksAreMinuteAlignedAndStrictlyForward() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)
        // Mid-minute: the next tick is the following boundary.
        let mid = anchor.addingTimeInterval(23.4)
        let next = MenuBarCountdownClock.nextTick(after: mid, anchor: anchor)
        XCTAssertEqual(next.timeIntervalSinceReferenceDate, 1_000_060, accuracy: 1e-9)

        // Exactly on a boundary: strictly after, so a tick that fires a hair
        // early cannot re-schedule itself for the instant it just handled.
        let onGrid = anchor.addingTimeInterval(120)
        XCTAssertEqual(
            MenuBarCountdownClock.nextTick(after: onGrid, anchor: anchor)
                .timeIntervalSinceReferenceDate,
            1_000_180,
            accuracy: 1e-9
        )

        // Every tick lands on the shared grid, so the menu bar and the popover
        // never disagree about what "now" is.
        var cursor = anchor.addingTimeInterval(7)
        for _ in 0..<5 {
            cursor = MenuBarCountdownClock.nextTick(after: cursor, anchor: anchor)
            let offset = cursor.timeIntervalSince(anchor)
            XCTAssertEqual(offset.truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-9)
        }
    }

    // MARK: - Seeding follows the layout (review thread 3)

    private func layoutItem(
        _ layout: MenuBarLayout,
        fields: [String]? = nil,
        styles: [String: MenuBarFieldStyle] = [:]
    ) -> MenuBarItemSettings {
        MenuBarItemSettings(
            kind: .compact,
            isVisible: true,
            showTitle: false,
            layout: layout,
            selectedFieldIds: fields ?? [
                "codex.five_hour", "codex.weekly", "claude.five_hour", "claude.weekly"
            ],
            fieldStyles: styles
        )
    }

    func testIconOnlySeedsTheGlyphItActuallyShows() {
        // The default item is `.iconOnly` while still carrying four selected
        // fields. Expanding those would greet the user with a four-quota strip
        // they have never seen.
        let seeded = MenuBarComposition.seeded(
            template: .matching(.iconOnly),
            from: layoutItem(.iconOnly)
        )
        XCTAssertEqual(seeded.tokens.map(\.kind), [.appIcon])
    }

    func testTwoRowsSeedsOneGroupPerColumnTheWayTheLayoutPacksThem() {
        // The two-row layout packs entries into two-cell columns. Before
        // groups existed the seed had to flatten that into two long rows,
        // which drew the same words in the same order but lost the pairing —
        // nothing said `codex.weekly` sat under `codex.five_hour`. A group is
        // a column now, so the seed says it.
        let seeded = MenuBarComposition.seeded(
            template: .matching(.twoRows),
            from: layoutItem(.twoRows)
        )
        XCTAssertEqual(seeded.segments.count, 2)
        let paired = seeded.segments.map { segment -> [String?] in
            [
                segment.top.map(\.kind).compactMap(quotaFieldId).first,
                segment.bottom?.map(\.kind).compactMap(quotaFieldId).first
            ]
        }
        XCTAssertEqual(paired, [
            ["codex.five_hour", "codex.weekly"],
            ["claude.five_hour", "claude.weekly"]
        ])
        // ...and the plan hands the rasterizer exactly those columns.
        let rendered = seeded.plan(
            quotas: ["codex.five_hour", "codex.weekly", "claude.five_hour", "claude.weekly"]
                .map { quota($0) },
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        XCTAssertEqual(rendered.columns.count, 2)
        XCTAssertTrue(rendered.isTwoRow)
    }

    func testEverySeedUsesTheSameSeparatorRuleTheRendererDoes() {
        // Five review rounds found the seed and the renderer disagreeing about
        // a different dimension each time, because each kept its own copy of
        // the rule. Both read `MenuBarFieldStripRules` now, so this asserts
        // the agreement over every layout instead of listing what each one
        // happens to draw — a hand-listed expectation is what passed through
        // all five of those rounds.
        for layout in MenuBarLayout.allCases {
            let seeded = MenuBarComposition.seeded(
                template: .matching(layout),
                from: layoutItem(layout, fields: ["claude.five_hour", "claude.weekly"])
            )
            let separators = seeded.tokens.map(\.kind).filter {
                if case .separator = $0 { return true }
                return $0 == .space(width: 1)
            }
            let expected = MenuBarFieldStripRules.separator(for: layout)
            XCTAssertEqual(
                Set(separators),
                expected.map { Set([$0]) } ?? [],
                "\(layout) seeds a separator its renderer does not draw"
            )
        }
    }

    func testTwoRowsSplitsAStripThatHasNoFieldEntries() {
        // The composer takes arbitrary blocks, so a strip can be words and
        // logos with no value to close an entry. Choosing Two rows still has
        // to produce two rows — a control that quietly produces one is the
        // defect the seam exists to fix.
        var composed = composition([
            MenuBarToken(kind: .logo(.claude)),
            MenuBarToken(kind: .text("A")),
            MenuBarToken(kind: .text("B")),
            MenuBarToken(kind: .appIcon)
        ])
        composed.isEnabled = true
        composed.setTemplate(.twoColumn)
        XCTAssertEqual(composed.segments.filter(\.isStacked).count, 1, "Two rows must open a row")
        XCTAssertEqual(rowCount(composed), 2)
    }

    func testASingleBlockStripStaysOnOneRow() {
        // ...and the fallback must not invent a break where there is nothing
        // to put on the second row.
        var composed = composition([MenuBarToken(kind: .text("only"))])
        composed.isEnabled = true
        composed.setTemplate(.twoColumn)
        XCTAssertFalse(composed.segments.contains(where: \.isStacked))
    }

    func testATwoRowTitleGetsAColumnOfItsOwn() {
        // This used to be the seed's one named divergence: the field renderer
        // gives the title a column with no second cell, which the rasterizer
        // centres across both rows, and a flat list of blocks had no way to
        // say that — so the title led the first row instead. A group with one
        // row *is* that column, so the divergence is gone rather than
        // documented.
        var item = layoutItem(.twoRows, fields: ["claude.five_hour", "claude.weekly"])
        item.showTitle = true
        let seeded = MenuBarComposition.seeded(template: .matching(.twoRows), from: item)
        XCTAssertEqual(seeded.segments.first?.tokens.map(\.kind), [.text(item.kind.title)])
        XCTAssertEqual(seeded.segments.first?.isStacked, false)
        let rendered = seeded.plan(
            quotas: ["claude.five_hour", "claude.weekly"].map { quota($0) },
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        XCTAssertNil(rendered.columns.first?.bottom, "the title cell spans the height")
        XCTAssertNotNil(rendered.columns.dropFirst().first?.bottom, "the entries still stack")
    }

    func testASeedNeverAppliesAStyleItsLayoutIgnores() {
        // Single line draws words only. A saved logo style must not put a logo
        // on a strip that has never shown one.
        for layout in MenuBarLayout.allCases {
            let seeded = MenuBarComposition.seeded(
                template: .matching(layout),
                from: layoutItem(
                    layout,
                    fields: ["claude.five_hour"],
                    styles: ["claude.five_hour": .logoLabelAndPercent]
                )
            )
            let hasLogo = seeded.tokens.contains {
                if case .logo = $0.kind { return true }
                return false
            }
            let styleKeepsLogo = MenuBarFieldStripRules.effectiveStyle(
                .logoLabelAndPercent, layout: layout
            ) != .labelAndPercent
            // Icon Only seeds the app glyph and no field blocks at all.
            if layout == .iconOnly { continue }
            XCTAssertEqual(
                hasLogo, styleKeepsLogo,
                "\(layout) disagrees with its renderer about the logo style"
            )
        }
    }

    func testTemplateMatchesTheLayoutItSeedsFrom() {
        XCTAssertEqual(MenuBarComposition.Template.matching(.twoRows), .twoColumn)
        XCTAssertEqual(MenuBarComposition.Template.matching(.compact), .compact)
        XCTAssertEqual(MenuBarComposition.Template.matching(.singleLine), .roomy)
        XCTAssertEqual(MenuBarComposition.Template.matching(.iconOnly), .roomy)
    }

    func testTheAppGlyphRendersAsAGlyphAndIsSpoken() {
        let rendered = plan([MenuBarToken(kind: .appIcon)], quotas: [])
        XCTAssertEqual(rendered.rows[0].tokens[0].glyph, .app)
        XCTAssertNil(rendered.rows[0].tokens[0].text)
        XCTAssertEqual(rendered.spokenDescription, "Vibe Bar")
    }

    func testTheAppGlyphRoundTrips() throws {
        let composed = composition([MenuBarToken(kind: .appIcon)])
        let decoded = try JSONDecoder().decode(
            MenuBarComposition.self,
            from: try JSONEncoder().encode(composed)
        )
        XCTAssertEqual(decoded.tokens.map(\.kind), [.appIcon])
    }

    /// The field of a percentage block, ignoring the name block beside it.
    private func quotaFieldId(_ kind: MenuBarToken.Kind) -> String? {
        if case let .quota(fieldId, metric) = kind, metric != .label { return fieldId }
        return nil
    }

    // MARK: - Two-row fit (review thread 4)

    func testAStripThatAlreadyFitsIsNotShrunk() {
        XCTAssertEqual(
            MenuBarStripFit.scale(contentHeight: 16, availableHeight: 18),
            1,
            accuracy: 1e-9
        )
        // Degenerate inputs never produce a zero-size strip.
        XCTAssertEqual(MenuBarStripFit.scale(contentHeight: 0, availableHeight: 18), 1)
        XCTAssertEqual(MenuBarStripFit.scale(contentHeight: 20, availableHeight: 0), 1)
    }

    func testEverySupportedTwoRowCombinationFitsTheCanvas() {
        // The property, not a constant. The previous test asserted the content
        // fit *or* the floor had bitten, which is a tautology — and it passed
        // while the rows stayed cropped. At the top composition scale with two
        // Large blocks the content is ~39.5pt for 18pt of canvas, needing
        // ~0.46; the old 0.55 floor left ~21.7pt for the canvas cap to crop.
        let available = MenuBarStripGeometry.nominalTwoRowAvailableHeight
        let base = MenuBarStripGeometry.nominalTwoRowFontSize
        let scales = [
            MenuBarComposition.fontScaleRange.lowerBound,
            1.0,
            1.3,
            MenuBarComposition.fontScaleRange.upperBound
        ]
        for compositionScale in scales {
            for first in MenuBarToken.SizeStep.allCases {
                for second in MenuBarToken.SizeStep.allCases {
                    let rows = [first, second].map {
                        base * compositionScale * $0.multiplier
                    }
                    let content = MenuBarStripGeometry.twoRowContentHeight(
                        rowFontSizes: rows,
                        lineSpacing: MenuBarStripGeometry.nominalTwoRowLineSpacing,
                        lineHeightRatio: MenuBarStripGeometry.nominalLineHeightRatio
                    )
                    let fit = MenuBarStripFit.scale(
                        contentHeight: content,
                        availableHeight: available
                    )
                    let label = "scale \(compositionScale), \(first)/\(second)"

                    // 1. It fits, so nothing is left for the canvas cap to crop.
                    XCTAssertLessThanOrEqual(
                        content * fit, available + 1e-9,
                        "does not fit at \(label)"
                    )
                    // 2. Fitting never turns legible type into a smudge —
                    //    what the floor was reaching for, and got wrong by
                    //    applying it inside the arithmetic instead of asking
                    //    about the result. A face that was already tiny
                    //    because someone hand-edited `fontScale` down is their
                    //    choice, not something fitting did to them.
                    for row in rows where row >= MenuBarStripFit.legibleFontSize {
                        XCTAssertGreaterThanOrEqual(
                            row * fit, MenuBarStripFit.legibleFontSize,
                            "fitting made it illegible at \(label)"
                        )
                    }
                }
            }
        }
    }

    func testTheWorstSupportedCombinationReallyDoesOverflow() {
        // Guards the test above from passing because nothing overflows.
        let base = MenuBarStripGeometry.nominalTwoRowFontSize
        let worst = base * MenuBarComposition.fontScaleRange.upperBound
            * MenuBarToken.SizeStep.large.multiplier
        let content = MenuBarStripGeometry.twoRowContentHeight(
            rowFontSizes: [worst, worst],
            lineSpacing: MenuBarStripGeometry.nominalTwoRowLineSpacing,
            lineHeightRatio: MenuBarStripGeometry.nominalLineHeightRatio
        )
        XCTAssertGreaterThan(content, MenuBarStripGeometry.nominalTwoRowAvailableHeight)
    }

    func testEveryConfigurationTheEditorCanProduceIsLegible() {
        // What the UI can actually reach: the template defaults, which no
        // control overrides, times the three size steps.
        for template in MenuBarComposition.Template.allCases {
            for step in MenuBarToken.SizeStep.allCases {
                let row = MenuBarStripGeometry.nominalTwoRowFontSize
                    * template.fontScale * step.multiplier
                let content = MenuBarStripGeometry.twoRowContentHeight(
                    rowFontSizes: [row, row],
                    lineSpacing: MenuBarStripGeometry.nominalTwoRowLineSpacing,
                    lineHeightRatio: MenuBarStripGeometry.nominalLineHeightRatio
                )
                let fit = MenuBarStripFit.scale(
                    contentHeight: content,
                    availableHeight: MenuBarStripGeometry.nominalTwoRowAvailableHeight
                )
                XCTAssertGreaterThanOrEqual(
                    row * fit, MenuBarStripFit.legibleFontSize,
                    "\(template)/\(step)"
                )
            }
        }
    }

    func testAStripThatFitsIsNotScaledAtAll() {
        XCTAssertEqual(MenuBarStripFit.scale(contentHeight: 16, availableHeight: 18), 1)
        XCTAssertEqual(MenuBarStripFit.scale(contentHeight: 18, availableHeight: 18), 1)
        XCTAssertEqual(MenuBarStripFit.scale(contentHeight: 0, availableHeight: 18), 1)
    }

    // MARK: - Drag commits once (review thread 1)

    func testADragCrossingSeveralChipsLandsWhereOneMoveWould() {
        // The editor keeps the provisional order in local state and writes it
        // once on drop. That is only safe if replaying every crossing on a
        // scratch copy ends where a single move would have — otherwise the one
        // committed write would not be the arrangement the user watched.
        let base = composition([
            MenuBarToken(kind: .text("a")),
            MenuBarToken(kind: .text("b")),
            MenuBarToken(kind: .text("c")),
            MenuBarToken(kind: .text("d"))
        ])
        let ids = base.tokens.map(\.id)

        var provisional = base
        // One drag of "a" that crosses b, then c, then d.
        provisional.move(ids[0], before: ids[1])
        provisional.move(ids[0], before: ids[2])
        provisional.move(ids[0], before: ids[3])

        XCTAssertEqual(
            provisional.tokens.map(\.kind),
            [.text("b"), .text("c"), .text("a"), .text("d")]
        )
        // The committed value is the provisional one — one assignment, not one
        // per crossing.
        var committed = base
        committed.segments = provisional.segments
        XCTAssertEqual(committed.tokens.map(\.id), provisional.tokens.map(\.id))
        // ...and the source of truth was never touched while the drag ran.
        XCTAssertEqual(base.tokens.map(\.kind), [.text("a"), .text("b"), .text("c"), .text("d")])
    }

    func testAnAbandonedDragLeavesTheCommittedOrderAlone() {
        let base = composition([
            MenuBarToken(kind: .text("a")),
            MenuBarToken(kind: .text("b")),
            MenuBarToken(kind: .text("c"))
        ])
        var provisional = base
        // Drag "c" to the front, then walk away without dropping.
        provisional.move(base.tokens[2].id, before: base.tokens[0].id)
        XCTAssertEqual(
            provisional.tokens.map(\.kind),
            [.text("c"), .text("a"), .text("b")]
        )
        XCTAssertNotEqual(provisional.tokens.map(\.kind), base.tokens.map(\.kind))
        // Dropping the scratch copy is the whole rollback.
        XCTAssertEqual(base.tokens.map(\.kind), [.text("a"), .text("b"), .text("c")])
    }

    // MARK: - Requirement-aware preview cache (review thread 2)

    func testSwappingAMetricChangesTheRequirementsThoughTheFieldSetDoesNot() {
        let percent = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .displayPercent))
        ])
        let runsOut = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .runsOutIn))
        ])
        // The field set is identical, which is why keying a cache on it missed
        // the edit and left the preview showing nothing for the block.
        XCTAssertEqual(percent.referencedFieldIds, runsOut.referencedFieldIds)
        XCTAssertNotEqual(percent.quotaRequirements, runsOut.quotaRequirements)
        XCTAssertEqual(runsOut.quotaRequirements[0].needsForecast, true)
        XCTAssertEqual(percent.quotaRequirements[0].needsForecast, false)
    }

    func testAForecastBlockRendersOnlyOnceItsSnapshotCarriesAForecast() {
        // What a stale cache produces: a snapshot resolved for a percentage
        // block carries no forecast, so a forecast block draws nothing until
        // the cache notices the metric changed.
        let stale = quota("claude.weekly", label: "Weekly", used: 50)
        let fresh = quota(
            "claude.weekly",
            label: "Weekly",
            used: 50,
            forecast: .init(verdict: .watch, projectedRemainingPercent: 18)
        )
        let tokens = [MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .forecastPercent))]
        XCTAssertTrue(plan(tokens, quotas: [stale]).isEmpty)
        XCTAssertEqual(texts(plan(tokens, quotas: [fresh])), [["18%"]])
    }

    // MARK: - Two-row run gap (review thread 3)

    func testComposedRunsAddNoGapWhileTheBuiltInLayoutStillDoes() {
        let runs = [10.0, 8.0, 12.0]
        // A composed row carries the user's configured spacing inside its own
        // text runs, so the cell adds nothing between them: zero spacing has
        // to mean zero.
        XCTAssertEqual(
            MenuBarStripGeometry.cellWidth(runWidths: runs, gap: 0),
            30,
            accuracy: 1e-9
        )
        // The built-in two-row layout draws a leading logo and still gets its
        // fixed gap after it.
        XCTAssertEqual(
            MenuBarStripGeometry.cellWidth(runWidths: [8, 20], gap: 2),
            30,
            accuracy: 1e-9
        )
        // Non-zero spacing is applied once per boundary, never doubled.
        XCTAssertEqual(
            MenuBarStripGeometry.cellWidth(runWidths: runs, gap: 3),
            36,
            accuracy: 1e-9
        )
        // Degenerate shapes stay sane.
        XCTAssertEqual(MenuBarStripGeometry.cellWidth(runWidths: [], gap: 5), 0)
        XCTAssertEqual(MenuBarStripGeometry.cellWidth(runWidths: [7], gap: 5), 7)
    }

    // MARK: - Seeded labels are not spoken twice (review thread 3)

    func testASeededStripDrawsItsLabelsButSaysEachFieldOnce() {
        // End to end: seed the way switching to Custom seeds, then plan it
        // against live buckets.
        var seeded = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        seeded.isEnabled = true
        let rendered = seeded.plan(
            quotas: [
                quota("claude.five_hour", label: "5 Hours", used: 73, display: 73),
                quota("claude.weekly", label: "Weekly", used: 100, display: 100)
            ],
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        // The strip still *draws* the label blocks — that is what the seeded
        // bar looks like today.
        XCTAssertEqual(texts(rendered), [["5 Hours", "73%", "·", "Weekly", "100%"]])
        // ...and says each field name exactly once.
        XCTAssertEqual(rendered.spokenDescription, "5 Hours 73% used, Weekly 100% used")
    }

    func testALabelBlockDoingItsOwnWorkIsStillSpoken() {
        let quotas = [quota("claude.five_hour", label: "5 Hours", used: 40, display: 40)]
        // A word that is not the quota's name is the user's own and is read.
        let custom = plan(
            [
                MenuBarToken(kind: .text("Claude")),
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))
            ],
            quotas: quotas
        )
        XCTAssertEqual(custom.spokenDescription, "Claude, 5 Hours 40% used")

        // A row boundary between them means the label is heading its own row.
        let split = planStacked(
            top: [MenuBarToken(kind: .text("5 Hours"))],
            bottom: [
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))
            ],
            quotas: quotas
        )
        XCTAssertEqual(split.spokenDescription, "5 Hours · 5 Hours 40% used")

        // A label with no quota after it at all is still read.
        let alone = plan([MenuBarToken(kind: .text("5 Hours"))], quotas: quotas)
        XCTAssertEqual(alone.spokenDescription, "5 Hours")
    }

    func testAnEchoedLabelIsSuppressedThroughSpacingOnly() {
        let quotas = [quota("claude.weekly", label: "Weekly", used: 20, display: 20)]
        // Spacing between the label and its number does not make it a
        // different block.
        let spaced = plan(
            [
                MenuBarToken(kind: .text("Weekly")),
                MenuBarToken(kind: .space(width: 1)),
                MenuBarToken(kind: .separator(":")),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .displayPercent))
            ],
            quotas: quotas
        )
        XCTAssertEqual(spaced.spokenDescription, "Weekly 20% used")
        // Case and surrounding whitespace do not make it a different word.
        let sloppy = plan(
            [
                MenuBarToken(kind: .text(" weekly ")),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .displayPercent))
            ],
            quotas: quotas
        )
        XCTAssertEqual(sloppy.spokenDescription, "Weekly 20% used")
        // The rendered token also stops carrying the clause, so every consumer
        // agrees rather than only the joined description.
        XCTAssertNil(sloppy.rows[0].tokens[0].spoken)
        XCTAssertEqual(sloppy.rows[0].tokens[0].text, " weekly ")
    }

    func testAnEchoedLabelBeforeAnUnavailableQuotaIsStillSpoken() {
        // The number is gone, so the label is the only thing left describing
        // the block — suppressing it would leave the strip silent.
        let rendered = plan(
            [
                MenuBarToken(kind: .text("5 Hours")),
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .displayPercent))
            ],
            quotas: []
        )
        XCTAssertEqual(rendered.spokenDescription, "5 Hours")
    }

    // MARK: - A label is only silenced when its quota speaks (review thread 1)

    private func labelThenQuota(_ metric: MenuBarQuotaMetric) -> [MenuBarToken] {
        [
            MenuBarToken(kind: .text("Weekly")),
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: metric))
        ]
    }

    func testALabelIsStillSpokenWhenItsQuotaBlockHasNothingToSay() {
        // The forecast exists but does not predict exhaustion, so `runsOutIn`
        // renders nothing. The label beside it is then the only content on
        // screen — silencing it would describe less than the strip shows.
        let noRunOut = quota(
            "claude.weekly",
            label: "Weekly",
            used: 30,
            forecast: .init(verdict: .enough, projectedRemainingPercent: 60)
        )
        XCTAssertEqual(
            plan(labelThenQuota(.runsOutIn), quotas: [noRunOut]).spokenDescription,
            "Weekly"
        )

        // Same one level down: a quota that is answering, but has no forecast
        // yet for a forecast metric.
        let noForecast = quota("claude.weekly", label: "Weekly", used: 30)
        XCTAssertEqual(
            plan(labelThenQuota(.forecastPercent), quotas: [noForecast]).spokenDescription,
            "Weekly"
        )

        // And a countdown with no reset date behind it.
        XCTAssertEqual(
            plan(labelThenQuota(.resetsIn), quotas: [noForecast]).spokenDescription,
            "Weekly"
        )
    }

    func testALabelIsStillSpokenWhenItsQuotaBlockIsHiddenByARule() {
        let calm = quota("claude.weekly", label: "Weekly", used: 10, display: 10)
        let rendered = plan(
            [
                MenuBarToken(kind: .text("Weekly")),
                MenuBarToken(
                    kind: .quota(fieldId: "claude.weekly", metric: .displayPercent),
                    visibility: .whenUsedAtLeast(fieldId: "claude.weekly", percent: 90)
                )
            ],
            quotas: [calm]
        )
        XCTAssertEqual(texts(rendered), [["Weekly"]])
        XCTAssertEqual(rendered.spokenDescription, "Weekly")
    }

    func testALabelIsStillSilencedWhenItsQuotaDoesSpeak() {
        // The case the coalescing exists for, unchanged.
        let live = quota(
            "claude.weekly",
            label: "Weekly",
            used: 30,
            forecast: .init(
                verdict: .watch,
                projectedRemainingPercent: 12,
                runOutAt: reference.addingTimeInterval(3600 * 5)
            )
        )
        let rendered = plan(labelThenQuota(.runsOutIn), quotas: [live])
        XCTAssertEqual(texts(rendered), [["Weekly", "5h"]])
        XCTAssertEqual(rendered.spokenDescription, "Weekly runs out in 5h")
    }

    // MARK: - A forecast-driven strip is on a clock (review thread 1)

    func testAForecastMetricPutsTheStripOnAClock() {
        for metric in [MenuBarQuotaMetric.forecastPercent, .runsOutIn] {
            let composed = composition([
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: metric))
            ])
            XCTAssertTrue(
                composed.needsForecastClock(colorBasis: .actual),
                "\(metric) reads the forecast"
            )
        }
    }

    func testAForecastVisibilityRulePutsTheStripOnAClock() {
        // The rule decides whether the block is on screen at all, so a stale
        // verdict leaves a block wrongly shown or wrongly hidden.
        let composed = composition([
            MenuBarToken(
                kind: .text("!"),
                visibility: .whenForecast(fieldId: "claude.weekly", verdicts: [.atRisk])
            )
        ])
        XCTAssertTrue(composed.needsForecastClock(colorBasis: .actual))
    }

    func testAForecastColourPutsTheStripOnAClock() {
        // Explicit forecast colour...
        let explicit = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.weekly", metric: .displayPercent),
                style: .init(color: .forecast)
            )
        ])
        XCTAssertTrue(explicit.needsForecastClock(colorBasis: .actual))

        // ...and one that follows another quota's forecast.
        let follows = composition([
            MenuBarToken(
                kind: .text("Claude"),
                style: .init(color: .followsQuota(fieldId: "claude.weekly", basis: .forecast))
            )
        ])
        XCTAssertTrue(follows.needsForecastClock(colorBasis: .actual))
    }

    func testAnAutomaticColourIsAForecastColourUnderThatBasis() {
        // What every seeded percentage wears. Under the forecast basis its
        // colour is the verdict, so the strip is forecast-driven even though
        // no block names a forecast.
        let composed = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.weekly", metric: .displayPercent),
                style: .percent
            )
        ])
        XCTAssertTrue(composed.needsForecastClock(colorBasis: .forecast))
        XCTAssertFalse(composed.needsForecastClock(colorBasis: .actual))
    }

    func testAPlainStripStartsNoClockAtAll() {
        let composed = composition([
            MenuBarToken(kind: .logo(.claude)),
            MenuBarToken(kind: .text("Claude")),
            MenuBarToken(
                kind: .quota(fieldId: "claude.weekly", metric: .usedPercent),
                style: .init(color: .primary)
            )
        ])
        XCTAssertFalse(composed.needsForecastClock(colorBasis: .actual))
        XCTAssertFalse(composed.hasTimeBasedBlock)
        XCTAssertNil(composed.clockInterval(colorBasis: .actual))
    }

    func testTheClockIsPacedToWhateverTheStripActuallyNeeds() {
        // Forecast only: the forecast's own quantum, because `QuotaService`
        // floors and memoises on it and a faster tick buys only wakeups.
        let forecastOnly = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .forecastPercent))
        ])
        XCTAssertEqual(
            forecastOnly.clockInterval(colorBasis: .actual),
            MenuBarCountdownClock.forecastInterval
        )
        XCTAssertEqual(
            MenuBarCountdownClock.forecastInterval,
            QuotaService.paceForecastClockQuantumSeconds
        )

        // Anything counting down needs the minute, and that also covers the
        // forecast.
        let countdown = composition([
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .resetsIn)),
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .forecastPercent))
        ])
        XCTAssertEqual(
            countdown.clockInterval(colorBasis: .actual),
            MenuBarCountdownClock.interval
        )
    }

    // MARK: - Seeds match what each layout draws (review thread 2)

    // MARK: - A field edit never carries stale neighbours (review thread 2)

    func testTwoFieldEditsInOneDebounceWindowBothSurvive() {
        // The exact sequence: pick a colour, then change the threshold before
        // the colour's queued write has landed. The queued write flushes
        // first, and the threshold edit must be applied to the token *after*
        // that flush — a whole-token replacement built beforehand would carry
        // the old colour and silently undo it.
        var composed = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.weekly", metric: .displayPercent),
                style: .init(color: .primary),
                visibility: .whenUsedAtLeast(fieldId: "claude.weekly", percent: 80)
            )
        ])
        let id = composed.tokens[0].id

        // The queued colour write, expressed as the field it owns.
        func edit(_ change: (inout MenuBarToken) -> Void) {
            guard composed.token(id) != nil else { return XCTFail("token went missing") }
            composed.updateToken(id) { change(&$0) }
        }
        edit { $0.style.color = .hex("#ff0000") }
        // ...then the threshold, from a control that never saw the colour.
        edit { $0.visibility = .whenUsedAtLeast(fieldId: "claude.weekly", percent: 40) }

        XCTAssertEqual(composed.tokens[0].style.color, .fixed("#ff0000"), "the colour survived")
        XCTAssertEqual(
            composed.tokens[0].visibility,
            .whenUsedAtLeast(fieldId: "claude.weekly", percent: 40),
            "the threshold survived"
        )
    }

    func testAWholeTokenReplacementIsWhatUsedToLoseTheEdit() {
        // The shape of the old bug, kept as the reason the contract is
        // field-level: a copy taken before the flush wins over what the flush
        // wrote, so the colour is gone.
        var composed = composition([
            MenuBarToken(
                kind: .quota(fieldId: "claude.weekly", metric: .displayPercent),
                style: .init(color: .primary),
                visibility: .whenUsedAtLeast(fieldId: "claude.weekly", percent: 80)
            )
        ])
        let stale = composed.tokens[0]

        composed.updateToken(stale.id) { $0.style.color = .hex("#ff0000") }
        var replacement = stale
        replacement.visibility = .whenUsedAtLeast(fieldId: "claude.weekly", percent: 40)
        composed.updateToken(stale.id) { $0 = replacement }

        XCTAssertEqual(composed.tokens[0].style.color, .primary, "this is the regression")
    }

    // MARK: - One glyph-sizing decision (review thread 3)

    func testAOneRowGlyphGrowsWithItsTypeAndATwoRowGlyphIsCapped() {
        // The single-row strip builds an uncapped attachment, so a Large block
        // is a large glyph; the preview used to cap it at 12 and show a
        // different icon from the one the bar drew.
        XCTAssertEqual(MenuBarStripGeometry.glyphSide(fontSize: 13, rowCount: 1), 16)
        XCTAssertEqual(MenuBarStripGeometry.singleRowGlyphSide(fontSize: 13), 16)
        // A `.large` block on the 13pt face: still uncapped, still ~19.
        XCTAssertEqual(MenuBarStripGeometry.glyphSide(fontSize: 13 * 1.2, rowCount: 1), 19)

        // The two-row band is fixed, so the glyph is capped there.
        XCTAssertEqual(MenuBarStripGeometry.glyphSide(fontSize: 9, rowCount: 2), 10)
        XCTAssertEqual(
            MenuBarStripGeometry.glyphSide(fontSize: 40, rowCount: 2),
            MenuBarStripGeometry.maximumTwoRowGlyphSide
        )
    }

    // MARK: - Localization register

    func testEveryComposerStringIsInBothCatalogs() throws {
        let (en, zh) = try Self.catalogs()
        let keys = en.keys.filter { $0.hasPrefix("menuBar.") }
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            XCTAssertNotNil(zh[key], "\(key) has no Simplified Chinese value")
            XCTAssertFalse((zh[key] ?? "").isEmpty, "\(key) is empty in Simplified Chinese")
        }
    }

    func testTheChineseComposerCopyKeepsTheWrittenRegister() throws {
        let (_, zh) = try Self.catalogs()
        // Second person, mood particles, exclamation marks and the banned
        // colloquial rendering of "surplus" — all of which read as chat rather
        // than as an interface.
        let banned = ["你", "您", "吧", "呢", "啦", "！", "用不完"]
        for (key, value) in zh where key.hasPrefix("menuBar.") {
            for term in banned {
                XCTAssertFalse(
                    value.contains(term),
                    "\(key) uses \(term), which the written register does not allow: \(value)"
                )
            }
        }
        // And the term the composer reuses from the forecast surfaces.
        XCTAssertEqual(zh["quota.forecast.verdict.surplus"], "盈余")
    }

    /// The two catalogs as flat key → value maps.
    private static func catalogs() throws -> ([String: String], [String: String]) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/i18n")
        func load(_ name: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { $0["value"] as? String }
        }
        return (try load("en.json"), try load("zh-Hans.json"))
    }

    // MARK: - A seeded name follows the language (review thread 2)

    func testASeededNameIsAReferenceAndATypedOneIsVerbatim() {
        let item = fieldItem(labels: ["claude.weekly": "C-wk"])
        let seeded = MenuBarComposition.seeded(template: .roomy, from: item)

        // Nothing derived is stored as words: the only literals in the seed
        // are the divider and the name the user typed.
        let literals: [String] = seeded.tokens.compactMap {
            if case let .text(text) = $0.kind { return text }
            return nil
        }
        XCTAssertEqual(literals, ["C-wk"])
        XCTAssertTrue(seeded.tokens.contains {
            $0.kind == .quota(fieldId: "claude.five_hour", metric: .label)
        })
    }

    func testTheSeededNameMovesWithTheLanguageAndTheTypedOneDoesNot() {
        var seeded = MenuBarComposition.seeded(
            template: .roomy,
            from: fieldItem(labels: ["claude.weekly": "C-wk"])
        )
        seeded.isEnabled = true

        // The resolver hands the planner an already-localized name, so a
        // language change arrives as a different snapshot label.
        func drawn(fiveHourLabel: String) -> [String] {
            texts(seeded.plan(
                quotas: [
                    quota("claude.five_hour", label: fiveHourLabel, used: 73, display: 73),
                    quota("claude.weekly", label: "Weekly", used: 40, display: 40)
                ],
                displayMode: .used,
                colorBasis: .actual,
                now: reference
            )).flatMap { $0 }
        }

        let english = drawn(fiveHourLabel: "5 Hours")
        let chinese = drawn(fiveHourLabel: "5 小时")
        XCTAssertTrue(english.contains("5 Hours"))
        XCTAssertTrue(chinese.contains("5 小时"))
        XCTAssertFalse(chinese.contains("5 Hours"), "the seeded name followed the language")
        // ...while the name the user typed is theirs in both.
        XCTAssertTrue(english.contains("C-wk"))
        XCTAssertTrue(chinese.contains("C-wk"), "a typed name is never translated")
    }

    func testASeededNameReferenceIsNotSpokenTwice() {
        // The round-six rule, in the shape the seed now produces: a name block
        // that refers to the very quota the next block reports says nothing of
        // its own.
        var seeded = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        seeded.isEnabled = true
        let rendered = seeded.plan(
            quotas: [
                quota("claude.five_hour", label: "5 Hours", used: 73, display: 73),
                quota("claude.weekly", label: "Weekly", used: 100, display: 100)
            ],
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        XCTAssertEqual(texts(rendered), [["5 Hours", "73%", "·", "Weekly", "100%"]])
        XCTAssertEqual(rendered.spokenDescription, "5 Hours 73% used, Weekly 100% used")
    }

    func testTwoNameBlocksInARowAreBothSpoken() {
        // Only a name followed by a *report* of the same quota is an echo.
        let rendered = plan(
            [
                MenuBarToken(kind: .quota(fieldId: "claude.five_hour", metric: .label)),
                MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .label))
            ],
            quotas: [
                quota("claude.five_hour", label: "5 Hours", used: 10, display: 10),
                quota("claude.weekly", label: "Weekly", used: 20, display: 20)
            ]
        )
        XCTAssertEqual(rendered.spokenDescription, "5 Hours, Weekly")
    }

    // MARK: - A composed strip claims its fields (review thread 1)

    private func discoveredRegistry() -> QuotaFieldRegistry {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return QuotaFieldRegistry(fields: [
            DiscoveredQuotaField(
                tool: .codex,
                bucketId: "gpt_reserve_weekly",
                title: "Weekly",
                groupTitle: "GPT-reserve",
                shortLabel: "Weekly",
                firstSeen: now,
                lastSeen: now
            )
        ])
    }

    func testAFieldOnlyTheComposedStripNamesSurvivesAPrune() {
        // The field is in no `selectedFieldIds` and has no custom label — the
        // composition is its only referrer, and it names it three ways none of
        // which the default strip knows about.
        let composed = composition([
            MenuBarToken(kind: .quota(fieldId: "codex.gpt_reserve_weekly", metric: .displayPercent)),
            MenuBarToken(
                kind: .text("!"),
                style: .init(color: .followsQuota(fieldId: "codex.gpt_reserve_weekly", basis: .actual))
            ),
            MenuBarToken(
                kind: .logo(.codex),
                visibility: .whenUsedAtLeast(fieldId: "codex.gpt_reserve_weekly", percent: 90)
            )
        ])
        XCTAssertEqual(composed.referencedFieldIds, ["codex.gpt_reserve_weekly"])

        var registry = discoveredRegistry()
        // The provider's next response omits the bucket.
        let dropped = registry.prune(
            tool: .codex,
            liveBucketIds: [],
            keeping: QuotaFieldKeepSet(fieldIds: Set(composed.referencedFieldIds))
        )
        XCTAssertFalse(dropped)
        XCTAssertNotNil(
            registry.field(id: "codex.gpt_reserve_weekly"),
            "a bucket the composed strip names must keep its display metadata"
        )
    }

    func testAFieldNothingNamesIsStillPruned() {
        var registry = discoveredRegistry()
        let dropped = registry.prune(tool: .codex, liveBucketIds: [], keeping: QuotaFieldKeepSet())
        XCTAssertTrue(dropped)
        XCTAssertNil(registry.field(id: "codex.gpt_reserve_weekly"))
    }

    // MARK: - A template applies the shape it names (review thread 2)

    private func rowCount(_ composed: MenuBarComposition) -> Int {
        composed.plan(
            quotas: [
                quota("claude.five_hour", label: "5 Hours", used: 40, display: 40),
                quota("claude.weekly", label: "Weekly", used: 60, display: 60)
            ],
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        ).rows.filter { !$0.isEmpty }.count
    }

    func testChoosingTwoRowsActuallyProducesTwoRows() {
        // The picker's own description says "Two stacked rows in one status
        // item". Setting the enum alone left the strip single-row, because
        // nothing had opened a second row on any of its columns.
        var composed = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        composed.isEnabled = true
        XCTAssertEqual(rowCount(composed), 1)

        composed.setTemplate(.twoColumn)
        XCTAssertEqual(composed.template, .twoColumn)
        XCTAssertEqual(rowCount(composed), 2)
    }

    func testTheSplitTakesOverTheDividerRatherThanJoiningIt() {
        // The row boundary lands where the seed would put it, swallowing the
        // divider between the two entries instead of leaving a dangling one.
        var composed = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        composed.setTemplate(.twoColumn)
        XCTAssertEqual(composed.segments.count, 1)
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [
            .quota(fieldId: "claude.five_hour", metric: .label),
            .quota(fieldId: "claude.five_hour", metric: .displayPercent)
        ])
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [
            .quota(fieldId: "claude.weekly", metric: .label),
            .quota(fieldId: "claude.weekly", metric: .displayPercent)
        ])
    }

    func testChoosingASingleRowTemplateJoinsTheRowsBackUp() {
        var composed = MenuBarComposition.seeded(template: .twoColumn, from: layoutItem(.twoRows))
        composed.isEnabled = true
        XCTAssertEqual(rowCount(composed), 2)

        composed.setTemplate(.roomy)
        XCTAssertFalse(composed.segments.contains(where: \.isStacked))
        XCTAssertEqual(rowCount(composed), 1)
        // The divider the row boundary took over comes back, so the entries
        // are still separated rather than run together.
        XCTAssertTrue(composed.tokens.contains { $0.kind == .separator("·") })
    }

    func testTheTwoDirectionsRoundTrip() {
        let original = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        var composed = original
        composed.setTemplate(.twoColumn)
        composed.setTemplate(.roomy)
        XCTAssertEqual(composed.tokens.map(\.kind), original.tokens.map(\.kind))
    }

    func testCompactRejoinsWithNothingBecauseThatIsWhatItDraws() {
        // Compact butts entries together with the ordinary token gap and draws
        // no character between them, so collapsing two rows into one leaves
        // the spacing to do the work rather than inserting punctuation.
        var composed = MenuBarComposition.seeded(template: .twoColumn, from: layoutItem(.twoRows))
        composed.setTemplate(.compact)
        XCTAssertFalse(composed.segments.contains(where: \.isStacked))
        XCTAssertFalse(composed.tokens.contains { $0.kind == .separator("·") })
        XCTAssertFalse(composed.tokens.contains { $0.kind == .space(width: 1) })
    }

    func testChoosingTwoRowsTwiceDoesNotSplitAgain() {
        var composed = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
        composed.setTemplate(.twoColumn)
        let split = composed.segments
        composed.setTemplate(.twoColumn)
        XCTAssertEqual(composed.segments, split)
    }

    func testAStripWithNothingToSplitIsLeftAlone() {
        var composed = composition([MenuBarToken(kind: .text("only"))])
        composed.setTemplate(.twoColumn)
        XCTAssertFalse(composed.segments.contains(where: \.isStacked))
        XCTAssertEqual(composed.tokens.map(\.kind), [.text("only")])
        XCTAssertEqual(composed.template, .twoColumn)
    }

    // MARK: - A field is chosen by the words it is drawn with (review thread 3)

    func testAnOptionIsNamedTheWayTheStripDrawsIt() {
        // The picker used to render the contract spelling while the strip drew
        // the resolved one, so the user chose "5 Hours" and got "5 小时".
        let fiveHour = MenuBarFieldCatalog.field(id: "claude.five_hour")!
        XCTAssertEqual(fiveHour.displayTitle, QuotaGroupLabelLocalizer.display("5 Hours"))
        XCTAssertEqual(fiveHour.displayDefaultLabel, QuotaGroupLabelLocalizer.display("5 Hours"))
    }

    func testAComposedTitleIsResolvedPartByPart() {
        // "All Models · Weekly": both halves are generic window words.
        let weekly = MenuBarFieldCatalog.field(id: "claude.weekly")!
        XCTAssertEqual(weekly.title, "All Models · Weekly")
        XCTAssertEqual(
            weekly.displayTitle,
            [QuotaGroupLabelLocalizer.display("All Models"),
             QuotaGroupLabelLocalizer.display("Weekly")].joined(separator: " · ")
        )
    }

    func testAProductNameInATitleIsNeverTranslated() {
        // "GPT-5.3 Codex Spark · 5 Hours": only the window half may move.
        let spark = MenuBarFieldCatalog.field(id: "codex.gpt_5_3_codex_spark_five_hour")!
        XCTAssertTrue(spark.displayTitle.hasPrefix("GPT-5.3 Codex Spark · "))
        XCTAssertFalse(QuotaGroupLabelLocalizer.isTranslated("GPT-5.3 Codex Spark"))
    }

    // MARK: - Nothing stored depends on the language (review thread 11)

    /// Run `body` with each supported language selected, restoring whatever
    /// was set before.
    private func underEachLanguage(_ body: (AppLanguage) -> Void) {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageOverride = language
            body(language)
        }
    }

    func testAddingABlockStoresNothingThatDependsOnTheLanguage() {
        // A placeholder is prompt copy that happened to be in the field, not
        // text the user typed. Persisting it froze whichever language was
        // selected when the block was made — a Chinese placeholder rendered
        // in an English menu bar forever after.
        var byLanguage: [AppLanguage: [MenuBarToken.Kind]] = [:]
        underEachLanguage { language in
            byLanguage[language] = MenuBarToken.paletteSamples().map(\.kind)
        }
        XCTAssertEqual(byLanguage[.english], byLanguage[.simplifiedChinese])
        // ...and specifically: a fresh text block carries no content at all.
        XCTAssertEqual(MenuBarToken.newText().kind, .text(""))
    }

    func testSeedingStoresNothingThatDependsOnTheLanguage() {
        // The same invariant on the other constructor, so round nine's fix
        // cannot regress either.
        var byLanguage: [AppLanguage: [MenuBarToken.Kind]] = [:]
        underEachLanguage { language in
            byLanguage[language] = MenuBarComposition
                .seeded(template: .roomy, from: fieldItem(labels: ["claude.weekly": "C-wk"]))
                .tokens
                .map(\.kind)
        }
        XCTAssertEqual(byLanguage[.english], byLanguage[.simplifiedChinese])
    }

    func testEveryStoredStringIsEitherTypedOrAnIdentifier() {
        // The rule in one assertion: no stored value may equal a catalog
        // string that differs between the two languages. A value that is the
        // same in both is either punctuation or a naming-axis identifier, and
        // those are safe to store.
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        func storedStrings() -> [String] {
            var seeded = MenuBarComposition.seeded(template: .roomy, from: fieldItem())
            for sample in MenuBarToken.paletteSamples() { seeded.append(sample) }
            return seeded.tokens.compactMap { token in
                switch token.kind {
                case let .text(value): return value
                case let .separator(value): return value
                default: return nil
                }
            }
        }

        L10n.languageOverride = .english
        let english = storedStrings()
        L10n.languageOverride = .simplifiedChinese
        let chinese = storedStrings()
        XCTAssertEqual(english, chinese)
        for value in english where !value.isEmpty {
            XCTAssertFalse(
                Self.isLocalizedCopy(value),
                "\(value) is copy that exists to be shown; it must not be stored"
            )
        }
    }

    /// Whether a string is one the catalog renders differently per language —
    /// which makes it copy, not an identifier.
    private static func isLocalizedCopy(_ value: String) -> Bool {
        // Reads the catalog files directly, so it neither depends on nor
        // touches the selected language — this runs inside a test that has
        // one set, and nudging a global from a helper is how a suite starts
        // failing depending on what ran before it.
        guard let (en, zh) = try? catalogs() else { return false }
        for (key, english) in en where english == value {
            if let chinese = zh[key], chinese != english { return true }
        }
        return false
    }

    func testAnEmptyTextBlockDrawsNothing() {
        // The decision this fix turns on: no reserved gap. The block is in the
        // editor, which says so; the menu bar spends no width on it.
        let rendered = plan(
            [
                MenuBarToken(kind: .text("before")),
                MenuBarToken.newText(),
                MenuBarToken(kind: .text("after"))
            ],
            quotas: []
        )
        XCTAssertEqual(texts(rendered), [["before", "after"]])
        XCTAssertEqual(rendered.spokenDescription, "before, after")
    }

    func testWhitespaceTheUserTypedIsStillContent() {
        // Spaces are a gap they asked for, not an empty block.
        let rendered = plan([MenuBarToken(kind: .text("   "))], quotas: [])
        XCTAssertEqual(texts(rendered), [["   "]])
        // It says nothing, though — there are no words in it.
        XCTAssertTrue(rendered.spokenDescription.isEmpty)
    }

    // MARK: - A downgrade must not delete blocks (review thread 12)

    /// A token as a newer build might have written it.
    private func tokenJSON(
        id: String = "11111111-1111-1111-1111-111111111111",
        kind: String = #"{"type":"text","text":"keep"}"#,
        size: String = #""regular""#,
        weight: String = #""medium""#,
        color: String = #"{"type":"tertiary"}"#,
        monospacedDigits: Bool = true
    ) -> String {
        """
        {"id":"\(id)","kind":\(kind),
         "style":{"color":\(color),"size":\(size),"weight":\(weight),
                  "monospacedDigits":\(monospacedDigits)},
         "visibility":{"type":"always"}}
        """
    }

    private func decodeComposition(tokens: [String]) throws -> MenuBarComposition {
        let json = #"{"isEnabled":true,"template":"roomy","tokens":["#
            + tokens.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
    }

    func testAnUnknownSizeOrWeightKeepsTheBlock() throws {
        // The named bug: the synthesized `Style` decoder threw on a value a
        // newer build wrote, `LossyMenuBarToken` turned that into a dropped
        // block, and the next save wrote the deletion to disk.
        let composed = try decodeComposition(tokens: [
            tokenJSON(size: #""colossal""#),
            tokenJSON(id: "22222222-2222-2222-2222-222222222222", weight: #""ultrablack""#)
        ])
        XCTAssertEqual(composed.tokens.count, 2, "neither block may be dropped")
        XCTAssertEqual(composed.tokens[0].kind, .text("keep"))
        XCTAssertEqual(composed.tokens[1].kind, .text("keep"))
        // Only the attribute this build cannot read falls back. Catching the
        // failure a level up would keep the block but reset its whole style,
        // silently discarding the colour and weight the user chose.
        XCTAssertEqual(composed.tokens[0].style.size, .regular, "the unreadable one")
        XCTAssertEqual(composed.tokens[0].style.weight, .medium, "kept as written")
        XCTAssertEqual(composed.tokens[0].style.color, .tertiary, "kept as written")
        XCTAssertTrue(composed.tokens[0].style.monospacedDigits, "kept as written")
        XCTAssertEqual(composed.tokens[1].style.weight, .medium, "the unreadable one")
        XCTAssertEqual(composed.tokens[1].style.color, .tertiary, "kept as written")
        XCTAssertEqual(composed.tokens[1].style.size, .regular)
    }

    func testAnUnknownQuotaMetricKeepsTheBlockAsWritten() throws {
        // Substituting a readable metric looked like graceful degradation and
        // was destructive: the next save wrote the substitute back, so a round
        // trip through an older build permanently changed what the user chose.
        let composed = try decodeComposition(tokens: [
            tokenJSON(
                kind: #"{"type":"quota","fieldId":"claude.weekly","metric":"vibes"}"#
            )
        ])
        XCTAssertEqual(composed.tokens.count, 1, "the block is kept")
        guard case .unsupported = composed.tokens[0].kind else {
            return XCTFail("an unknown metric must be preserved, not substituted")
        }
        // And handed back byte-for-byte, which is the whole point.
        let round = try JSONEncoder().encode(composed)
        let json = String(decoding: round, as: UTF8.self)
        XCTAssertTrue(json.contains("vibes"), "the original metric survives a save")
    }

    func testAnUnknownBlockKindIsKeptVerbatimRatherThanDeleted() throws {
        let composed = try decodeComposition(tokens: [
            tokenJSON(),
            tokenJSON(
                id: "33333333-3333-3333-3333-333333333333",
                kind: #"{"type":"sparkline","fieldId":"claude.weekly","window":"7d"}"#
            )
        ])
        XCTAssertEqual(composed.tokens.count, 2)
        guard case .unsupported = composed.tokens[1].kind else {
            return XCTFail("expected the unknown block to be preserved")
        }
        // Draws nothing, says nothing...
        let rendered = composed.plan(
            quotas: [], displayMode: .used, colorBasis: .actual, now: reference
        )
        XCTAssertEqual(texts(rendered), [["keep"]])
        XCTAssertEqual(rendered.spokenDescription, "keep")

        // ...and goes back out unchanged, so a newer build finds it again.
        let reencoded = try JSONEncoder().encode(composed)
        let raw = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        let rawTokens = raw?["tokens"] as? [[String: Any]]
        let preserved = (rawTokens?[1]["kind"] as? [String: Any]) ?? [:]
        XCTAssertEqual(preserved["type"] as? String, "sparkline")
        XCTAssertEqual(preserved["fieldId"] as? String, "claude.weekly")
        XCTAssertEqual(preserved["window"] as? String, "7d")
    }

    func testAProviderThisBuildDoesNotKnowKeepsItsBlock() throws {
        // The realistic instance: a logo naming a provider added after this
        // version shipped. `ToolType` gains cases regularly.
        let composed = try decodeComposition(tokens: [
            tokenJSON(kind: #"{"type":"logo","tool":"someFutureProvider"}"#)
        ])
        XCTAssertEqual(composed.tokens.count, 1)
        guard case .unsupported = composed.tokens[0].kind else {
            return XCTFail("expected the block to be preserved")
        }
    }

    func testAnUnknownLayoutKeepsTheWholeMenuBarItem() throws {
        // Worse than the named bug, found by applying the same lens: an
        // unreadable `layout` threw, `LossyMenuBarItem` dropped the item, and
        // the field selection, every rename, every per-field style and the
        // composed strip went with it.
        let json = """
        {"kind":"compact","isVisible":true,"showTitle":false,"layout":"notchIsland",
         "selectedFieldIds":["claude.five_hour"],"customLabels":{"claude.five_hour":"C5"},
         "fieldStyles":{"claude.five_hour":"logoAndPercent"},"mergesGroupWindows":true}
        """
        let item = try JSONDecoder().decode(MenuBarItemSettings.self, from: Data(json.utf8))
        XCTAssertEqual(item.selectedFieldIds, ["claude.five_hour"])
        XCTAssertEqual(item.customLabels, ["claude.five_hour": "C5"])
        XCTAssertEqual(item.style(for: "claude.five_hour"), .logoAndPercent)
        XCTAssertTrue(item.mergesGroupWindows)
        XCTAssertEqual(item.layout, .iconOnly, "only the unreadable enum falls back")
    }

    func testAMalformedScalarKeepsTheStrip() throws {
        // One bad number used to throw out of the composition decoder, which
        // the item catches into `composition = nil` — every block gone.
        let json = #"{"isEnabled":true,"template":"roomy","fontScale":"wide","tokens":["#
            + tokenJSON() + "]}"
        let composed = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(composed.tokens.count, 1)
        XCTAssertNil(composed.fontScale)
        XCTAssertEqual(composed.effectiveFontScale, MenuBarComposition.Template.roomy.fontScale)
    }

    func testOneUnreadableRegistryEntryDoesNotDiscardTheRest() throws {
        // `QuotaService` loads this with `try? … ?? .empty`, so a decoder that
        // threw on one row silently emptied the whole registry — and the next
        // refresh rewrote the file without any of it, losing precisely the
        // rows the keep set exists to protect.
        let json = """
        {"fields":[
          {"tool":"claude","bucketId":"weekly_new","title":"Weekly","groupTitle":"New",
           "shortLabel":"New","firstSeen":0,"lastSeen":0},
          {"tool":"someFutureProvider","bucketId":"weekly","title":"Weekly",
           "shortLabel":"Weekly","firstSeen":0,"lastSeen":0}
        ]}
        """
        let registry = try JSONDecoder().decode(QuotaFieldRegistry.self, from: Data(json.utf8))
        XCTAssertEqual(registry.fields.count, 1, "only the unreadable row is dropped")
        XCTAssertEqual(registry.fields.first?.bucketId, "weekly_new")
    }

    // MARK: - A template draws at its renderer's face (review thread 2)

    func testEachTemplateAsksForTheFaceItsRendererUses() {
        // Compact's seed is one row, and the built-in compact renderer draws
        // at the 9pt face — asking for the system face made the seeded strip
        // noticeably larger than the strip it reproduced.
        XCTAssertEqual(MenuBarStripGeometry.face(template: .compact, rowCount: 1), .compact)
        XCTAssertEqual(MenuBarStripGeometry.face(template: .roomy, rowCount: 1), .system)
        // Two rows always go through the rasterizer, whatever the template.
        for template in MenuBarComposition.Template.allCases {
            XCTAssertEqual(
                MenuBarStripGeometry.face(template: template, rowCount: 2),
                .compact,
                "\(template) at two rows"
            )
        }
    }

    func testCompactDoesNotScaleItsFaceDownAgain() {
        // Its smallness is the face, not a multiplier applied to a larger one.
        for template in MenuBarComposition.Template.allCases {
            XCTAssertEqual(template.fontScale, 1.0, "\(template)")
        }
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
            MenuBarToken(kind: .space(width: 1)),
            MenuBarToken(kind: .separator(" · "), style: .divider)
        ]
        let underneath = [
            MenuBarToken(
                kind: .quota(fieldId: "codex.five_hour", metric: .pace),
                style: .init(color: .followsQuota(fieldId: "codex.five_hour", basis: .forecast)),
                visibility: .whenRemainingAtMost(fieldId: "codex.five_hour", percent: 25)
            )
        ]
        let composed = MenuBarComposition(
            isEnabled: true,
            template: .twoColumn,
            segments: [MenuBarSegment(top: tokens, bottom: underneath)],
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
        item.composition?.append(MenuBarToken(kind: .text("tail")))
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

    func testAnUnreadableBlockIsKeptRatherThanDroppedFromTheStrip() throws {
        // This used to assert the block was dropped. Dropping is a silent,
        // permanent deletion the moment the settings file is saved again, so
        // an unreadable block is now preserved verbatim instead — see
        // `MenuBarToken.Kind.unsupported`.
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
        XCTAssertEqual(decoded.tokens.count, 2)
        XCTAssertEqual(decoded.tokens[0].kind, .text("keep"))
        guard case .unsupported = decoded.tokens[1].kind else {
            return XCTFail("the unreadable block should be preserved")
        }
        // It contributes nothing to the strip either way.
        let rendered = decoded.plan(
            quotas: [], displayMode: .used, colorBasis: .actual, now: reference
        )
        XCTAssertEqual(texts(rendered), [["keep"]])
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

    // MARK: - Groups

    private func grouped(_ groups: [[MenuBarToken]]) -> MenuBarComposition {
        columns(groups.map { MenuBarSegment(tokens: $0) })
    }

    private func columns(_ segments: [MenuBarSegment]) -> MenuBarComposition {
        MenuBarComposition(isEnabled: true, template: .twoColumn, segments: segments)
    }

    func testEachGroupIsOneColumnAndASecondRowStacksIt() {
        let composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(tokens: [MenuBarToken(kind: .text("c"))])
        ])
        let rendered = composed.plan(
            quotas: [], displayMode: .used, colorBasis: .actual, now: reference
        )
        XCTAssertEqual(rendered.columns.count, 2)
        XCTAssertEqual(rendered.columns[0].top.tokens.compactMap(\.text), ["a"])
        XCTAssertEqual(rendered.columns[0].bottom?.tokens.compactMap(\.text), ["b"])
        // One row, so this column has one cell — what the rasterizer centres
        // across both rows.
        XCTAssertEqual(rendered.columns[1].top.tokens.compactMap(\.text), ["c"])
        XCTAssertNil(rendered.columns[1].bottom)
    }

    func testAGroupWhoseBlocksAllFellAwayLeavesTheOthersAlone() {
        let composed = grouped([
            [MenuBarToken(kind: .quota(fieldId: "gone.bucket", metric: .displayPercent))],
            [MenuBarToken(kind: .text("kept"))]
        ])
        let rendered = composed.plan(
            quotas: [], displayMode: .used, colorBasis: .actual, now: reference
        )
        XCTAssertEqual(rendered.columns.count, 1)
        XCTAssertEqual(rendered.columns[0].top.tokens.compactMap(\.text), ["kept"])
    }

    func testAGroupLeftWithOnlyItsLowerCellBecomesAOneCellColumn() {
        // Not a column with a hole in it: the upper cell's only block is
        // hidden by its rule, and a cell with nothing in it is not a cell.
        let composed = columns([MenuBarSegment(
            top: [MenuBarToken(
                kind: .text("hidden"),
                visibility: .whenUsedAtLeast(fieldId: "claude.weekly", percent: 90)
            )],
            bottom: [MenuBarToken(kind: .text("shown"))]
        )])
        let rendered = composed.plan(
            quotas: [quota("claude.weekly", used: 10)],
            displayMode: .used,
            colorBasis: .actual,
            now: reference
        )
        XCTAssertEqual(rendered.columns.count, 1)
        XCTAssertNil(rendered.columns[0].bottom)
        XCTAssertEqual(rendered.columns[0].top.tokens.compactMap(\.text), ["shown"])
    }

    func testAOneRowStripSeparatesItsGroupsTheWayItsTemplateDoes() {
        // The same table the seed reads, so a hand-grouped strip is divided
        // the way the layout it came from divides its entries.
        for template in MenuBarComposition.Template.allCases {
            let composed = MenuBarComposition(
                isEnabled: true,
                template: template,
                segments: [
                    MenuBarSegment(tokens: [MenuBarToken(kind: .text("a"))]),
                    MenuBarSegment(tokens: [MenuBarToken(kind: .text("b"))])
                ]
            )
            let rendered = composed.plan(
                quotas: [], displayMode: .used, colorBasis: .actual, now: reference
            )
            XCTAssertFalse(rendered.isTwoRow, "\(template)")
            let expected: String?
            if case let .separator(text)? = MenuBarFieldStripRules
                .separator(for: template.seededFrom) {
                expected = text
            } else {
                expected = nil
            }
            XCTAssertEqual(rendered.columnSeparator, expected, "\(template)")
        }
    }

    func testAStripIsSpokenColumnByColumn() {
        let composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(tokens: [MenuBarToken(kind: .text("c"))])
        ])
        let rendered = composed.plan(
            quotas: [], displayMode: .used, colorBasis: .actual, now: reference
        )
        XCTAssertEqual(rendered.spokenDescription, "a · b · c")
    }

    func testABlockMovesBetweenGroupsAndTheGroupsSurviveIt() {
        var composed = grouped([
            [MenuBarToken(kind: .text("a")), MenuBarToken(kind: .text("b"))],
            [MenuBarToken(kind: .text("c"))]
        ])
        let moved = composed.segments[0].tokens[1].id
        let target = composed.segments[1].tokens[0].id
        composed.move(moved, before: target)
        XCTAssertEqual(composed.segments.map { $0.tokens.map(\.kind) }, [
            [.text("a")],
            [.text("b"), .text("c")]
        ])
        // ...and back again, onto the end of the first group's top row.
        composed.move(moved, toEndOf: .init(segment: composed.segments[0].id, row: .top))
        XCTAssertEqual(composed.segments.map { $0.tokens.map(\.kind) }, [
            [.text("a"), .text("b")],
            [.text("c")]
        ])
    }

    func testABlockMovesBetweenTheTwoRowsOfOneGroup() {
        // The same gesture as a move between groups, because a row is a
        // container the drop target can name.
        var composed = columns([MenuBarSegment(
            top: [MenuBarToken(kind: .text("a")), MenuBarToken(kind: .text("b"))],
            bottom: [MenuBarToken(kind: .text("c"))]
        )])
        let group = composed.segments[0].id
        let moved = composed.segments[0].top[1].id
        composed.move(moved, toEndOf: .init(segment: group, row: .bottom))
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [.text("a")])
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [.text("c"), .text("b")])
        // ...and in front of a chip in the row above.
        composed.move(moved, before: composed.segments[0].top[0].id)
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [.text("b"), .text("a")])
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [.text("c")])
    }

    func testARowThatDoesNotExistIsNotADropTarget() {
        var composed = grouped([
            [MenuBarToken(kind: .text("a"))],
            [MenuBarToken(kind: .text("b"))]
        ])
        let before = composed.segments
        composed.move(
            composed.segments[0].top[0].id,
            toEndOf: .init(segment: composed.segments[1].id, row: .bottom)
        )
        XCTAssertEqual(composed.segments, before)
    }

    func testSplittingAndMergingAreInverses() {
        var composed = grouped([[
            MenuBarToken(kind: .text("a")),
            MenuBarToken(kind: .text("b")),
            MenuBarToken(kind: .text("c"))
        ]])
        let pivot = composed.segments[0].tokens[1].id
        composed.splitSegment(before: pivot)
        XCTAssertEqual(composed.segments.map { $0.tokens.map(\.kind) }, [
            [.text("a")],
            [.text("b"), .text("c")]
        ])
        composed.mergeSegmentIntoPrevious(composed.segments[1].id)
        XCTAssertEqual(composed.segments.map { $0.tokens.map(\.kind) }, [
            [.text("a"), .text("b"), .text("c")]
        ])
    }

    func testSplittingAtTheFirstBlockOfAGroupIsANoOp() {
        var composed = grouped([[MenuBarToken(kind: .text("a")), MenuBarToken(kind: .text("b"))]])
        composed.splitSegment(before: composed.segments[0].tokens[0].id)
        XCTAssertEqual(composed.segments.count, 1)
    }

    func testSplittingCutsAColumnVerticallyAndMergingPutsItBack() {
        // A column is cut through its top row and its lower cell comes along,
        // so both halves are still columns the strip can draw.
        var composed = columns([MenuBarSegment(
            top: [MenuBarToken(kind: .text("a")), MenuBarToken(kind: .text("b"))],
            bottom: [MenuBarToken(kind: .text("c"))]
        )])
        composed.splitSegment(before: composed.segments[0].top[1].id)
        XCTAssertEqual(composed.segments.map { $0.top.map(\.kind) }, [[.text("a")], [.text("b")]])
        XCTAssertEqual(composed.segments.map { $0.bottom?.map(\.kind) }, [nil, [.text("c")]])

        composed.mergeSegmentIntoPrevious(composed.segments[1].id)
        XCTAssertEqual(composed.segments.count, 1)
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [.text("a"), .text("b")])
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [.text("c")])
    }

    func testAColumnIsNotCutThroughItsLowerRow() {
        var composed = columns([MenuBarSegment(
            top: [MenuBarToken(kind: .text("a"))],
            bottom: [MenuBarToken(kind: .text("b")), MenuBarToken(kind: .text("c"))]
        )])
        let before = composed.segments
        composed.splitSegment(before: composed.segments[0].bottom![1].id)
        XCTAssertEqual(composed.segments, before)
    }

    func testMergingTwoStackedColumnsJoinsThemRowByRow() {
        var composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("c"))],
                bottom: [MenuBarToken(kind: .text("d"))]
            )
        ])
        composed.mergeSegmentIntoPrevious(composed.segments[1].id)
        XCTAssertEqual(composed.segments.count, 1)
        XCTAssertEqual(composed.segments[0].top.map(\.kind), [.text("a"), .text("c")])
        XCTAssertEqual(composed.segments[0].bottom?.map(\.kind), [.text("b"), .text("d")])
    }

    func testGroupsReorderAndTheEndsAreNoOpsRatherThanTraps() {
        var composed = grouped([
            [MenuBarToken(kind: .text("a"))],
            [MenuBarToken(kind: .text("b"))],
            [MenuBarToken(kind: .text("c"))]
        ])
        let first = composed.segments[0].id
        composed.moveSegment(first, by: -1)
        XCTAssertEqual(composed.segments.first?.id, first)
        composed.moveSegment(first, by: 2)
        XCTAssertEqual(composed.segments.map { $0.tokens.map(\.kind) }, [
            [.text("b")], [.text("c")], [.text("a")]
        ])
        composed.moveSegment(first, by: 9)
        XCTAssertEqual(composed.segments.last?.id, first)
    }

    func testTheRowCapIsPerGroupBecauseEveryGroupHasItsOwnTwoRows() {
        let composed = columns([
            MenuBarSegment(top: [MenuBarToken(kind: .text("a"))], bottom: []),
            MenuBarSegment(tokens: [MenuBarToken(kind: .text("b"))])
        ])
        XCTAssertFalse(composed.canAddRow(toSegment: composed.segments[0].id))
        XCTAssertTrue(composed.canAddRow(toSegment: composed.segments[1].id))
    }

    // MARK: - Groups survive a settings file, and a downgrade

    func testAStoredStripFromBeforeGroupsDecodesAsOneGroupWithItsRows() throws {
        let json = """
        {"isEnabled":true,"template":"twoColumn","tokens":[
          {"kind":{"type":"text","text":"a"}},
          {"kind":{"type":"lineBreak"}},
          {"kind":{"type":"text","text":"b"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments[0].top.map(\.kind), [.text("a")])
        XCTAssertEqual(decoded.segments[0].bottom?.map(\.kind), [.text("b")])
    }

    func testAStoredGroupWithABreakInItDecodesIntoTwoRows() throws {
        // The shape this branch's own dev builds wrote: groups existed, rows
        // did not, so the break sat inside the group's one list.
        let json = """
        {"isEnabled":true,"template":"twoColumn","segments":[
          {"tokens":[
            {"kind":{"type":"text","text":"a"}},
            {"kind":{"type":"lineBreak"}},
            {"kind":{"type":"text","text":"b"}},
            {"kind":{"type":"lineBreak"}},
            {"kind":{"type":"text","text":"c"}}
          ]}
        ]}
        """
        let decoded = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments[0].top.map(\.kind), [.text("a")])
        // A second marker cannot open a third row, so its blocks stay on the
        // bottom — the folding the flat model always did.
        XCTAssertEqual(decoded.segments[0].bottom?.map(\.kind), [.text("b"), .text("c")])
    }

    func testAStoredPresetWithABreakInItDecodesIntoTwoRows() throws {
        let json = """
        {"name":"Claude","tokens":[
          {"kind":{"type":"text","text":"a"}},
          {"kind":{"type":"lineBreak"}},
          {"kind":{"type":"text","text":"b"}}
        ]}
        """
        let decoded = try JSONDecoder().decode(
            MenuBarSegmentPreset.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.top.map(\.kind), [.text("a")])
        XCTAssertEqual(decoded.bottom?.map(\.kind), [.text("b")])
        XCTAssertEqual(decoded.segment().bottom?.map(\.kind), [.text("b")])
    }

    func testGroupsRoundTripAndKeepTheirIdentities() throws {
        let composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(tokens: [MenuBarToken(kind: .text("c"))])
        ])
        let decoded = try JSONDecoder().decode(
            MenuBarComposition.self,
            from: try JSONEncoder().encode(composed)
        )
        XCTAssertEqual(decoded.segments.map(\.id), composed.segments.map(\.id))
        XCTAssertEqual(
            decoded.segments.map { $0.tokens.map(\.id) },
            composed.segments.map { $0.tokens.map(\.id) }
        )
    }

    func testABuildWithoutGroupsStillFindsEveryBlock() throws {
        // The one that has already gone wrong once: a downgrade that reads
        // nothing draws an empty status item and then saves that emptiness
        // over the user's strip. It reads `tokens`, so `tokens` is written
        // too — every block, in the reading order the columns had.
        let composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("c"))],
                bottom: [MenuBarToken(kind: .text("d"))]
            ),
            MenuBarSegment(tokens: [MenuBarToken(kind: .appIcon)])
        ])
        let downgraded = try downgrade(composed)
        let expected: [MenuBarToken.Kind] = [
            .text("a"), .text("c"), .appIcon, .text("b"), .text("d")
        ]
        XCTAssertEqual(
            downgraded.tokens.map(\.kind),
            expected,
            "top cells then bottom cells, nothing dropped"
        )
        // ...and it lands as the two rows the columns were read in, because
        // the marker an older build looks for was written between them.
        XCTAssertEqual(downgraded.segments.count, 1)
        XCTAssertEqual(
            downgraded.segments[0].top.map(\.kind),
            [.text("a"), .text("c"), .appIcon]
        )
        XCTAssertEqual(downgraded.segments[0].bottom?.map(\.kind), [.text("b"), .text("d")])
        // Every block, with the identity it had. The grouping is what a build
        // without groups cannot hold; nothing else is lost.
        XCTAssertEqual(Set(downgraded.tokens.map(\.id)), Set(composed.tokens.map(\.id)))
    }

    /// The composition an older build would decode: everything this one wrote,
    /// minus the key it has never heard of.
    private func downgrade(_ composed: MenuBarComposition) throws -> MenuBarComposition {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(composed))
                as? [String: Any]
        )
        XCTAssertNotNil(object["segments"], "this build reads groups")
        object.removeValue(forKey: "segments")
        return try JSONDecoder().decode(
            MenuBarComposition.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
    }

    func testAOneRowStripWritesNoRowBreakAtAll() throws {
        // The mirror is content-faithful: nothing that would come back as a
        // block the user never made, and a break with nothing under it is one.
        let composed = grouped([
            [MenuBarToken(kind: .text("a"))],
            [MenuBarToken(kind: .text("b"))]
        ])
        let encoded = String(decoding: try JSONEncoder().encode(composed), as: UTF8.self)
        XCTAssertFalse(encoded.contains(MenuBarFlatToken.rowBreakDiscriminator))
        let downgraded = try downgrade(composed)
        XCTAssertFalse(downgraded.segments[0].isStacked)
        XCTAssertEqual(downgraded.tokens.map(\.kind), [.text("a"), .text("b")])
    }

    func testAnEmptySecondRowIsNotWrittenIntoTheMirror() throws {
        // An opened-but-unfilled row is kept in `segments`, where it means
        // something; in the flat list it would be a trailing marker naming a
        // row with nothing in it.
        let composed = columns([MenuBarSegment(
            top: [MenuBarToken(kind: .text("a"))],
            bottom: []
        )])
        XCTAssertEqual(
            try JSONDecoder()
                .decode(MenuBarComposition.self, from: try JSONEncoder().encode(composed))
                .segments[0].bottom,
            [],
            "this build keeps the row the user opened"
        )
        let downgraded = try downgrade(composed)
        XCTAssertFalse(downgraded.segments[0].isStacked)
        XCTAssertEqual(downgraded.tokens.map(\.kind), [.text("a")])
    }

    func testAStripThatComesBackFromAnOlderBuildKeepsItsRows() throws {
        // The full round trip: this build writes, an older one reads its flat
        // list and saves it again, this one reads that. The grouping is gone,
        // the rows and every block are not.
        let composed = columns([
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            ),
            MenuBarSegment(tokens: [MenuBarToken(kind: .appIcon)])
        ])
        let returned = try downgrade(try downgrade(composed))
        XCTAssertEqual(returned.segments[0].top.map(\.kind), [.text("a"), .appIcon])
        XCTAssertEqual(returned.segments[0].bottom?.map(\.kind), [.text("b")])
        XCTAssertEqual(Set(returned.tokens.map(\.id)), Set(composed.tokens.map(\.id)))
    }

    // MARK: - Saved groups

    func testAPresetInsertsAsANewGroupWithFreshIdentities() {
        let tokens = [
            MenuBarToken(kind: .text("VB")),
            MenuBarToken(kind: .quota(fieldId: "claude.weekly", metric: .displayPercent))
        ]
        let preset = MenuBarSegmentPreset(name: "Claude", top: tokens)
        var composed = grouped([[MenuBarToken(kind: .text("a"))]])
        composed.appendSegment(preset.segment())
        composed.appendSegment(preset.segment())
        XCTAssertEqual(composed.segments.count, 3)
        XCTAssertEqual(composed.segments[1].tokens.map(\.kind), tokens.map(\.kind))
        // Two insertions are two groups the editor can drag apart, the same
        // rule `duplicate` follows.
        XCTAssertTrue(
            Set(composed.segments[1].tokens.map(\.id))
                .isDisjoint(with: Set(composed.segments[2].tokens.map(\.id)))
        )
        XCTAssertTrue(
            Set(composed.segments[1].tokens.map(\.id))
                .isDisjoint(with: Set(tokens.map(\.id)))
        )
    }

    func testAPresetKeepsAQuotaThisMacNoLongerReturns() throws {
        // Not filtered on the way in or out. Inserted, it is a block like any
        // other and the availability warning already explains it.
        let preset = MenuBarSegmentPreset(
            name: "Old",
            top: [MenuBarToken(kind: .quota(fieldId: "gone.bucket", metric: .displayPercent))]
        )
        let decoded = try JSONDecoder().decode(
            MenuBarSegmentPreset.self,
            from: try JSONEncoder().encode(preset)
        )
        XCTAssertEqual(decoded.top.map(\.kind), preset.top.map(\.kind))

        var composed = grouped([[]])
        composed.appendSegment(decoded.segment())
        let availability = composed.availability(liveFieldIds: ["claude.weekly"])
        XCTAssertEqual(availability.missingFieldIds, ["gone.bucket"])
        XCTAssertEqual(availability.silentTokenIds.count, 1)
    }

    func testPresetsSurviveAReseedAndASettingsRoundTrip() throws {
        var item = fieldItem()
        item.segmentPresets = [
            MenuBarSegmentPreset(
                name: "Claude",
                top: [MenuBarToken(kind: .text("VB"))],
                bottom: [MenuBarToken(kind: .appIcon)]
            )
        ]
        item.setComposedStripEnabled(true)
        item.reseedComposedStrip(template: .twoColumn)
        XCTAssertEqual(item.segmentPresets.map(\.name), ["Claude"])
        let decoded = try JSONDecoder().decode(
            MenuBarItemSettings.self,
            from: try JSONEncoder().encode(item)
        )
        XCTAssertEqual(decoded.segmentPresets, item.segmentPresets)
    }

    // MARK: - Space width

    func testASpaceDrawsAsManySpacesAsItIsWide() {
        let rendered = plan(
            [MenuBarToken(kind: .space(width: 4))],
            quotas: []
        )
        XCTAssertEqual(rendered.rows[0].tokens.compactMap(\.text), ["    "])
        // Still not spoken: a gap is not a word.
        XCTAssertEqual(rendered.spokenDescription, "")
    }

    func testANewSpaceIsOneWideAndAnOutOfRangeOneIsClamped() {
        XCTAssertEqual(MenuBarToken.newSpace().kind, .space(width: 1))
        let wide = plan([MenuBarToken(kind: .space(width: 99))], quotas: [])
        XCTAssertEqual(
            wide.rows[0].tokens.compactMap(\.text),
            [String(repeating: " ", count: MenuBarToken.spaceWidthRange.upperBound)]
        )
    }

    func testASpaceWidthRoundTripsAndADowngradeStillDrawsASpace() throws {
        let composed = composition([MenuBarToken(kind: .space(width: 5))])
        let encoded = try JSONEncoder().encode(composed)
        XCTAssertEqual(
            try JSONDecoder().decode(MenuBarComposition.self, from: encoded).tokens[0].kind,
            .space(width: 5)
        )
        // An older build reads the discriminator and ignores the width: the
        // block survives one space wide rather than becoming unsupported.
        let json = """
        {"isEnabled":true,"template":"roomy","tokens":[{"kind":{"type":"space"}}]}
        """
        let old = try JSONDecoder().decode(MenuBarComposition.self, from: Data(json.utf8))
        XCTAssertEqual(old.tokens.map(\.kind), [.space(width: 1)])
    }

    func testADefaultWidthWritesTheBytesTheFileAlreadyHad() throws {
        // A strip that predates the width control must not start producing a
        // diff on every save just because the model grew a field.
        let encoded = try JSONEncoder().encode(
            composition([MenuBarToken(kind: .space(width: 1))])
        )
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("width"))
    }

    // MARK: - A size choice costs only the block that made it

    func testASpanningColumnIsFittedAgainstTheWholeCanvasNotTheTopRow() {
        // A one-cell column is centred across both bands, so its height is the
        // whole canvas. Counting it in the top row's demand let a Large title
        // cap every stacked top cell — and capped the title itself as though
        // it had half the room it actually has.
        var composed = columns([
            MenuBarSegment(top: [MenuBarToken(kind: .text("VB"), style: .init(size: .large))]),
            MenuBarSegment(
                top: [MenuBarToken(kind: .text("a"))],
                bottom: [MenuBarToken(kind: .text("b"))]
            )
        ])
        composed.fontScale = 1
        // The nominal canvas, where it bites: two rows plus their spacing are
        // already over budget with nothing resized, so a stacked cell is
        // shrunk to fit. A cell that spans both rows is not stacked and pays
        // none of that — 18pt is the whole of its budget, and 1.2 fits.
        let rendered = composed.plan(
            quotas: [], displayMode: .used, colorBasis: .actual,
            now: reference, canvas: .nominalTwoRow
        )
        let spanning = rendered.columns[0].top.tokens[0].fontScale
        let stackedTop = rendered.columns[1].top.tokens[0].fontScale
        XCTAssertEqual(
            spanning, 1.2, accuracy: 0.0001,
            "a spanning cell must keep the size it asked for; the whole canvas is its row"
        )
        XCTAssertLessThan(
            stackedTop, 1.0,
            "the stacked rows still share one canvas and are still fitted to it"
        )
    }

    private func twoRowScales(
        top: MenuBarToken.SizeStep,
        bottom: MenuBarToken.SizeStep,
        compositionScale: Double = 1,
        canvas: MenuBarStripCanvas = .nominalTwoRow
    ) -> (top: Double, bottom: Double) {
        var composed = columns([MenuBarSegment(
            top: [MenuBarToken(kind: .text("a"), style: .init(size: top))],
            bottom: [MenuBarToken(kind: .text("b"), style: .init(size: bottom))]
        )])
        composed.fontScale = compositionScale
        let rendered = composed.plan(
            quotas: [],
            displayMode: .used,
            colorBasis: .actual,
            now: reference,
            canvas: canvas
        )
        return (
            rendered.columns[0].top.tokens[0].fontScale,
            rendered.columns[0].bottom?.tokens[0].fontScale ?? 0
        )
    }

    func testGrowingOneRowNeverChangesTheRowThatAskedForNothing() {
        // The complaint, as a property. Choosing Large used to solve one
        // uniform scale for the whole strip, so every block the user had not
        // touched came out smaller than before they touched anything.
        for canvas in [MenuBarStripCanvas.nominalTwoRow, roomierCanvas] {
            for scale in [0.8, 1.0, 1.3, MenuBarComposition.fontScaleRange.upperBound] {
                let untouched = twoRowScales(
                    top: .regular, bottom: .regular, compositionScale: scale, canvas: canvas
                )
                for chosen in MenuBarToken.SizeStep.allCases {
                    let after = twoRowScales(
                        top: chosen, bottom: .regular, compositionScale: scale, canvas: canvas
                    )
                    let label = "\(chosen) at \(scale), canvas \(canvas.availableHeight)"
                    // Never smaller. That is the whole rule: the cost of a
                    // size choice lands on the block that made it.
                    XCTAssertGreaterThanOrEqual(
                        after.bottom, untouched.bottom - 1e-9,
                        "the untouched row shrank for \(label)"
                    )
                    if chosen != .small {
                        // Growing takes only from the surplus, so the row that
                        // asked for nothing is exactly where it was. (A row
                        // that asked to be *smaller* gives height back, and
                        // the strip is allowed to stop squeezing the other
                        // one — a bigger untouched row is not a cost.)
                        XCTAssertEqual(
                            after.bottom, untouched.bottom, accuracy: 1e-9,
                            "the untouched row moved for \(label)"
                        )
                    }
                }
            }
        }
    }

    func testABlockThatAsksToBeSmallerStillGetsSmaller() {
        // The cap is a ceiling, never a floor: giving height back is always
        // allowed, and it is what pays for the other row's growth.
        let scales = twoRowScales(top: .small, bottom: .regular, canvas: roomierCanvas)
        XCTAssertLessThan(scales.top, scales.bottom)
    }

    func testAGrowingRowGetsAsMuchAsTheCanvasCanPayForAndNoMore() {
        let canvas = roomierCanvas
        let grown = twoRowScales(top: .large, bottom: .regular, canvas: canvas)
        XCTAssertGreaterThan(grown.top, 1, "there is surplus, so Large is larger")
        XCTAssertLessThanOrEqual(
            grown.top,
            MenuBarToken.SizeStep.large.multiplier + 1e-9,
            "and never larger than what was asked for"
        )
        let content = MenuBarStripGeometry.twoRowContentHeight(
            rowFontSizes: [grown.top, grown.bottom].map { canvas.baseFontSize * $0 },
            lineSpacing: canvas.lineSpacing,
            lineHeightRatio: canvas.lineHeightRatio
        )
        XCTAssertLessThanOrEqual(content, canvas.availableHeight + 1e-9)
    }

    func testEveryCappedTwoRowStripFitsAndStaysLegible() {
        // The property the uniform fit already had, restated over the caps:
        // whatever the editor can produce still fits the canvas, and fitting
        // never turns legible type into a smudge.
        for canvas in [MenuBarStripCanvas.nominalTwoRow, roomierCanvas] {
            for scale in [
                MenuBarComposition.fontScaleRange.lowerBound, 1.0, 1.3,
                MenuBarComposition.fontScaleRange.upperBound
            ] {
                for first in MenuBarToken.SizeStep.allCases {
                    for second in MenuBarToken.SizeStep.allCases {
                        let scales = twoRowScales(
                            top: first, bottom: second, compositionScale: scale, canvas: canvas
                        )
                        let sizes = [scales.top, scales.bottom].map { canvas.baseFontSize * $0 }
                        let content = MenuBarStripGeometry.twoRowContentHeight(
                            rowFontSizes: sizes,
                            lineSpacing: canvas.lineSpacing,
                            lineHeightRatio: canvas.lineHeightRatio
                        )
                        let label = "scale \(scale), \(first)/\(second), canvas \(canvas.availableHeight)"
                        XCTAssertLessThanOrEqual(content, canvas.availableHeight + 1e-9, "does not fit at \(label)")
                        let requested = [first, second]
                            .map { canvas.baseFontSize * scale * $0.multiplier }
                        for (drawn, asked) in zip(sizes, requested)
                        where asked >= MenuBarStripFit.legibleFontSize {
                            XCTAssertGreaterThanOrEqual(
                                drawn, MenuBarStripFit.legibleFontSize,
                                "fitting made it illegible at \(label)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testAOneRowStripIsNotFittedAtAll() {
        // One row has the whole bar, so Large there simply is large.
        let rendered = plan(
            [MenuBarToken(kind: .text("a"), style: .init(size: .large))],
            quotas: []
        )
        XCTAssertEqual(
            rendered.rows[0].tokens[0].fontScale,
            MenuBarToken.SizeStep.large.multiplier,
            accuracy: 1e-9
        )
    }

    /// A bar tall enough that two neutral rows fit with something to spare —
    /// `nominalTwoRow` is the short bar, where they already do not.
    private var roomierCanvas: MenuBarStripCanvas {
        var canvas = MenuBarStripCanvas.nominalTwoRow
        canvas.availableHeight = 24
        return canvas
    }
}
