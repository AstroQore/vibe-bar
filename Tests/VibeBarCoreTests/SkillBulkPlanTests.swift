import XCTest
@testable import VibeBarCore

final class SkillBulkPlanTests: XCTestCase {
    private func skill(
        _ directory: String,
        projected: [SkillAppTarget] = [],
        nativeDisabled: Set<SkillAppTarget> = [],
        unknown: Set<SkillAppTarget> = []
    ) -> Skill {
        Skill(
            id: .local(directory: directory),
            name: directory,
            directory: directory,
            installedAt: .distantPast,
            apps: Dictionary(uniqueKeysWithValues: projected.map { ($0, SkillMaterialization(method: .symlink)) }),
            nativeDisabledApps: nativeDisabled,
            nativeStateUnknownApps: unknown
        )
    }

    private struct Boom: Error {}

    // MARK: - Planning

    func testEnableSkipsRowsAlreadyOnAndRowsInAnUnknownState() {
        let skills = [
            skill("on", projected: [.claude]),
            skill("off"),
            skill("paused", projected: [.claude], nativeDisabled: [.claude]),
            skill("unreadable", projected: [.claude], unknown: [.claude]),
        ]

        let plan = SkillBulkPlan(app: .claude, direction: .enable, skills: skills)

        XCTAssertEqual(plan.steps.map(\.name), ["off", "paused"])
        XCTAssertEqual(plan.steps.map(\.action), [.enable, .enable])
        XCTAssertEqual(plan.alreadyInState, 1)
        XCTAssertEqual(plan.skippedUnknown, 1)
        XCTAssertEqual(plan.unreachable, 0)
        XCTAssertEqual(plan.consideredCount, 4)
    }

    func testDisableUsesTheNativeSwitchWhereTheHarnessHasOne() {
        let skills = [
            skill("on", projected: [.claude]),
            skill("off"),
            skill("paused", projected: [.claude], nativeDisabled: [.claude]),
        ]

        let plan = SkillBulkPlan(app: .claude, direction: .disable, skills: skills)

        XCTAssertEqual(plan.steps, [
            SkillBulkPlan.Step(id: .local(directory: "on"), name: "on", action: .disableInHarness),
        ])
        XCTAssertEqual(plan.alreadyInState, 2)
    }

    func testDisableRemovesTheProjectionWhereThereIsNoNativeSwitch() {
        // AntiGravity has no per-skill config; the projection is the switch.
        let plan = SkillBulkPlan(
            app: .antigravity,
            direction: .disable,
            skills: [skill("linked", projected: [.antigravity]), skill("absent")]
        )

        XCTAssertEqual(plan.steps.map(\.action), [.removeProjection])
        XCTAssertEqual(plan.alreadyInState, 1)
    }

    func testCoupledRowsCountAsVisibleAndCannotBeTurnedOffByUnlinking() {
        // Cursor reads the shared root and has no switch: every row is
        // already visible to it, and nothing Vibe Bar writes hides one.
        let skills = [skill("shared"), skill("linked", projected: [.cursor])]

        let enable = SkillBulkPlan(app: .cursor, direction: .enable, skills: skills)
        XCTAssertTrue(enable.isEmpty)
        XCTAssertEqual(enable.alreadyInState, 2)

        let disable = SkillBulkPlan(app: .cursor, direction: .disable, skills: skills)
        XCTAssertTrue(disable.isEmpty)
        XCTAssertEqual(disable.unreachable, 2)
    }

    func testAntiGravityReadingTheGeminiFolderTooCannotBeUnlinkedOff() {
        // The direct projection makes the state read `.enabled`, but the
        // Gemini copy keeps AntiGravity discovering the skill after it goes.
        let dual = skill("dual", projected: [.antigravity, .gemini])
        XCTAssertEqual(dual.activationState(for: .antigravity), .enabled)

        let plan = SkillBulkPlan(
            app: .antigravity,
            direction: .disable,
            skills: [dual, skill("direct", projected: [.antigravity])]
        )

        XCTAssertEqual(plan.steps.map(\.name), ["direct"])
        XCTAssertEqual(plan.unreachable, 1)
        XCTAssertEqual(
            SkillBulkPlan.resolve(skill: dual, app: .antigravity, direction: .disable),
            .unreachable
        )
    }

    func testUnknownStateIsSkippedInBothDirections() {
        let skills = [skill("unreadable", projected: [.codex], unknown: [.codex])]
        for direction in [SkillBulkDirection.enable, .disable] {
            let plan = SkillBulkPlan(app: .codex, direction: direction, skills: skills)
            XCTAssertTrue(plan.isEmpty)
            XCTAssertEqual(plan.skippedUnknown, 1)
        }
    }

    func testRefreshedDropsRowsChangedOrRemovedSinceThePlanWasQuoted() {
        let before = [skill("a"), skill("b"), skill("c")]
        let plan = SkillBulkPlan(app: .claude, direction: .enable, skills: before)
        XCTAssertEqual(plan.steps.count, 3)

        // "a" switched on by hand, "b" uninstalled, "d" newly shown — the
        // dialog only ever agreed to a, b, and c.
        let after = [skill("a", projected: [.claude]), skill("c"), skill("d")]
        let refreshed = plan.refreshed(against: after)

        XCTAssertEqual(refreshed.steps.map(\.name), ["c"])
        XCTAssertEqual(refreshed.alreadyInState, 1)
    }

