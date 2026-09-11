import XCTest
@testable import VibeBarCore

/// Records every call the sync engine makes and answers from a script.
///
/// `@unchecked Sendable` over a lock rather than an actor: the service is
/// `@MainActor` and the assertions read the log from the test's own context,
/// so an actor would force every assertion through an `await` for no gain.
private final class FakeDotClient: DotDeviceClienting, @unchecked Sendable {
    struct Push: Sendable {
        let deviceID: String
        let taskKey: String?
        let refreshNow: Bool
        let windowDataDigest: String
        let at: Date
    }

    private let lock = NSLock()
    private var pushLog: [Push] = []
    private var statusCallCount = 0

    var devices: [DotDevice] = []
    var tasks: [DotTask] = []
    var status = DotDeviceStatus(deviceID: "panel-1", current: "USB")
    /// Errors handed to `sendCanvas`, one per call, oldest first. An empty
    /// list means every push succeeds.
    var sendErrors: [DotDeviceError] = []
    var listError: DotDeviceError?

    var pushes: [Push] {
        lock.lock(); defer { lock.unlock() }
        return pushLog
    }

    var statusReads: Int {
        lock.lock(); defer { lock.unlock() }
        return statusCallCount
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pushLog = []
        statusCallCount = 0
    }

    func listDevices(apiKey: String) async throws -> [DotDevice] {
        if let listError { throw listError }
        return devices
    }

    func status(deviceID: String, apiKey: String) async throws -> DotDeviceStatus {
        lock.lock()
        statusCallCount += 1
        lock.unlock()
        return status
    }

    func listTasks(deviceID: String, type: DotTaskType, apiKey: String) async throws -> [DotTask] {
        if let listError { throw listError }
        return tasks
    }

    @discardableResult
    func sendCanvas(deviceID: String, payload: DotCanvasPayload, apiKey: String) async throws -> String {
        lock.lock()
        let error = sendErrors.isEmpty ? nil : sendErrors.removeFirst()
        pushLog.append(
            Push(
                deviceID: deviceID,
                taskKey: payload.taskKey,
                refreshNow: payload.refreshNow,
                windowDataDigest: EInkSyncService.digest(of: payload),
                at: Date()
            )
        )
        lock.unlock()
        if let error { throw error }
        return "ok"
    }

    func fetchRenderImage(url: URL) async throws -> Data { Data() }
}

@MainActor
final class EInkSyncServiceTests: XCTestCase {
    private var temporaryHome: URL!

