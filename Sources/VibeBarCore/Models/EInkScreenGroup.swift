import Foundation

/// Screen locations are in upright display pixels, independent of the
/// panel's physical rotation. Frames share a clock; each region assigns one
/// page to one or more screens. Unassigned screens are explicitly blank.
public struct EInkScreenPlacement: Codable, Equatable, Identifiable, Sendable {
    public var deviceID: String
    public var x: Int
    public var y: Int
    public var id: String { deviceID }

    public init(deviceID: String, x: Int = 0, y: Int = 0) {
        self.deviceID = deviceID; self.x = x; self.y = y
    }
}

public struct EInkScreenRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceIDs: [String]
    public var slide: EInkSlide

    public init(id: String = UUID().uuidString, deviceIDs: [String], slide: EInkSlide) {
        self.id = id; self.deviceIDs = deviceIDs; self.slide = slide
    }
}

public struct EInkScreenFrame: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var regions: [EInkScreenRegion]

    public init(id: String = UUID().uuidString, title: String = "", regions: [EInkScreenRegion] = []) {
        self.id = id; self.title = title; self.regions = regions
    }
}

public struct EInkScreenGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var screens: [EInkScreenPlacement]
    public var frames: [EInkScreenFrame]
    public var secondsPerFrame: Int
    public var dataRefreshMinutes: Int
    public var batteryRefreshMinutes: Int
    public var behavior: EInkGroupBehavior? = nil
    public var playbackMode: EInkPlaybackMode? = nil
    public var singleSlideID: String? = nil

    public init(id: String = UUID().uuidString, name: String = "", enabled: Bool = false,
                screens: [EInkScreenPlacement] = [], frames: [EInkScreenFrame] = [],
                secondsPerFrame: Int = 300, dataRefreshMinutes: Int = 15, batteryRefreshMinutes: Int = 60) {
        self.id = id; self.name = name; self.enabled = enabled
        self.screens = screens; self.frames = frames
        self.secondsPerFrame = secondsPerFrame
        self.dataRefreshMinutes = dataRefreshMinutes; self.batteryRefreshMinutes = batteryRefreshMinutes
    }

    public func rect(for deviceID: String, devices: [EInkDeviceConfig]) -> EInkRect? {
        guard let placement = screens.first(where: { $0.deviceID == deviceID }),
              let device = devices.first(where: { $0.deviceID == deviceID }) else { return nil }
        let size = device.profile.frameSize(for: device.orientation)
        return EInkRect(x: placement.x, y: placement.y, width: size.width, height: size.height)
    }

    public func bounds(for deviceIDs: [String], devices: [EInkDeviceConfig]) -> EInkRect? {
        let rects = deviceIDs.compactMap { rect(for: $0, devices: devices) }
        guard rects.count == deviceIDs.count, let x = rects.map(\.x).min(), let y = rects.map(\.y).min(),
              let right = rects.map(\.maxX).max(), let bottom = rects.map(\.maxY).max() else { return nil }
        return EInkRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    /// Invalid spatial arrangements are refused at render time, rather than
    /// silently moving a screen or changing what an existing page means.
    func sanitized(devices: [EInkDeviceConfig], claimed: inout Set<String>) -> Self {
        var copy = self
        let valid = Set(devices.map(\.deviceID))
        copy.screens = screens.filter { valid.contains($0.deviceID) && claimed.insert($0.deviceID).inserted }
        copy.screens = copy.screens.map {
            EInkScreenPlacement(deviceID: $0.deviceID, x: min(4096, max(-4096, $0.x)), y: min(4096, max(-4096, $0.y)))
        }
        copy.secondsPerFrame = min(86400, max(10, secondsPerFrame))
        copy.dataRefreshMinutes = min(1440, max(1, dataRefreshMinutes))
        copy.batteryRefreshMinutes = min(1440, max(1, batteryRefreshMinutes))
        return copy
    }
}

public extension EInkSyncSettings {
    /// Includes grouped pages in both field discovery and retention.
    var groupContentDevices: [EInkDeviceConfig] {
        groups.map { EInkDeviceConfig(deviceID: $0.id, slides: $0.frames.flatMap { $0.regions.map(\.slide) }) }
    }

    func owningGroup(for deviceID: String) -> EInkScreenGroup? {
        groups.first { $0.screens.contains { $0.deviceID == deviceID } }
    }

    func group(for deviceID: String) -> EInkScreenGroup? {
        groups.first { $0.enabled && $0.screens.contains { $0.deviceID == deviceID } }
    }
}

public struct EInkGroupBehavior: Codable, Equatable, Sendable {
    public var alerts: EInkAlertConfig
    public var tapLink: EInkTapLink
    public var quietHours: EInkQuietHours

    public init(device: EInkDeviceConfig) {
        alerts = device.alerts; tapLink = device.tapLink; quietHours = device.quietHours
    }
}

public extension EInkScreenGroup {
    func resolvedBehavior(devices: [EInkDeviceConfig]) -> EInkGroupBehavior {
        behavior ?? EInkGroupBehavior(device: devices.first { $0.id == screens.first?.id } ?? EInkDeviceConfig(deviceID: ""))
    }
}