    // MARK: - Running

    func testRunCountsSuccessesAndFailuresAndKeepsGoing() async {
        let plan = SkillBulkPlan(
            app: .claude,
            direction: .enable,
            skills: [skill("a"), skill("b"), skill("c")]
        )
        var applied: [String] = []
        var reported: [[Int]] = []

        let outcome = await plan.run(
            apply: { step in
                applied.append(step.name)
                if step.name == "b" { throw Boom() }
                return true
            },
            progress: { done, total in reported.append([done, total]) }
        )

        XCTAssertEqual(applied, ["a", "b", "c"])
        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertNotNil(outcome.lastError)
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(reported, [[0, 3], [1, 3], [2, 3], [3, 3]])
    }

    func testRunCountsARowTheServiceLeftInPlaceAsFailed() async {
        // `setActivation(.removeProjection)` answers `false` when it keeps a
        // user-edited copy: the harness still sees the skill.
        let plan = SkillBulkPlan(
            app: .antigravity,
            direction: .disable,
            skills: [skill("clean", projected: [.antigravity]), skill("edited", projected: [.antigravity])]
        )

        let outcome = await plan.run(apply: { step in step.name != "edited" })

        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(outcome.notChanged, 1)
    }

    func testSkippedRowsAreReportedAsNotChangedAndStillAskForConfirmation() async {
        let skills = [
            skill("off"),
            skill("unreadable", projected: [.claude], unknown: [.claude]),
            skill("on", projected: [.claude]),
        ]
        let plan = SkillBulkPlan(app: .claude, direction: .enable, skills: skills)
        XCTAssertTrue(plan.needsConfirmation)
        XCTAssertEqual(plan.skippedCount, 1)

        let outcome = await plan.run(apply: { _ in true })
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.notChanged, 1)

        // Nothing reachable at all is still a plan to confirm and report —
        // zero changed, every requested row not changed.
        let cursor = SkillBulkPlan(
            app: .cursor,
            direction: .disable,
            skills: [skill("shared"), skill("linked", projected: [.cursor])]
        )
        XCTAssertTrue(cursor.isEmpty)
        XCTAssertTrue(cursor.needsConfirmation)
        var calls = 0
        let empty = await cursor.run(apply: { _ in calls += 1; return true })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(empty.succeeded, 0)
        XCTAssertEqual(empty.notChanged, 2)

        // Every row already where the user asked: nothing to confirm.
        let settled = SkillBulkPlan(app: .claude, direction: .enable, skills: [skill("on", projected: [.claude])])
        XCTAssertFalse(settled.needsConfirmation)
    }

    func testRefreshedKeepsRowsThatWereSkippedWhenQuoted() {
        let plan = SkillBulkPlan(
            app: .claude,
            direction: .enable,
            skills: [skill("unreadable", projected: [.claude], unknown: [.claude])]
        )
        XCTAssertEqual(plan.requestedIDs, [.local(directory: "unreadable")])

        // The config became readable while the dialog was open.
        let refreshed = plan.refreshed(against: [skill("unreadable", projected: [.claude], nativeDisabled: [.claude])])
        XCTAssertEqual(refreshed.steps.map(\.action), [.enable])
        XCTAssertEqual(refreshed.skippedCount, 0)
    }

    func testRunStopsOnCancellation() async {
        let plan = SkillBulkPlan(
            app: .claude,
            direction: .enable,
            skills: [skill("a"), skill("b")]
        )
        var applied = 0

        let outcome = await plan.run(apply: { _ in
            applied += 1
            throw CancellationError()
        })

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertTrue(outcome.wasCancelled)
    }

    func testRunAgainstTheServiceProjectsOnlyTheRowsThatNeededIt() async throws {
        let home = try SkillTestHome()
        let service = SkillsService(homeDirectory: home.path)
        for name in ["alpha", "beta", "gamma"] {
            let staging = try home.makeSkillDirectory(at: home.url.appendingPathComponent("Downloads/\(name)"))
            _ = try await service.installLocal(from: staging, name: name)
        }
        try await service.setActivation(.local(directory: "alpha"), app: .antigravity, action: .enable)

        let plan = SkillBulkPlan(
            app: .antigravity,
            direction: .enable,
            skills: await service.installedSkills()
        )
        XCTAssertEqual(plan.steps.map(\.name).sorted(), ["beta", "gamma"])
        XCTAssertEqual(plan.alreadyInState, 1)

        let outcome = await plan.run(apply: { step in
            try await service.setActivation(step.id, app: .antigravity, action: step.action)
        })
        XCTAssertEqual(outcome.notChanged, 0)

        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(outcome.failed, 0)
        let after = await service.installedSkills()
        XCTAssertTrue(after.allSatisfy { $0.activationState(for: .antigravity) == .enabled })
        for name in ["alpha", "beta", "gamma"] {
            XCTAssertTrue(home.exists(home.appDirectory(.antigravity).appendingPathComponent(name)))
        }
    }
}
