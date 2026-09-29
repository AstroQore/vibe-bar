import Foundation

/// Which way a bulk change on one harness goes.
public enum SkillBulkDirection: String, Hashable, Sendable {
    case enable
    case disable
}

/// One harness switched on or off for many skills at once, worked out before
/// anything on disk changes.
///
/// The plan is the whole decision: which rows get which explicit action, and
/// how many were left alone and why. Keeping it here rather than in the
/// Skills page model means the skip rules are tested against real
/// `activationState` values, and the confirmation dialog can quote the exact
/// count the loop is going to act on.
///
/// The per-row action follows the single-click rules of the toggle row:
/// harnesses with a native switch are turned off in their own config (the
/// projection stays, so turning it back on is one write), harnesses without
/// one lose the projection, and a harness that discovers the shared root with
/// no switch at all (Cursor) cannot be turned off per skill — those rows are
/// reported as unreachable instead of being "changed" into the same state.
/// So is a row AntiGravity reads through the Gemini CLI folder as well as its
/// own: unlinking the direct copy leaves it discovered.
public struct SkillBulkPlan: Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public let id: SkillID
        public let name: String
        public let action: SkillActivationAction

        public init(id: SkillID, name: String, action: SkillActivationAction) {
            self.id = id
            self.name = name
            self.action = action
        }
    }

    /// What the plan decided for one row.
    public enum Resolution: Hashable, Sendable {
        case apply(SkillActivationAction)
        case alreadyInState
        /// The harness config could not be read, so Vibe Bar does not know
        /// what state the row is in. Writing over it blind is how a bulk
        /// action would clobber a setting the user made by hand.
        case unknown
        /// The harness has no switch that reaches the requested state.
        case unreachable
    }

    public let app: SkillAppTarget
    public let direction: SkillBulkDirection
    public let steps: [Step]
    public let alreadyInState: Int
    public let skippedUnknown: Int
    public let unreachable: Int
    /// Rows the user asked to change: every row not already in the target
    /// state, whether or not a step reaches it. What `refreshed` re-reads.
    public let requestedIDs: Set<SkillID>

    public init(app: SkillAppTarget, direction: SkillBulkDirection, skills: [Skill]) {
        var steps: [Step] = []
        var already = 0
        var unknown = 0
        var unreachable = 0
        var requested: Set<SkillID> = []
        for skill in skills {
            let resolution = Self.resolve(skill: skill, app: app, direction: direction)
            if resolution != .alreadyInState { requested.insert(skill.id) }
            switch resolution {
            case let .apply(action):
                steps.append(Step(id: skill.id, name: skill.name, action: action))
            case .alreadyInState: already += 1
            case .unknown: unknown += 1
            case .unreachable: unreachable += 1
            }
        }
        self.app = app
        self.direction = direction
        self.steps = steps
        self.alreadyInState = already
        self.skippedUnknown = unknown
        self.unreachable = unreachable
        self.requestedIDs = requested
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Rows that will not reach the requested state and that the user is told
    /// about as failures: nothing on disk changes for them, but the change
    /// they asked for did not happen either.
    public var skippedCount: Int { skippedUnknown + unreachable }

    /// Whether confirming this plan would change or report anything. False
    /// only when every row is already in the requested state.
    public var needsConfirmation: Bool { !steps.isEmpty || skippedCount > 0 }

    /// Every row the plan looked at, acted on or not.
    public var consideredCount: Int {
        steps.count + alreadyInState + skippedUnknown + unreachable
    }

    /// The same plan recomputed against the registry as it is now, limited to
    /// the rows this one was asked to change.
    ///
    /// A confirmation dialog can sit open across several filesystem reloads;
    /// a row switched by hand in the meantime must not be switched again from
    /// a stale reading, and a row uninstalled in the meantime simply drops.
    public func refreshed(against skills: [Skill]) -> SkillBulkPlan {
        SkillBulkPlan(
            app: app,
            direction: direction,
            skills: skills.filter { requestedIDs.contains($0.id) }
        )
    }

    /// The explicit action that moves one row toward `direction`, or why the
    /// row is skipped.
    ///
    /// Takes the whole skill rather than its effective state: a direct
    /// AntiGravity projection reads as `.enabled` even when the Gemini folder
    /// would keep it discovered, and only the skill's projections say so.
    public static func resolve(
        skill: Skill,
        app: SkillAppTarget,
        direction: SkillBulkDirection
    ) -> Resolution {
        let state = skill.activationState(for: app)
        if state == .unknown { return .unknown }
        switch direction {
        case .enable:
            switch state {
            // A coupled row is already visible to the harness through a root
            // it reads on its own; the header capsule counts it as seen, and
            // the bulk action agrees with that number.
            case .enabled, .coupled: return .alreadyInState
            case .notProjected, .disabledInHarness:
                // A shared-root harness with no native switch has nothing
                // `enable` could write — the service reports it as a no-op.
                if app.discoversSharedSkillRoot, !app.supportsNativeSkillActivation {
                    return .unreachable
                }
                return .apply(.enable)
            case .unknown: return .unknown
            }
        case .disable:
            switch state {
            case .notProjected, .disabledInHarness: return .alreadyInState
            case .enabled, .coupled:
                if app.supportsNativeSkillActivation { return .apply(.disableInHarness) }
                // Removing the projection only turns the skill off where the
                // harness has no other way to see it: a shared root, or the
                // Gemini folder AntiGravity also reads, keeps it discovered.
                if state == .coupled || skill.isDiscoveredWithoutProjection(for: app) {
                    return .unreachable
                }
                return .apply(.removeProjection)
            case .unknown: return .unknown
            }
        }
    }

    /// Applies the steps one at a time.
    ///
    /// Sequential on purpose: each step rewrites the registry and, for the
    /// native harnesses, one shared config file; running them concurrently
    /// would only interleave read-modify-write cycles on the same files. A
    /// failed row is counted and the loop moves on — one unreadable skill
    /// must not strand the rest of a hundred-row change halfway.
    ///
    /// `apply` returns whether the row actually changed. `false` is the
    /// service leaving something in place on purpose — a copy the user has
    /// edited since it was made — and counts as a failure: the harness still
    /// sees the skill, whatever the loop did.
    public func run(
        apply: (Step) async throws -> Bool,
        progress: (_ done: Int, _ total: Int) async -> Void = { _, _ in }
    ) async -> SkillBulkOutcome {
        var succeeded = 0
        var failed = 0
        var lastError: String?
        var cancelled = false
        let total = steps.count
        for (index, step) in steps.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            await progress(index, total)
            do {
                if try await apply(step) {
                    succeeded += 1
                } else {
                    failed += 1
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failed += 1
                lastError = error.localizedDescription
            }
        }
        if !cancelled { await progress(total, total) }
        return SkillBulkOutcome(
            succeeded: succeeded,
            failed: failed,
            skipped: skippedCount,
            lastError: lastError,
            wasCancelled: cancelled
        )
    }
}

/// What a finished bulk run did.
public struct SkillBulkOutcome: Hashable, Sendable {
    public let succeeded: Int
    /// Steps that threw or were left in place by the service.
    public let failed: Int
    /// Rows the plan could not act on: unknown state or no reachable switch.
    public let skipped: Int
    /// The last failure's message, for a log line; the toast reports counts.
    public let lastError: String?
    public let wasCancelled: Bool

    public init(
        succeeded: Int,
        failed: Int,
        skipped: Int = 0,
        lastError: String? = nil,
        wasCancelled: Bool = false
    ) {
        self.succeeded = succeeded
        self.failed = failed
        self.skipped = skipped
        self.lastError = lastError
        self.wasCancelled = wasCancelled
    }

    /// Every requested row that did not end in the requested state — what
    /// the summary reports as failed, since there is no separate "skipped"
    /// wording to tell the two apart.
    public var notChanged: Int { failed + skipped }
}
