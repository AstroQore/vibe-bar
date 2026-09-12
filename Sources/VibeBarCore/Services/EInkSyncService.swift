import Combine
import CryptoKit
import Foundation

/// What one push pass did, for the "Push now" button's result line.
public struct EInkPushOutcome: Equatable, Sendable {
    public var pushed: Int
    public var skipped: Int
    public var failure: EInkSyncFailure?
    public var errorDetail: String?

    public init(pushed: Int = 0, skipped: Int = 0, failure: EInkSyncFailure? = nil, errorDetail: String? = nil) {
        self.pushed = pushed
        self.skipped = skipped
        self.failure = failure
        self.errorDetail = errorDetail
    }

    public var succeeded: Bool { failure == nil }
}

/// Which slide goes to which Canvas API task, and whether the device should
/// redraw immediately.
///
/// Pure and separate from the service so the mapping — the part that is easy
/// to get subtly wrong and impossible to eyeball on a panel across the room —
/// is testable without a client, a clock, or a device.
public struct EInkPushPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// What the item puts on its task.
        public enum Content: Equatable, Sendable {
            case slide(String)
            /// A Canvas API task the device's loop carries that no slide
            /// claims. It gets a placeholder rather than being left alone —
            /// see `EInkPresets.unusedSlot`.
            case unusedSlot
        }

        public var content: Content
        public var slideID: String
        /// `nil` means "the device has exactly one Canvas API task": the API
        /// treats an omitted key that way, and a device the user never added
        /// extra tasks to is the common case.
        public var taskKey: String?
        public var refreshNow: Bool

        public init(slideID: String, taskKey: String?, refreshNow: Bool) {
            self.content = .slide(slideID)
            self.slideID = slideID
            self.taskKey = taskKey
            self.refreshNow = refreshNow
        }

        public init(content: Content, taskKey: String?, refreshNow: Bool) {
            self.content = content
            self.slideID = { if case let .slide(id) = content { return id }; return "" }()
            self.taskKey = taskKey
            self.refreshNow = refreshNow
        }

        public var isUnusedSlot: Bool { content == .unusedSlot }

        /// The key a digest is filed under. The default task has no key, so it
        /// gets the empty string rather than a second dictionary.
        public var digestKey: String { taskKey ?? "" }
    }

    public var items: [Item]
    public var failure: EInkSyncFailure?
    /// Canvas API tasks in the loop that no slide claims. Reported so the
    /// settings pane can say how many, because only the Dot. app can remove
    /// them.
    public var surplusTaskCount: Int

    public init(items: [Item] = [], failure: EInkSyncFailure? = nil, surplusTaskCount: Int = 0) {
        self.items = items
        self.failure = failure
        self.surplusTaskCount = surplusTaskCount
    }

    /// `slideIndex` is only read by the app-timer carousel; the other two
    /// playback modes ignore it.
    public static func make(for device: EInkDeviceConfig, slideIndex: Int) -> EInkPushPlan {
        let slides = device.slides
        guard !slides.isEmpty else { return EInkPushPlan(failure: .noSlides) }
        let keys = device.taskKeys

        switch device.playback {
        case .single:
            // One slide, one task — and every other task in the loop is a
            // slot still showing whatever it was last sent. A device moved
            // from a carousel to a single slide would otherwise keep the rest
            // of the carousel on screen, which is the opposite of what the
            // switch says it does.
            let slide = device.resolvedSingleSlide ?? slides[0]
            let surplus = keys.dropFirst()
            return EInkPushPlan(
                items: [Item(slideID: slide.id, taskKey: keys.first, refreshNow: true)]
                    + surplus.map { Item(content: .unusedSlot, taskKey: $0, refreshNow: false) },
                surplusTaskCount: surplus.count
            )

        case let .carousel(driver, _):
            switch driver {
            case .deviceLoop:
                // One slide per pre-existing task, in order. The device does
                // the rotating, so nothing asks for an immediate redraw: a
                // `refreshNow` here would make the panel flash N times per
                // data refresh instead of following its own loop.
                guard !keys.isEmpty else {
                    return EInkPushPlan(
                        items: [Item(slideID: slides[0].id, taskKey: nil, refreshNow: false)],
                        failure: slides.count > 1 ? .noTaskKeys : nil
                    )
                }
                var items = zip(slides, keys).map {
                    Item(slideID: $0.0.id, taskKey: $0.1, refreshNow: false)
                }
                // A loop with more tasks than slides — the user deleted a
                // slide, or added one task too many on the phone — leaves the
                // surplus slot showing whatever was pushed to it last. The API
                // cannot delete a task, so the slot is claimed and told what
                // it is instead of being left to lie.
                let surplus = keys.dropFirst(slides.count)
                items.append(contentsOf: surplus.map {
                    Item(content: .unusedSlot, taskKey: $0, refreshNow: false)
                })
                return EInkPushPlan(
                    items: items,
                    failure: keys.count < slides.count ? .noTaskKeys : nil,
                    surplusTaskCount: surplus.count
                )

            case .appTimer:
                // One task, re-pushed on the Mac's clock. Every switch is a
                // full e-ink refresh, which is exactly the trade this driver
                // exists to make.
                let index = slides.isEmpty ? 0 : ((slideIndex % slides.count) + slides.count) % slides.count
                // Same as `single`: this driver uses one task, so any others
                // in the loop are slots nobody is writing to any more.
                let surplus = keys.dropFirst()
                return EInkPushPlan(
                    items: [Item(slideID: slides[index].id, taskKey: keys.first, refreshNow: true)]
                        + surplus.map { Item(content: .unusedSlot, taskKey: $0, refreshNow: false) },
                    surplusTaskCount: surplus.count
                )
            }
        }
    }
}