    override func setUpWithError() throws {
        temporaryHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vibebar-eink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryHome)
    }

    // MARK: - Helpers

    private func slide(_ id: String, preset: EInkPreset = .quotaLedger) -> EInkSlide {
        EInkSlide(id: id, title: id, kind: .preset(preset), quotaFieldIDs: [])
    }

    private func device(
        slides: [EInkSlide],
        taskKeys: [String],
        playback: EInkPlayback
    ) -> EInkDeviceConfig {
        EInkDeviceConfig(
            deviceID: "panel-1",
            alias: "Test Panel",
            enabled: true,
            orientation: .degrees0,
            playback: playback,
            taskKeys: taskKeys,
            slides: slides
        )
    }

    private func service(
        client: FakeDotClient,
        device: EInkDeviceConfig,
        snapshot: @escaping @Sendable () async throws -> EInkDataSnapshot = { EInkFixtures.snapshot() },
        requestSpacing: Duration = .milliseconds(150),
        retryDelays: [Duration] = []
    ) -> EInkSyncService {
        let service = EInkSyncService(
            client: client,
            store: EInkSyncStateStore(homeDirectory: temporaryHome.path),
            apiKeyProvider: { "synthetic-key" },
            snapshotProvider: snapshot,
            requestSpacing: requestSpacing,
            retryDelays: retryDelays,
            snapshotReuseWindow: .zero
        )
        service.apply(
            settings: EInkSyncSettings(apiKeyPresent: true, syncEnabled: true, devices: [device]),
            layouts: [:]
        )
        return service
    }

    // MARK: - Plan

    func testDeviceLoopMapsSlideIToTaskKeyIAndNeverAsksForAnImmediateRedraw() {
        let config = device(
            slides: [slide("a"), slide("b"), slide("c")],
            taskKeys: ["k1", "k2", "k3"],
            playback: .carousel(driver: .deviceLoop, secondsPerSlide: 300)
        )
        let plan = EInkPushPlan.make(for: config, slideIndex: 0)
        XCTAssertEqual(plan.items.map(\.slideID), ["a", "b", "c"])
        XCTAssertEqual(plan.items.map(\.taskKey), ["k1", "k2", "k3"])
        XCTAssertEqual(plan.items.map(\.refreshNow), [false, false, false])
        XCTAssertNil(plan.failure)
    }

    func testDeviceLoopWithTooFewTasksPushesWhatItCanAndFlagsTheShortfall() {
        let config = device(
            slides: [slide("a"), slide("b"), slide("c")],
            taskKeys: ["k1"],
            playback: .carousel(driver: .deviceLoop, secondsPerSlide: 300)
        )
        let plan = EInkPushPlan.make(for: config, slideIndex: 0)
        XCTAssertEqual(plan.items.map(\.slideID), ["a"])
        XCTAssertEqual(plan.failure, .noTaskKeys)
    }

    func testAppTimerPushesOneSlideAtTheCurrentIndexAndAsksForAnImmediateRedraw() {
        let config = device(
            slides: [slide("a"), slide("b"), slide("c")],
            taskKeys: ["k1", "k2"],
            playback: .carousel(driver: .appTimer, secondsPerSlide: 60)
        )
        XCTAssertEqual(EInkPushPlan.make(for: config, slideIndex: 1).items.map(\.slideID), ["b"])
        XCTAssertEqual(EInkPushPlan.make(for: config, slideIndex: 4).items.map(\.slideID), ["b"])
        let plan = EInkPushPlan.make(for: config, slideIndex: 2)
        XCTAssertEqual(plan.items.map(\.taskKey), ["k1"])
        XCTAssertEqual(plan.items.map(\.refreshNow), [true])
    }

    func testSingleUsesTheFirstTaskKeyAndTheNamedSlide() {
        let config = device(
            slides: [slide("a"), slide("b")],
            taskKeys: ["k1", "k2"],
            playback: .single(slideID: "b")
        )
        let plan = EInkPushPlan.make(for: config, slideIndex: 0)
        XCTAssertEqual(plan.items.map(\.slideID), ["b"])
        XCTAssertEqual(plan.items.map(\.taskKey), ["k1"])
        XCTAssertEqual(plan.items.map(\.refreshNow), [true])
    }

    func testADeviceWithNoSlidesReportsItRatherThanPushingNothingQuietly() {
        let config = device(slides: [], taskKeys: ["k1"], playback: .single(slideID: ""))
        XCTAssertEqual(EInkPushPlan.make(for: config, slideIndex: 0).failure, .noSlides)
    }

    // MARK: - Runs

    func testOverlappingTriggersJoinTheRunInFlightInsteadOfPushingTwice() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(
                slides: [slide("a"), slide("b")],
                taskKeys: ["k1", "k2"],
                playback: .carousel(driver: .deviceLoop, secondsPerSlide: 300)
            )
        )
        async let first = sync.refresh(deviceID: "panel-1")
        async let second = sync.refresh(deviceID: "panel-1")
        async let third = sync.refresh(deviceID: "panel-1")
        _ = await (first, second, third)
        XCTAssertEqual(client.pushes.count, 2, "three triggers must produce one pass of two slides")
    }

    func testAnUnchangedPayloadIsNotPushedASecondTime() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        )
        let first = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(first.pushed, 1)
        let second = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(second.pushed, 0)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(client.pushes.count, 1)
    }

    func testPushNowIgnoresTheDigestCheckBecauseAButtonMustRedraw() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        )
        _ = await sync.refresh(deviceID: "panel-1")
        let forced = await sync.pushNow(deviceID: "panel-1")
        XCTAssertEqual(forced.pushed, 1)
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertEqual(client.pushes[0].windowDataDigest, client.pushes[1].windowDataDigest)
    }

    func testEveryPassReadsStatusExactlyOnce() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(
                slides: [slide("a"), slide("b")],
                taskKeys: ["k1", "k2"],
                playback: .carousel(driver: .deviceLoop, secondsPerSlide: 300)
            )
        )
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(client.statusReads, 1)
    }

    func testConsecutivePushesAreSpacedForTheTenPerSecondLimit() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(
                slides: [slide("a"), slide("b"), slide("c")],
                taskKeys: ["k1", "k2", "k3"],
                playback: .carousel(driver: .deviceLoop, secondsPerSlide: 300)
            )
        )
        _ = await sync.refresh(deviceID: "panel-1")
        let stamps = client.pushes.map(\.at)
        XCTAssertEqual(stamps.count, 3)
        for (previous, next) in zip(stamps, stamps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                next.timeIntervalSince(previous),
                0.1,
                "pushes must be spaced by at least DotDeviceClient.minimumRequestInterval"
            )
        }
    }

    func testAdvancingTheCarouselMovesToTheNextSlideAndWrapsAround() async {
        let client = FakeDotClient()
        let sync = service(
            client: client,
            device: device(
                slides: [slide("a"), slide("b")],
                taskKeys: ["k1"],
                playback: .carousel(driver: .appTimer, secondsPerSlide: 30)
            )
        )
        _ = await sync.refresh(deviceID: "panel-1")
        await sync.advanceCarousel(deviceID: "panel-1")
        XCTAssertEqual(sync.state(for: "panel-1").slideIndex, 1)
        await sync.advanceCarousel(deviceID: "panel-1")
        XCTAssertEqual(sync.state(for: "panel-1").slideIndex, 0)
        XCTAssertEqual(client.pushes.count, 3)
        XCTAssertTrue(client.pushes.allSatisfy { $0.refreshNow })
    }

    func testAChangedConfigurationGetsItsOwnPassRatherThanTheStaleOnesResult() async {
        let client = FakeDotClient()
        var config = device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        let sync = service(client: client, device: config)

        // A pass under the old settings, then a rotation, then a refresh: the
        // rotation must not ride out the whole interval on the old picture.
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(client.pushes.count, 1)

        config.orientation = .degrees90
        sync.apply(
            settings: EInkSyncSettings(apiKeyPresent: true, syncEnabled: true, devices: [config]),
            layouts: [:]
        )
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(client.pushes.count, 2)
        XCTAssertNotEqual(
            client.pushes[0].windowDataDigest,
            client.pushes[1].windowDataDigest,
            "the second push must carry the rotated layout"
        )
    }

    func testReplacingARejectedKeyStartsSyncingAgain() async {
        let client = FakeDotClient()
        client.sendErrors = [.unauthorized]
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        )
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertTrue(sync.credentialInvalid)

        client.reset()
        // `apiKeyPresent` does not move when a key is replaced, so only the
        // explicit signal can clear the flag.
        sync.credentialDidChange()
        XCTAssertFalse(sync.credentialInvalid)
        let outcome = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertEqual(client.pushes.count, 1)
    }

    // MARK: - Cadence

    func testABatteryDeviceUsesTheSlowerCadence() async {
        let client = FakeDotClient()
        client.status = DotDeviceStatus(deviceID: "panel-1", current: "Battery", battery: "72%")
        var config = device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        config.dataRefreshMinutes = 15
        config.batteryRefreshMinutes = 60
        let sync = service(client: client, device: config)

        XCTAssertEqual(sync.refreshInterval(for: "panel-1"), 15 * 60)
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertTrue(sync.state(for: "panel-1").onBattery)
        XCTAssertEqual(sync.refreshInterval(for: "panel-1"), 60 * 60)
    }

    func testAPoweredDeviceIsNeverMistakenForABatteryOne() {
        XCTAssertFalse(EInkPowerReading.isBattery(current: "USB", battery: "100%"))
        XCTAssertFalse(EInkPowerReading.isBattery(current: "Adapter", battery: "Battery full"))
        XCTAssertTrue(EInkPowerReading.isBattery(current: "Battery", battery: "72%"))
        XCTAssertTrue(EInkPowerReading.isBattery(current: "电池", battery: "72%"))
    }

    // MARK: - Failures

    func testARejectedKeyStopsEveryLoopAndIsSurfaced() async {
        let client = FakeDotClient()
        client.sendErrors = [.unauthorized]
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        )
        let outcome = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(outcome.failure, .unauthorized)
        XCTAssertTrue(sync.credentialInvalid)
        XCTAssertEqual(sync.state(for: "panel-1").lastFailure, .unauthorized)

        client.reset()
        client.sendErrors = []
        _ = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(client.pushes.count, 0, "a rejected key must stop pushing until it is replaced")
    }

    func testATaskMissingFromTheLoopBecomesItsOwnGuidanceRatherThanANetworkError() async {
        let client = FakeDotClient()
        client.sendErrors = [.taskNotInLoop]
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a"))
        )
        let outcome = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(outcome.failure, .taskMissing)
        XCTAssertFalse(sync.credentialInvalid)
        XCTAssertEqual(sync.state(for: "panel-1").lastFailure, .taskMissing)
    }

    func testARateLimitIsRetriedAndThenSucceeds() async {
        let client = FakeDotClient()
        client.sendErrors = [.rateLimited]
        let sync = service(
            client: client,
            device: device(slides: [slide("a")], taskKeys: ["k1"], playback: .single(slideID: "a")),
            retryDelays: [.milliseconds(1)]
        )
        let outcome = await sync.refresh(deviceID: "panel-1")
        XCTAssertEqual(outcome.pushed, 1)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(client.pushes.count, 2, "the first attempt plus the retry")
    }

    func testOnlyTransientFailuresAreWorthRetrying() {
        XCTAssertTrue(EInkSyncService.isTransient(.rateLimited))
        XCTAssertTrue(EInkSyncService.isTransient(.network("offline")))
        XCTAssertTrue(EInkSyncService.isTransient(.http(code: 503)))
        XCTAssertFalse(EInkSyncService.isTransient(.http(code: 400)))
        XCTAssertFalse(EInkSyncService.isTransient(.unauthorized))
        XCTAssertFalse(EInkSyncService.isTransient(.taskNotInLoop))
    }

    // MARK: - Digest

    func testTheDigestIgnoresTheGeneratedTimestampAndFollowsTheContent() throws {
        let device = EInkFixtures.device(orientation: .degrees0)
        let slide = EInkFixtures.slide(preset: .quotaLedger)
        var snapshot = EInkFixtures.snapshot()
        let first = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)
        snapshot.generatedAtISO = "2026-02-02T02:02:02Z"
        let sameContent = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)
        XCTAssertEqual(EInkSyncService.digest(of: first), EInkSyncService.digest(of: sameContent))

        snapshot.quota[0].remainingPercent = (snapshot.quota[0].remainingPercent + 11) % 100
        let changed = try EInkRenderer.render(slide: slide, device: device, snapshot: snapshot)
        XCTAssertNotEqual(EInkSyncService.digest(of: first), EInkSyncService.digest(of: changed))
    }

    // MARK: - State store

    func testStateSurvivesARoundTripThroughTheStore() throws {
        let store = EInkSyncStateStore(homeDirectory: temporaryHome.path)
        var state = EInkSyncState()
        state["panel-1"] = EInkDeviceSyncState(
            deviceID: "panel-1",
            pushedDigests: ["k1": "abc123"],
            lastPushAt: EInkFixtures.referenceDate,
            lastFailure: .taskMissing,
            renderImageURL: "https://os-cdn.mindreset.tech/render/synthetic.png",
            onBattery: true,
            powerLabel: "Battery",
            slideIndex: 2,
            canvasTaskCount: 3
        )
        try store.save(state)

        let reloaded = EInkSyncStateStore(homeDirectory: temporaryHome.path).load()
        XCTAssertEqual(reloaded.version, EInkSyncState.currentVersion)
        XCTAssertEqual(reloaded["panel-1"].pushedDigests, ["k1": "abc123"])
        XCTAssertEqual(reloaded["panel-1"].lastFailure, .taskMissing)
        XCTAssertTrue(reloaded["panel-1"].onBattery)
        XCTAssertEqual(reloaded["panel-1"].slideIndex, 2)
        XCTAssertEqual(reloaded["panel-1"].canvasTaskCount, 3)
        XCTAssertEqual(
            reloaded["panel-1"].renderImage?.absoluteString,
            "https://os-cdn.mindreset.tech/render/synthetic.png"
        )
    }

    func testAnUnreadableStateFileIsTreatedAsAnEmptyOne() throws {
        let store = EInkSyncStateStore(homeDirectory: temporaryHome.path)
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.url)
        XCTAssertTrue(store.load().devices.isEmpty)
    }

    func testOnlyTheServicesOwnCDNIsAcceptedForAReadBackThumbnail() {
        XCTAssertTrue(DotRenderImagePolicy.isAllowed(URL(string: "https://os-cdn.mindreset.tech/a.png")!))
        XCTAssertFalse(DotRenderImagePolicy.isAllowed(URL(string: "http://os-cdn.mindreset.tech/a.png")!))
        XCTAssertFalse(DotRenderImagePolicy.isAllowed(URL(string: "https://example.com/a.png")!))
        XCTAssertFalse(
            DotRenderImagePolicy.isAllowed(URL(string: "https://os-cdn.mindreset.tech.example.com/a.png")!)
        )
    }

    // MARK: - Roster merge

    func testFetchingDevicesKeepsEveryExistingConfigurationAndOnlyRefreshesTheAlias() {
        let existing = [
            EInkDeviceConfig(
                deviceID: "panel-1",
                alias: "Old Name",
                enabled: true,
                orientation: .degrees270,
                playback: .carousel(driver: .appTimer, secondsPerSlide: 120),
                dataRefreshMinutes: 5,
                batteryRefreshMinutes: 90,
                taskKeys: ["k1", "k2"],
                slides: [slide("a"), slide("b")]
            ),
            EInkDeviceConfig(deviceID: "panel-gone", alias: "Retired", slides: [slide("z")])
        ]
        let merged = EInkDeviceMerge.merge(
            discovered: [
                DotDevice(id: "panel-2", alias: "New Panel", model: "quote_0"),
                DotDevice(id: "panel-1", alias: "New Name", model: "quote_0")
            ],
            into: existing
        )

        XCTAssertEqual(merged.map(\.deviceID), ["panel-2", "panel-1", "panel-gone"])
        let kept = merged.first { $0.deviceID == "panel-1" }
        XCTAssertEqual(kept?.alias, "New Name")
        XCTAssertEqual(kept?.orientation, .degrees270)
        XCTAssertEqual(kept?.dataRefreshMinutes, 5)
        XCTAssertEqual(kept?.batteryRefreshMinutes, 90)
        XCTAssertEqual(kept?.taskKeys, ["k1", "k2"])
        XCTAssertEqual(kept?.slides.map(\.id), ["a", "b"])
        XCTAssertEqual(kept?.playback, .carousel(driver: .appTimer, secondsPerSlide: 120))

        // A device the account no longer lists keeps its slides: a half-failed
        // roster read must not delete work someone did.
        XCTAssertEqual(merged.last?.slides.map(\.id), ["z"])

        // A device that is new gets a usable default rather than a blank one.
        let fresh = merged.first { $0.deviceID == "panel-2" }
        XCTAssertEqual(fresh?.slides.count, 1)
        XCTAssertEqual(fresh?.slides.first?.kind.preset, .quotaLedger)
        XCTAssertEqual(fresh?.enabled, false)
    }

    // MARK: - Preview

    func testAPortraitPreviewIsAuthoredSidewaysAndRotatedIntoThePanel() {
        let snapshot = EInkFixtures.snapshot()
        let slide = EInkFixtures.slide(preset: .quotaLedger)
        let landscape = EInkPreviewPlanner.plan(slide: slide, orientation: .degrees0, snapshot: snapshot)
        XCTAssertEqual(landscape.authoredWidth, 296)
        XCTAssertEqual(landscape.authoredHeight, 152)
        XCTAssertEqual(landscape.rotationDegrees, 0)
        XCTAssertFalse(landscape.boxes.isEmpty)

        let portrait = EInkPreviewPlanner.plan(slide: slide, orientation: .degrees90, snapshot: snapshot)
        XCTAssertEqual(portrait.authoredWidth, 152)
        XCTAssertEqual(portrait.authoredHeight, 296)
        XCTAssertEqual(portrait.panelWidth, 296)
        XCTAssertEqual(portrait.panelHeight, 152)
        XCTAssertEqual(portrait.rotationDegrees, 90)
        for box in portrait.boxes {
            XCTAssertLessThanOrEqual(box.frame.maxX, 152)
            XCTAssertLessThanOrEqual(box.frame.maxY, 296)
        }
    }

    func testACustomLayoutPreviewRefusesRatherThanDrawingAPresetInstead() {
        let slide = EInkSlide(id: "custom", kind: .custom(layoutID: "layout-1"))
        let layouts = ["layout-1": EInkCanvasLayout()]
        let plan = EInkPreviewPlanner.plan(
            slide: slide,
            orientation: .degrees0,
            snapshot: EInkFixtures.snapshot(),
            layouts: layouts
        )
        XCTAssertTrue(plan.boxes.isEmpty)
        XCTAssertEqual(plan.failure, EInkRenderError.customLayoutUnsupported(layoutID: "layout-1"))
    }
}
