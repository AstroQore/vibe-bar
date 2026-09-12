import Foundation

/// Why a device's last sync attempt failed, in a form the settings UI can
/// turn into guidance rather than a raw HTTP code.
///
/// `taskMissing` is the one the user can actually act on: the Dot. API only
/// *updates* a Canvas API task that already exists in the device's loop, so a
/// 404 on the canvas write means the task has to be added on the phone first.
public enum EInkSyncFailure: String, Codable, Equatable, Sendable {
    case unauthorized
    case taskMissing
    case deviceMissing
    case rateLimited
    case network
    case render
    case noTaskKeys
    case noSlides
    /// The local usage ledger could not be read. Quota slides still went out;
    /// the usage ones were skipped rather than drawn as zeros, because a panel
    /// reading "$0 today" is a wrong answer, not a missing one.
    case usageUnavailable
}

/// What the sync engine remembers about one device between launches.
///
/// Everything here is derived: deleting the file costs one redundant push per
/// device and nothing else. It is deliberately free of anything secret — no
/// key, no bearer token, and the render URL is the service's own CDN link.
public struct EInkDeviceSyncState: Codable, Equatable, Sendable {
    public var deviceID: String
    /// Canvas API task key → digest of the `windowData` last pushed to it.
    ///
    /// The digest covers `windowData` alone rather than the whole payload: a
    /// payload also carries `data.generatedAt`, which moves on every
    /// assembly, so digesting the envelope would make every refresh look like
    /// a change and defeat the point of the check.
    public var pushedDigests: [String: String]
    public var lastPushAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var lastFailure: EInkSyncFailure?
    /// `renderInfo.current.image[0]` from the last status read.
    public var renderImageURL: String?
    /// True when the last status read said the device is running on battery,
    /// which switches the loop to `batteryRefreshMinutes`.
    public var onBattery: Bool
    public var powerLabel: String
    public var batteryLabel: String
    public var wifiLabel: String
    public var nextRefreshAt: Date?
    /// Index of the slide the app-timer carousel will push next.
    public var slideIndex: Int
    /// Canvas API tasks counted by the last loop scan, or `nil` if never run.
    public var canvasTaskCount: Int?
    /// Tasks in the loop that no slide claims, as of the last pass.
    public var surplusTaskCount: Int
    public var lastStatusAt: Date?

    public init(
        deviceID: String,
        pushedDigests: [String: String] = [:],
        lastPushAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        lastFailure: EInkSyncFailure? = nil,
        renderImageURL: String? = nil,
        onBattery: Bool = false,
        powerLabel: String = "",
        batteryLabel: String = "",
        wifiLabel: String = "",
        nextRefreshAt: Date? = nil,
        slideIndex: Int = 0,
        canvasTaskCount: Int? = nil,
        surplusTaskCount: Int = 0,
        lastStatusAt: Date? = nil
    ) {
        self.deviceID = deviceID
        self.pushedDigests = pushedDigests
        self.lastPushAt = lastPushAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.lastFailure = lastFailure
        self.renderImageURL = renderImageURL
        self.onBattery = onBattery
        self.powerLabel = powerLabel
        self.batteryLabel = batteryLabel
        self.wifiLabel = wifiLabel
        self.nextRefreshAt = nextRefreshAt
        self.slideIndex = slideIndex
        self.canvasTaskCount = canvasTaskCount
        self.surplusTaskCount = surplusTaskCount
        self.lastStatusAt = lastStatusAt
    }

    /// The read-back thumbnail, only when the service handed us one of its own
    /// CDN links. Anything else is dropped rather than fetched.
    public var renderImage: URL? {
        guard let renderImageURL, let url = URL(string: renderImageURL) else { return nil }
        return DotRenderImagePolicy.isAllowed(url) ? url : nil
    }

    /// This state, with the fields a push pass does not own taken from
    /// `latest`.
    ///
    /// A pass captures the state before its network work and commits after, so
    /// anything written in between — a loop scan's task count, a carousel
    /// tick's slide index — belongs to whoever wrote it, not to the snapshot
    /// this pass has been carrying around.
    public func committing(over latest: EInkDeviceSyncState) -> EInkDeviceSyncState {
        var merged = self
        merged.slideIndex = latest.slideIndex
        merged.canvasTaskCount = latest.canvasTaskCount
        return merged
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, pushedDigests, lastPushAt, lastAttemptAt, lastError, lastFailure
        case renderImageURL, onBattery, powerLabel, batteryLabel, wifiLabel
        case nextRefreshAt, slideIndex, canvasTaskCount, surplusTaskCount, lastStatusAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deviceID: c.lenient(String.self, .deviceID, ""),
            pushedDigests: c.lenient([String: String].self, .pushedDigests, [:]),
            lastPushAt: c.lenientOptional(Date.self, .lastPushAt),
            lastAttemptAt: c.lenientOptional(Date.self, .lastAttemptAt),
            lastError: c.lenientOptional(String.self, .lastError),
            lastFailure: c.lenientOptional(EInkSyncFailure.self, .lastFailure),
            renderImageURL: c.lenientOptional(String.self, .renderImageURL),
            onBattery: c.lenient(Bool.self, .onBattery, false),
            powerLabel: c.lenient(String.self, .powerLabel, ""),
            batteryLabel: c.lenient(String.self, .batteryLabel, ""),
            wifiLabel: c.lenient(String.self, .wifiLabel, ""),
            nextRefreshAt: c.lenientOptional(Date.self, .nextRefreshAt),
            slideIndex: max(0, c.lenient(Int.self, .slideIndex, 0)),
            canvasTaskCount: c.lenientOptional(Int.self, .canvasTaskCount),
            surplusTaskCount: max(0, c.lenient(Int.self, .surplusTaskCount, 0)),
            lastStatusAt: c.lenientOptional(Date.self, .lastStatusAt)
        )
    }
}

/// The whole `~/.vibebar/eink_state.json` file.
public struct EInkSyncState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var devices: [String: EInkDeviceSyncState]

    public init(version: Int = EInkSyncState.currentVersion, devices: [String: EInkDeviceSyncState] = [:]) {
        self.version = version
        self.devices = devices
    }

    public subscript(deviceID: String) -> EInkDeviceSyncState {
        get { devices[deviceID] ?? EInkDeviceSyncState(deviceID: deviceID) }
        set { devices[deviceID] = newValue }
    }

    private enum CodingKeys: String, CodingKey { case version, devices }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: c.lenient(Int.self, .version, Self.currentVersion),
            devices: c.lenient([String: EInkDeviceSyncState].self, .devices, [:])
        )
    }
}

/// Which render URLs Vibe Bar is willing to fetch a thumbnail from.
///
/// The URL arrives inside an API response, so it is untrusted input: without
/// this gate a compromised or mistaken response could point the app at an
/// arbitrary host and have it make a request there. One host, HTTPS only.
public enum DotRenderImagePolicy {
    public static let allowedHost = "os-cdn.mindreset.tech"
    /// A panel render is a 296 × 152 1-bit PNG — a few kilobytes. 2 MB is
    /// generous and still bounded.
    public static let maxBytes = 2 * 1024 * 1024

    public static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == allowedHost
    }
}