/// Pushes rendered slides to every enabled E-ink device on its own cadence.
///
/// Modelled on `RemoteProbeService`: one loop per device, a `RefreshRun` so
/// overlapping triggers join the pass already in flight instead of queueing a
/// second one, and a `configurationGeneration` that invalidates work started
/// under settings the user has since changed.
///
/// Three things are specific to a panel rather than a dashboard:
///
/// - **A push that would change nothing is skipped.** Every payload's
///   `windowData` is digested and compared with what that task last received.
///   An e-ink refresh is visible, slow, and (on battery) expensive; redrawing
///   the same pixels is pure cost.
/// - **Battery devices get their own cadence.** When the last status read said
///   the device is on battery, the loop sleeps `batteryRefreshMinutes`
///   (default an hour) instead of `dataRefreshMinutes` (default 15).
/// - **Requests are spaced.** The service allows 10 per second; pushes are
///   spaced by `DotDeviceClient.minimumRequestInterval` so a six-slide
///   carousel cannot trip the limiter.
@MainActor
public final class EInkSyncService: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var states: [String: EInkDeviceSyncState] = [:]
    /// Devices with a push pass in flight, for the button's spinner.
    @Published public private(set) var busyDeviceIDs: Set<String> = []
    /// True once the API answered 401/403: every loop is stopped and the
    /// settings pane says the key has to be replaced.
    @Published public private(set) var credentialInvalid = false
    @Published public private(set) var isRunning = false

    public func state(for deviceID: String) -> EInkDeviceSyncState {
        states[deviceID] ?? EInkDeviceSyncState(deviceID: deviceID)
    }

    public func isBusy(_ deviceID: String) -> Bool { busyDeviceIDs.contains(deviceID) }

    // MARK: - Dependencies

    private let client: any DotDeviceClienting
    private let store: EInkSyncStateStore
    private let apiKeyProvider: @Sendable () -> String?
    /// Assembles what one pass needs: the passed field ids on top of the
    /// default priority order, and the usage half only when a slide draws it.
    private let snapshotProvider: @Sendable (EInkSnapshotRequest) async throws -> EInkAssemblyOutcome
    private let clock: @Sendable () -> Date
    /// Spacing between two canvas writes in the same pass. A stored property
    /// only so tests can collapse it; not part of the public API.
    private var requestSpacing: Duration
    /// 1 s then 2 s, matching `RemoteProbeService`: enough to ride out a
    /// limiter window without making a broken run take a minute to fail.
    private var retryDelays: [Duration]
    /// How long an assembled snapshot may be reused across devices in the same
    /// wave. Assembly walks the ledger; doing it once per device would be the
    /// same query three times in a row.
    private var snapshotReuseWindow: Duration

    // MARK: - Configuration

    private var settings: EInkSyncSettings = .default
    private var layouts: [String: EInkCanvasLayout] = [:]
    private var configurationGeneration = 0

    // MARK: - Loops

    private final class RefreshRun {
        let generation: Int
        let task: Task<EInkPushOutcome, Never>

        init(generation: Int, task: Task<EInkPushOutcome, Never>) {
            self.generation = generation
            self.task = task
        }
    }

    private var refreshLoops: [String: Task<Void, Never>] = [:]
    private var carouselLoops: [String: Task<Void, Never>] = [:]
    private var activeRuns: [String: RefreshRun] = [:]
    private var cachedSnapshot: (
        outcome: EInkAssemblyOutcome,
        takenAt: Date,
        generation: Int,
        fieldIDs: [String],
        includesUsage: Bool
    )?
    private var cachedAPIKey: String?
    private var apiKeyLoaded = false
    private var credentialGeneration = 0
    /// The last slot handed out by the rate gate, for *any* device.
    ///
    /// A `ContinuousClock` instant, not a `Date`: a rate limit is a duration
    /// between two events, and the wall clock is not one — an NTP step
    /// between the claim and the send makes the gap the service sees bear no
    /// relation to the one the gate computed. (CI caught this as two writes
    /// 9 ms apart through a gate set to 150.)
    private var lastRequestSlot: ContinuousClock.Instant?
    private let writer: EInkSyncStateWriter
    private var persistTask: Task<Void, Never>?
    /// Devices whose restarted loop must sleep before its first pass, because
    /// a forced push is about to cover it.
    private var deferredFirstPass: Set<String> = []

    // MARK: - Init

    public init(
        client: any DotDeviceClienting = DotDeviceClient(),
        store: EInkSyncStateStore = EInkSyncStateStore(),
        apiKeyProvider: @escaping @Sendable () -> String? = { try? EInkCredentialStore.readAPIKey() },
        snapshotProvider: @escaping @Sendable (EInkSnapshotRequest) async throws -> EInkAssemblyOutcome,
        clock: @escaping @Sendable () -> Date = Date.init,
        requestSpacing: Duration = .milliseconds(150),
        retryDelays: [Duration] = [.seconds(1), .seconds(2)],
        snapshotReuseWindow: Duration = .seconds(5)
    ) {
        self.client = client
        self.store = store
        self.apiKeyProvider = apiKeyProvider
        self.snapshotProvider = snapshotProvider
        self.clock = clock
        self.requestSpacing = requestSpacing
        self.retryDelays = retryDelays
        self.snapshotReuseWindow = snapshotReuseWindow
        self.writer = EInkSyncStateWriter(store: store)
        self.states = store.load().devices
    }

    // MARK: - Lifecycle

    /// Re-reads the roster after the settings pane changed it.
    ///
    /// Every in-flight push is fenced by the generation this bumps, so a pass
    /// that captured the old orientation cannot land after the user rotated
    /// the panel. Loops are restarted rather than reconciled: there are at
    /// most a handful of devices, and a diff would be more code than it saves.
    public func apply(settings: EInkSyncSettings, layouts: [String: EInkCanvasLayout]) {
        let changed = settings != self.settings || layouts != self.layouts
        self.settings = settings.sanitized
        self.layouts = layouts
        guard changed else { return }
        configurationGeneration += 1
        // A settings edit must *not* clear a rejected key. `apiKeyPresent`
        // stays true through a 401, so treating any edit as good news would
        // restart the loops with the same rejected credential and earn another
        // round of 401s; only `credentialDidChange()` lifts the stop.
        cachedSnapshot = nil
        restartLoops()
    }

    /// The stored key was replaced (or removed). Clears the rejected-key flag
    /// and restarts the loops that the 401 stopped.
    ///
    /// It needs its own call because the settings mirror cannot carry the
    /// news: replacing a rejected key leaves `apiKeyPresent` exactly where it
    /// was, so the `removeDuplicates()` that watches `EInkSyncSettings` sees
    /// no change and syncing would stay stopped until some unrelated E-ink
    /// setting moved.
    public func credentialDidChange() {
        configurationGeneration += 1
        credentialGeneration += 1
        cachedAPIKey = nil
        apiKeyLoaded = false
        credentialInvalid = false
        restartLoops()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        restartLoops()
    }

    public func stop() {
        isRunning = false
        cancelLoops()
    }

    /// Called after the Mac wakes: the loops were asleep with it, so the data
    /// on the panel is as old as the sleep was long.
    public func wakeFromSleep() {
        guard canSync else { return }
        for device in activeDevices {
            Task { [weak self] in _ = await self?.refresh(deviceID: device.deviceID) }
        }
    }

    private var canSync: Bool {
        isRunning && settings.syncEnabled && settings.apiKeyPresent && !credentialInvalid
    }

    /// The key, read off the main actor once and then held in memory.
    ///
    /// The whole service is `@MainActor`, and the Vault read behind
    /// `apiKeyProvider` can touch the Keychain — including a one-time legacy
    /// migration that writes and deletes. Doing that synchronously from a
    /// settings interaction (an orientation tap restarts the loops) is exactly
    /// the main-thread stall AGENTS.md § 7 calls a blocker, so the lookup is
    /// detached and the answer is cached until `credentialDidChange()`.
    private func currentAPIKey() async -> String? {
        if apiKeyLoaded { return cachedAPIKey }
        let generation = credentialGeneration
        let provider = apiKeyProvider
        let value = await Task.detached(priority: .utility) { provider() }.value
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty == false) ? trimmed : nil
        // The key may have been replaced while this read was out. Caching the
        // superseded one would keep syncing with a credential the user has
        // already thrown away, and the 401 that follows would stop the loops
        // with a perfectly good key sitting in the Keychain.
        guard generation == credentialGeneration else { return resolved }
        cachedAPIKey = resolved
        apiKeyLoaded = true
        return resolved
    }

    private var activeDevices: [EInkDeviceConfig] {
        settings.devices.filter { $0.enabled && !$0.deviceID.isEmpty }
    }

    private func cancelLoops() {
        for loop in refreshLoops.values { loop.cancel() }
        for loop in carouselLoops.values { loop.cancel() }
        refreshLoops.removeAll()
        carouselLoops.removeAll()
    }

    private func restartLoops() {
        cancelLoops()
        guard canSync else { return }
        for device in activeDevices {
            let id = device.deviceID
            let deferFirst = deferredFirstPass.contains(id)
            refreshLoops[id] = Task { [weak self] in
                var skipFirst = deferFirst
                while !Task.isCancelled {
                    guard let self else { return }
                    if skipFirst {
                        skipFirst = false
                    } else {
                        _ = await self.refresh(deviceID: id)
                    }
                    let interval = await self.refreshInterval(for: id)
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        return
                    }
                }
            }
            guard case let .carousel(driver, seconds) = device.playback, driver == .appTimer else { continue }
            carouselLoops[id] = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    guard let self else { return }
                    await self.advanceCarousel(deviceID: id)
                }
            }
        }
    }

    /// Seconds between two data refreshes for this device, which is where the
    /// battery rule lives: a panel on USB power can afford a quarter-hour
    /// cadence, one on its own cell cannot.
    public func refreshInterval(for deviceID: String) -> TimeInterval {
        guard let device = settings.device(id: deviceID) else {
            return TimeInterval(EInkDeviceConfig.defaultDataRefreshMinutes * 60)
        }
        let minutes = state(for: deviceID).onBattery ? device.batteryRefreshMinutes : device.dataRefreshMinutes
        return TimeInterval(max(EInkDeviceConfig.minimumDataRefreshMinutes, minutes) * 60)
    }

    // MARK: - Triggers

    /// Runs one pass, or joins the pass already in flight for this device.
    ///
    /// Joining is only right when the pass in flight is running under the
    /// configuration the caller wants. A run started before the user rotated
    /// the panel is fenced from committing anything, so treating it as this
    /// caller's pass would leave the loop sleeping a whole interval — up to a
    /// day — on the old picture. A stale run is waited out and then replaced.
    @discardableResult
    public func refresh(deviceID: String) async -> EInkPushOutcome {
        while let existing = activeRuns[deviceID] {
            let outcome = await existing.task.value
            if existing.generation == configurationGeneration { return outcome }
            if activeRuns[deviceID] === existing {
                activeRuns.removeValue(forKey: deviceID)
                busyDeviceIDs.remove(deviceID)
                break
            }
        }
        return await startRun(deviceID: deviceID, force: false)
    }

    /// Applies the configuration the caller is looking at and then forces a
    /// push, without letting the restart fire an automatic pass first.
    ///
    /// `apply` restarts the loops, and a restarted loop's first act is a
    /// normal refresh. Racing that against the forced pass produced two
    /// identical canvas writes — and two visible e-ink refreshes — for one
    /// button press.
    @discardableResult
    public func pushNow(
        deviceID: String,
        applying settings: EInkSyncSettings,
        layouts: [String: EInkCanvasLayout]
    ) async -> EInkPushOutcome {
        deferredFirstPass.insert(deviceID)
        apply(settings: settings, layouts: layouts)
        defer { deferredFirstPass.remove(deviceID) }
        return await pushNow(deviceID: deviceID)
    }

    /// The settings pane's "Push now": the same pass, except the digest check
    /// is skipped. Someone who presses a button expects the panel to redraw
    /// even when the numbers happen to be identical.
    @discardableResult
    public func pushNow(deviceID: String) async -> EInkPushOutcome {
        if let existing = activeRuns[deviceID] {
            _ = await existing.task.value
        }
        return await startRun(deviceID: deviceID, force: true)
    }

    private func startRun(deviceID: String, force: Bool) async -> EInkPushOutcome {
        let generation = configurationGeneration
        let run = RefreshRun(generation: generation, task: Task { [weak self] in
            guard let self else { return EInkPushOutcome() }
            return await self.performRun(deviceID: deviceID, generation: generation, force: force)
        })
        activeRuns[deviceID] = run
        busyDeviceIDs.insert(deviceID)
        let outcome = await run.task.value
        if activeRuns[deviceID] === run {
            activeRuns.removeValue(forKey: deviceID)
            busyDeviceIDs.remove(deviceID)
        }
        return outcome
    }

    /// Moves the app-timer carousel on by one slide and pushes it.
    public func advanceCarousel(deviceID: String) async {
        // Wait out the pass in flight before touching the index. That pass
        // captured the old one and writes its whole state back at the end, so
        // incrementing underneath it would be undone and the panel would show
        // the same slide twice.
        if let existing = activeRuns[deviceID] { _ = await existing.task.value }
        guard let device = settings.device(id: deviceID), !device.slides.isEmpty else { return }
        var state = self.state(for: deviceID)
        state.slideIndex = (state.slideIndex + 1) % device.slides.count
        states[deviceID] = state
        _ = await pushNow(deviceID: deviceID)
    }

    // MARK: - One pass

    private func performRun(deviceID: String, generation: Int, force: Bool) async -> EInkPushOutcome {
        // `force` is the Push now button, and it works on a device whose
        // per-device switch is still off. A freshly fetched panel starts
        // disabled, so requiring the switch here made the button report
        // "pushed 0, skipped 0" without ever contacting the panel — the worst
        // kind of answer, because it looks like a successful no-op.
        guard let device = settings.device(id: deviceID), device.enabled || force else {
            return EInkPushOutcome()
        }
        guard !credentialInvalid, let key = await currentAPIKey() else {
            return record(deviceID: deviceID, failure: .unauthorized, detail: nil, generation: generation)
        }
        guard generation == configurationGeneration else { return EInkPushOutcome() }

        var state = self.state(for: deviceID)
        state.lastAttemptAt = clock()
        let plan = EInkPushPlan.make(for: device, slideIndex: state.slideIndex)
        guard !plan.items.isEmpty else {
            return record(deviceID: deviceID, failure: plan.failure ?? .noSlides, detail: nil, generation: generation)
        }

        // Only walk the ledger when a slide on this pass actually draws usage.
        let needsUsage = plan.items.contains { item in
            guard case let .slide(slideID) = item.content else { return false }
            return device.slide(id: slideID)?.kind.preset?.needsUsageData ?? false
        }
        let assembly: EInkAssemblyOutcome
        do {
            assembly = try await assembleSnapshot(includesUsage: needsUsage)
        } catch {
            return record(
                deviceID: deviceID,
                failure: .network,
                detail: SafeLog.sanitize(String(describing: error)),
                generation: generation
            )
        }
        guard generation == configurationGeneration else { return EInkPushOutcome() }

        var pushed = 0
        var skipped = 0
        var failure = plan.failure
        var detail: String?

        let snapshot = assembly.snapshot
        if assembly.usageUnavailable { failure = .usageUnavailable }

        for item in plan.items {
            guard generation == configurationGeneration, !Task.isCancelled else { break }

            let payload: DotCanvasPayload
            do {
                switch item.content {
                case .unusedSlot:
                    payload = try EInkRenderer.renderUnusedSlot(
                        device: device,
                        taskKey: item.taskKey,
                        generatedAtISO: snapshot.generatedAtISO,
                        refreshNow: item.refreshNow
                    )
                case let .slide(slideID):
                    guard let slide = device.slide(id: slideID) else { continue }
                    // A usage slide drawn from an empty set would print "$0
                    // today" and be believed. Skip it and say why instead.
                    if assembly.usageUnavailable, slide.kind.preset?.needsUsageData ?? false { continue }
                    payload = try EInkRenderer.render(
                        slide: slide,
                        device: device,
                        snapshot: snapshot,
                        refreshNow: item.refreshNow,
                        taskKey: item.taskKey,
                        taskAlias: EInkRenderer.defaultTaskAlias(slide: slide, orientation: device.orientation),
                        layouts: layouts
                    )
                }
            } catch {
                failure = .render
                detail = String(describing: error)
                continue
            }

            let digest = Self.digest(of: payload)
            if !force, state.pushedDigests[item.digestKey] == digest {
                skipped += 1
                continue
            }

            guard generation == configurationGeneration else { break }

            do {
                try await withRetry(generation: generation) {
                    try await self.client.sendCanvas(deviceID: deviceID, payload: payload, apiKey: key)
                }
                state.pushedDigests[item.digestKey] = digest
                state.lastPushAt = clock()
                pushed += 1
            } catch let error as DotDeviceError {
                if error.invalidatesCredential {
                    state.pushedDigests.removeAll()
                    invalidateCredential()
                    return record(deviceID: deviceID, failure: .unauthorized, detail: nil, generation: generation)
                }
                failure = Self.failure(for: error)
                detail = error.description
            } catch {
                failure = .network
                detail = SafeLog.sanitize(String(describing: error))
            }
        }

        // One status read per pass, after the writes: it is what gives the UI
        // the power state (and therefore the next cadence), the Wi-Fi line,
        // and the render the device is actually showing.
        let statusRead = await readStatus(deviceID: deviceID, key: key, generation: generation)
        if let status = statusRead.status {
            state.apply(status)
            state.lastStatusAt = clock()
        } else if let statusFailure = statusRead.failure, failure == nil {
            failure = statusFailure
            detail = statusRead.detail
        }
        state.lastFailure = failure
        state.lastError = detail
        state.surplusTaskCount = plan.surplusTaskCount
        state.nextRefreshAt = clock().addingTimeInterval(
            TimeInterval(
                max(
                    EInkDeviceConfig.minimumDataRefreshMinutes,
                    state.onBattery ? device.batteryRefreshMinutes : device.dataRefreshMinutes
                ) * 60
            )
        )

        guard generation == configurationGeneration else { return EInkPushOutcome() }
        // The index belongs to the carousel timer, not to this pass: it may
        // have moved while this one was in flight.
        state.slideIndex = self.state(for: deviceID).slideIndex
        states[deviceID] = state
        persist()
        return EInkPushOutcome(pushed: pushed, skipped: skipped, failure: failure, errorDetail: detail)
    }

    /// A status read reports its own failure.
    ///
    /// Swallowing it meant a pass whose pushes were all skipped as unchanged
    /// returned a clean outcome while the account no longer had the device at
    /// all — so a panel someone unpaired months ago stayed in the list with
    /// nothing ever wrong with it.
    private func readStatus(
        deviceID: String,
        key: String,
        generation: Int
    ) async -> (status: DotDeviceStatus?, failure: EInkSyncFailure?, detail: String?) {
        await paceRequest()
        do {
            let status = try await client.status(deviceID: deviceID, apiKey: key)
            guard generation == configurationGeneration else { return (nil, nil, nil) }
            return (status, nil, nil)
        } catch let error as DotDeviceError {
            if error.invalidatesCredential { invalidateCredential() }
            return (nil, Self.failure(for: error), error.description)
        } catch {
            return (nil, .network, SafeLog.sanitize(String(describing: error)))
        }
    }

    /// Holds every outbound request to one per `requestSpacing`, across all
    /// devices rather than within one pass.
    ///
    /// Per-pass spacing was not enough: two enabled panels refresh together at
    /// launch, after wake, and after any settings change, and each pass
    /// counting its own gap put two writes on the wire every 150 ms — over the
    /// documented ten per second once the status reads are added.
    private func paceRequest() async {
        let now = ContinuousClock.now
        let earliest = lastRequestSlot.map { $0.advanced(by: requestSpacing) } ?? now
        let scheduled = earliest > now ? earliest : now
        // Claim the slot *before* suspending. Reading the stamp, sleeping, and
        // only then writing it lets two device passes wake into the same
        // instant and fire together; the claim and the read are one
        // uninterrupted step on the main actor, so every caller queues behind
        // the last slot handed out rather than behind the last send.
        lastRequestSlot = scheduled
        if scheduled > now {
            try? await Task.sleep(until: scheduled, clock: ContinuousClock())
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Assembles a snapshot, reusing the last one only when it answers the
    /// same question.
    ///
    /// The cache is keyed by the configuration generation *and* the field ids
    /// it was assembled for, and a result whose generation went stale while it
    /// was in flight is dropped rather than stored. Without both, an assembly
    /// that started before the user picked a new bucket could land in the
    /// cache afterwards and the very next pass — the one that exists to carry
    /// that bucket — would draw the panel without it, then sleep the interval.
    private func assembleSnapshot(
        fieldIDs: [String]? = nil,
        includesUsage: Bool
    ) async throws -> EInkAssemblyOutcome {
        let requested = fieldIDs ?? settings.selectedQuotaFieldIDs
        let generation = configurationGeneration
        if let cached = cachedSnapshot,
           cached.generation == generation,
           cached.fieldIDs == requested,
           // A quota-only answer cannot serve a pass that needs usage; the
           // other way round is fine, since the usage columns simply go unread.
           cached.includesUsage || !includesUsage
        {
            let age = clock().timeIntervalSince(cached.takenAt)
            if age >= 0, age < Self.seconds(snapshotReuseWindow) { return cached.outcome }
        }
        let outcome = try await snapshotProvider(
            EInkSnapshotRequest(quotaFieldIDs: requested, includesUsage: includesUsage)
        )
        if generation == configurationGeneration {
            cachedSnapshot = (outcome, clock(), generation, requested, includesUsage)
        }
        return outcome
    }

    /// Retries the transient failures and only those: a rate limit or a 5xx
    /// will very likely succeed a second later, a rejected key or a task that
    /// is not in the loop never will, and retrying them only delays the
    /// message the user needs.
    /// Every *attempt* claims its own slot, retries included. A wave of
    /// transient failures across several panels retries together, and a retry
    /// that skipped the gate would put the account straight back over the
    /// limit it just tripped.
    private func withRetry(generation: Int, _ request: () async throws -> Void) async throws {
        for delay in retryDelays {
            await paceRequest()
            // The gate is a suspension, and a settings edit can land in it.
            // Sending the payload rendered under the old configuration would
            // cost a visible e-ink refresh that the replacement run then has
            // to undo.
            guard generation == configurationGeneration else { return }
            do {
                try await request()
                return
            } catch let error as DotDeviceError {
                guard Self.isTransient(error) else { throw error }
                try? await Task.sleep(for: delay)
                guard generation == configurationGeneration else { return }
            }
        }
        await paceRequest()
        guard generation == configurationGeneration else { return }
        try await request()
    }

    public static func isTransient(_ error: DotDeviceError) -> Bool {
        switch error {
        case .rateLimited, .network: true
        case let .http(code): code >= 500
        default: false
        }
    }

    public static func failure(for error: DotDeviceError) -> EInkSyncFailure {
        switch error {
        case .unauthorized: .unauthorized
        case .taskNotInLoop: .taskMissing
        case .deviceNotFound: .deviceMissing
        case .rateLimited: .rateLimited
        default: .network
        }
    }

    /// A call that succeeded proves the key works, so it lifts the stop — and
    /// lifting it has to restart what `invalidateCredential` cancelled.
    /// Clearing the flag alone left syncing silently off until some unrelated
    /// edit happened to move the roster.
    private func clearCredentialRejection() {
        guard credentialInvalid else { return }
        credentialInvalid = false
        restartLoops()
    }

    private func invalidateCredential() {
        credentialInvalid = true
        cancelLoops()
    }

    @discardableResult
    private func record(
        deviceID: String,
        failure: EInkSyncFailure,
        detail: String?,
        generation: Int
    ) -> EInkPushOutcome {
        guard generation == configurationGeneration else { return EInkPushOutcome(failure: failure) }
        var state = self.state(for: deviceID)
        state.lastFailure = failure
        state.lastError = detail
        state.lastAttemptAt = clock()
        states[deviceID] = state
        persist()
        return EInkPushOutcome(failure: failure, errorDetail: detail)
    }

    /// Hands the current state to the background writer and returns.
    ///
    /// Chained rather than fired-and-forgotten so two writes cannot land out
    /// of order: the state is a last-writer-wins snapshot, and an older one
    /// overtaking a newer would resurrect a digest the engine has moved past.
    private func persist() {
        let snapshot = EInkSyncState(devices: states)
        let writer = self.writer
        let previous = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previous?.value
            await writer.write(snapshot)
        }
    }

    /// Waits for every queued state write. Tests only; nothing in the app
    /// needs to know when the file caught up.
    public func flushPendingWrites() async {
        await persistTask?.value
    }

    // MARK: - Preview

    /// The snapshot the settings preview draws, kept on the service so the
    /// pane never assembles one of its own — two assemblers would walk the
    /// ledger twice for the same numbers.
    @Published public private(set) var previewSnapshot: EInkDataSnapshot?

    /// `includingFieldIDs` exists because the settings pane is ahead of the
    /// engine: the roster reaches `apply` through a 400 ms debounce, so a
    /// bucket ticked a moment ago is not in `settings` yet and the preview
    /// would draw the row the user just asked for as missing.
    public func refreshPreviewSnapshot(includingFieldIDs: [String] = []) async {
        var fieldIDs = settings.selectedQuotaFieldIDs
        var seen = Set(fieldIDs)
        for fieldID in includingFieldIDs where seen.insert(fieldID).inserted {
            fieldIDs.append(fieldID)
        }
        // Ticking two buckets quickly starts two assemblies; the first can
        // finish last, and publishing it would drop the row the second one was
        // asked for until the user edited something else.
        previewRequest += 1
        let request = previewRequest
        guard let outcome = try? await assembleSnapshot(fieldIDs: fieldIDs, includesUsage: true) else { return }
        guard request == previewRequest else { return }
        previewSnapshot = outcome.snapshot
    }

    private var previewRequest = 0

    // MARK: - One-shot API calls for the settings pane

    /// Lists the account's devices and merges them into the stored roster,
    /// keeping every existing device's configuration intact.
    public func fetchDevices() async throws -> [DotDevice] {
        guard let key = await currentAPIKey() else { throw DotDeviceError.unauthorized }
        await paceRequest()
        do {
            let devices = try await client.listDevices(apiKey: key)
            clearCredentialRejection()
            return devices
        } catch let error as DotDeviceError {
            if error.invalidatesCredential { invalidateCredential() }
            throw error
        }
    }

    /// Reads the device's loop and returns the Canvas API task keys, newest
    /// order preserved. Records the count so the pane can say how many slides
    /// the loop can carry.
    @discardableResult
    public func rescanTasks(deviceID: String) async throws -> [DotTask] {
        guard let key = await currentAPIKey() else { throw DotDeviceError.unauthorized }
        await paceRequest()
        do {
            let tasks = try await client.listTasks(deviceID: deviceID, type: .loop, apiKey: key)
            var state = self.state(for: deviceID)
            state.canvasTaskCount = tasks.filter(\.isCanvasAPI).count
            states[deviceID] = state
            persist()
            clearCredentialRejection()
            return tasks
        } catch let error as DotDeviceError {
            if error.invalidatesCredential { invalidateCredential() }
            throw error
        }
    }

    /// Fetches the render the device is showing, for the read-back thumbnail.
    public func fetchRenderImage(deviceID: String) async -> Data? {
        guard let url = state(for: deviceID).renderImage else { return nil }
        await paceRequest()
        return try? await client.fetchRenderImage(url: url)
    }

    /// Reads status without pushing anything — the pane's status line on open.
    @discardableResult
    public func refreshStatus(deviceID: String) async -> DotDeviceStatus? {
        guard let key = await currentAPIKey() else { return nil }
        let read = await readStatus(deviceID: deviceID, key: key, generation: configurationGeneration)
        guard let status = read.status else {
            if let statusFailure = read.failure {
                var state = self.state(for: deviceID)
                state.lastFailure = statusFailure
                state.lastError = read.detail
                states[deviceID] = state
                persist()
            }
            return nil
        }
        var state = self.state(for: deviceID)
        state.apply(status)
        state.lastStatusAt = clock()
        states[deviceID] = state
        persist()
        return status
    }

    /// Forgets a device's recorded digests, so the next pass pushes every
    /// slide again. Used when the roster drops a device.
    public func forget(deviceID: String) {
        states.removeValue(forKey: deviceID)
        persist()
    }

    // MARK: - Digest

    /// SHA-256 over the payload's `windowData`, hex encoded.
    ///
    /// `windowData` and not the whole payload: the envelope also carries
    /// `data.generatedAt`, which moves on every assembly, so digesting it
    /// would make every pass look like a change and the skip would never fire.
    /// `refreshNow` and the task alias are likewise not content.
    public nonisolated static func digest(of payload: DotCanvasPayload) -> String {
        let encoder = DotCanvasPayload.jsonEncoder()
        guard let data = try? encoder.encode(payload.windowData) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension EInkDeviceSyncState {
    /// Folds a status read into the stored state.
    ///
    /// The power reading is the one with a consequence: `status.current` is
    /// the service's own word for how the panel is powered, in the account's
    /// language, so it is matched loosely and only ever *narrows* the cadence
    /// when it clearly says battery.
    mutating func apply(_ status: DotDeviceStatus) {
        powerLabel = status.current
        batteryLabel = status.battery
        wifiLabel = status.wifi
        onBattery = EInkPowerReading.isBattery(current: status.current, battery: status.battery)
        // Cleared, not kept: a status with no allowed image means the panel is
        // not reporting a render, and serving the previous one as "what the
        // device is showing" would be a stale picture presented as current —
        // it survives a factory reset otherwise.
        if let url = status.currentImageURL, DotRenderImagePolicy.isAllowed(url) {
            renderImageURL = url.absoluteString
        } else {
            renderImageURL = nil
        }
    }
}

/// Reads the service's power wording. Kept separate so the one string-matching
/// rule in the feature has a name and a test.
public enum EInkPowerReading {
    /// The service reports `current` as a power source. Everything that is not
    /// recognisably a battery counts as mains, because the cost of being wrong
    /// in that direction is a fresher panel, and being wrong the other way is
    /// a panel that stops updating on a device that was plugged in all along.
    public static func isBattery(current: String, battery: String) -> Bool {
        let haystack = (current + " " + battery).lowercased()
        if haystack.contains("usb") || haystack.contains("adapter") || haystack.contains("plug") {
            return false
        }
        return haystack.contains("battery") || haystack.contains("电池")
    }
}
