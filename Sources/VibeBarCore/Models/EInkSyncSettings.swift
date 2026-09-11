import Foundation

/// Everything the E-ink sync feature persists in `settings.json`, under its
/// own top-level `einkSync` key.
///
/// The Dot. API key itself is never stored here — it lives in the Keychain
/// through `EInkCredentialStore`, and this struct only records whether one
/// was ever written. Keeping the roster on its own top-level key matters for
/// the same reason `miniCanvasLayouts` has one: `SettingsDocument` merges two
/// clients' writes at top-level-key granularity, so a desktop client editing
/// device configuration must not clobber a freshly edited canvas layout.
public struct EInkSyncSettings: Codable, Equatable, Sendable {
    /// Mirrors the Keychain: `true` once a key was stored, `false` after it
    /// was deleted or found invalid. Never holds the key itself.
    public var apiKeyPresent: Bool
    public var syncEnabled: Bool
    public var devices: [EInkDeviceConfig]

    public init(
        apiKeyPresent: Bool = false,
        syncEnabled: Bool = false,
        devices: [EInkDeviceConfig] = []
    ) {
        self.apiKeyPresent = apiKeyPresent
        self.syncEnabled = syncEnabled
        self.devices = devices
    }

    public static let `default` = EInkSyncSettings()

    /// Every quota bucket any slide on any device has picked, in first-seen
    /// order. The assembler needs it so a chosen bucket is actually gathered.
    public var selectedQuotaFieldIDs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for device in devices {
            for slide in device.slides where slide.kind.preset?.isQuotaPreset ?? false {
                for fieldID in slide.quotaFieldIDs where seen.insert(fieldID).inserted {
                    result.append(fieldID)
                }
            }
        }
        return result
    }

    public func device(id: String) -> EInkDeviceConfig? {
        devices.first { $0.deviceID == id }
    }

    /// Drops duplicate device IDs and normalizes every device in place.
    public var sanitized: EInkSyncSettings {
        var seen = Set<String>()
        var copy = self
        copy.devices = devices
            .filter { !$0.deviceID.isEmpty && seen.insert($0.deviceID).inserted }
            .map(\.sanitized)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case apiKeyPresent, syncEnabled, devices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apiKeyPresent: c.lenient(Bool.self, .apiKeyPresent, false),
            syncEnabled: c.lenient(Bool.self, .syncEnabled, false),
            devices: c.lenient([EInkDeviceConfig].self, .devices, [])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiKeyPresent, forKey: .apiKeyPresent)
        try c.encode(syncEnabled, forKey: .syncEnabled)
        try c.encode(devices, forKey: .devices)
    }
}

// MARK: - Device profile

/// The panel a device has. `quote_0` is the only model Vibe Bar has been
/// verified against: 296 × 152 physical pixels, 1-bit black and white.
public enum EInkDeviceModel: String, Codable, CaseIterable, Sendable {
    case quote0 = "quote_0"

    public var pixelWidth: Int {
        switch self {
        case .quote0: 296
        }
    }

    public var pixelHeight: Int {
        switch self {
        case .quote0: 152
        }
    }
}

public struct EInkDeviceProfile: Codable, Equatable, Sendable {
    public var model: EInkDeviceModel
    public var width: Int
    public var height: Int

    public init(model: EInkDeviceModel = .quote0, width: Int = 296, height: Int = 152) {
        self.model = model
        self.width = width
        self.height = height
    }

    public static let quote0 = EInkDeviceProfile(model: .quote0, width: 296, height: 152)

    /// The frame a layout is authored in, which is the panel turned on its
    /// side for the two portrait rotations.
    public func frameSize(for orientation: EInkOrientation) -> (width: Int, height: Int) {
        orientation.isPortrait ? (height, width) : (width, height)
    }

    public var sanitized: EInkDeviceProfile {
        EInkDeviceProfile(
            model: model,
            width: width > 0 ? min(width, 4096) : model.pixelWidth,
            height: height > 0 ? min(height, 4096) : model.pixelHeight
        )
    }

    private enum CodingKeys: String, CodingKey { case model, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let model = c.lenient(EInkDeviceModel.self, .model, .quote0)
        self.init(
            model: model,
            width: c.lenient(Int.self, .width, model.pixelWidth),
            height: c.lenient(Int.self, .height, model.pixelHeight)
        )
    }
}

/// Clockwise rotation applied to the authored layout before it reaches the
/// panel. 90° and 270° are the two portrait readings of the same panel.
public enum EInkOrientation: Int, Codable, CaseIterable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    public var isPortrait: Bool { self == .degrees90 || self == .degrees270 }

    /// The CSS angle: 270° is expressed as -90° so the shorter arc is taken.
    public var cssDegrees: Int { self == .degrees270 ? -90 : rawValue }
}

// MARK: - Playback

/// How a device moves between its slides.
///
/// The Dot. API can only *update* a Canvas API task that already exists in
/// the device's loop; it cannot create one. `deviceLoop` therefore pushes one
/// slide per pre-existing task and lets the device rotate them on its own
/// schedule, while `appTimer` reuses a single task and re-pushes on a Mac-side
/// timer (one full e-ink refresh per switch).
public enum EInkPlayback: Codable, Equatable, Sendable {
    case single(slideID: String)
    case carousel(driver: Driver, secondsPerSlide: Int)

    public enum Driver: String, Codable, CaseIterable, Sendable {
        case deviceLoop
        case appTimer
    }

    public static let minimumSecondsPerSlide = 30
    public static let maximumSecondsPerSlide = 24 * 60 * 60
    public static let `default` = EInkPlayback.single(slideID: "")

    public var slideID: String? {
        if case let .single(slideID) = self { return slideID }
        return nil
    }

    public var driver: Driver? {
        if case let .carousel(driver, _) = self { return driver }
        return nil
    }

    public var sanitized: EInkPlayback {
        switch self {
        case let .single(slideID):
            return .single(slideID: slideID)
        case let .carousel(driver, seconds):
            let clamped = min(Self.maximumSecondsPerSlide, max(Self.minimumSecondsPerSlide, seconds))
            return .carousel(driver: driver, secondsPerSlide: clamped)
        }
    }

    private enum Kind: String, Codable { case single, carousel }
    private enum CodingKeys: String, CodingKey { case kind, slideID, driver, secondsPerSlide }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = c.lenient(Kind.self, .kind, .single)
        switch kind {
        case .single:
            self = .single(slideID: c.lenient(String.self, .slideID, ""))
        case .carousel:
            let driver = c.lenient(Driver.self, .driver, .deviceLoop)
            let seconds = c.lenient(Int.self, .secondsPerSlide, 300)
            self = EInkPlayback.carousel(driver: driver, secondsPerSlide: seconds).sanitized
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch sanitized {
        case let .single(slideID):
            try c.encode(Kind.single, forKey: .kind)
            try c.encode(slideID, forKey: .slideID)
        case let .carousel(driver, seconds):
            try c.encode(Kind.carousel, forKey: .kind)
            try c.encode(driver, forKey: .driver)
            try c.encode(seconds, forKey: .secondsPerSlide)
        }
    }
}

// MARK: - Device

public struct EInkDeviceConfig: Codable, Equatable, Identifiable, Sendable {
    public var deviceID: String
    public var alias: String
    public var profile: EInkDeviceProfile
    public var enabled: Bool
    public var orientation: EInkOrientation
    public var playback: EInkPlayback
    /// How often the data behind every slide is re-assembled and re-pushed.
    public var dataRefreshMinutes: Int
    /// Battery / Wi-Fi read-back cadence; far cheaper than a push, but it
    /// still wakes the API, so it defaults to an hour.
    public var batteryRefreshMinutes: Int
    /// Canvas API task keys already present in the device's loop, in the order
    /// slides are assigned to them.
    public var taskKeys: [String]
    public var slides: [EInkSlide]

    public var id: String { deviceID }

    public static let defaultDataRefreshMinutes = 15
    public static let minimumDataRefreshMinutes = 1
    public static let defaultBatteryRefreshMinutes = 60
    public static let minimumBatteryRefreshMinutes = 1

    public init(
        deviceID: String,
        alias: String = "",
        profile: EInkDeviceProfile = .quote0,
        enabled: Bool = false,
        orientation: EInkOrientation = .degrees0,
        playback: EInkPlayback = .single(slideID: ""),
        dataRefreshMinutes: Int = EInkDeviceConfig.defaultDataRefreshMinutes,
        batteryRefreshMinutes: Int = EInkDeviceConfig.defaultBatteryRefreshMinutes,
        taskKeys: [String] = [],
        slides: [EInkSlide] = []
    ) {
        self.deviceID = deviceID
        self.alias = alias
        self.profile = profile
        self.enabled = enabled
        self.orientation = orientation
        self.playback = playback
        self.dataRefreshMinutes = dataRefreshMinutes
        self.batteryRefreshMinutes = batteryRefreshMinutes
        self.taskKeys = taskKeys
        self.slides = slides
    }

    public func slide(id: String) -> EInkSlide? { slides.first { $0.id == id } }

    /// The slide a single-display device shows: the named one, else the first.
    public var resolvedSingleSlide: EInkSlide? {
        if case let .single(slideID) = playback, let match = slide(id: slideID) { return match }
        return slides.first
    }

    public var sanitized: EInkDeviceConfig {
        var copy = self
        copy.profile = profile.sanitized
        copy.dataRefreshMinutes = max(Self.minimumDataRefreshMinutes, min(24 * 60, dataRefreshMinutes))
        copy.batteryRefreshMinutes = max(Self.minimumBatteryRefreshMinutes, min(24 * 60, batteryRefreshMinutes))
        var seenTasks = Set<String>()
        copy.taskKeys = taskKeys.filter { !$0.isEmpty && seenTasks.insert($0).inserted }
        var seenSlides = Set<String>()
        copy.slides = slides
            .filter { !$0.id.isEmpty && seenSlides.insert($0.id).inserted }
            .map(\.sanitized)
        copy.playback = playback.sanitized
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, alias, profile, enabled, orientation, playback
        case dataRefreshMinutes, batteryRefreshMinutes, taskKeys, slides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let orientationRaw = c.lenientOptional(Int.self, .orientation)
        self.init(
            deviceID: c.lenient(String.self, .deviceID, ""),
            alias: c.lenient(String.self, .alias, ""),
            profile: c.lenient(EInkDeviceProfile.self, .profile, .quote0),
            enabled: c.lenient(Bool.self, .enabled, false),
            orientation: orientationRaw.flatMap(EInkOrientation.init(rawValue:)) ?? .degrees0,
            playback: c.lenient(EInkPlayback.self, .playback, .single(slideID: "")),
            dataRefreshMinutes: c.lenient(Int.self, .dataRefreshMinutes, Self.defaultDataRefreshMinutes),
            batteryRefreshMinutes: c.lenient(Int.self, .batteryRefreshMinutes, Self.defaultBatteryRefreshMinutes),
            taskKeys: c.lenient([String].self, .taskKeys, []),
            slides: c.lenient([EInkSlide].self, .slides, [])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(alias, forKey: .alias)
        try c.encode(profile, forKey: .profile)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(orientation.rawValue, forKey: .orientation)
        try c.encode(playback, forKey: .playback)
        try c.encode(dataRefreshMinutes, forKey: .dataRefreshMinutes)
        try c.encode(batteryRefreshMinutes, forKey: .batteryRefreshMinutes)
        try c.encode(taskKeys, forKey: .taskKeys)
        try c.encode(slides, forKey: .slides)
    }
}

// MARK: - Slide

/// One screen's worth of content: which preset (or custom layout) draws it,
/// and which of the available fields it is allowed to show.
public struct EInkSlide: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case preset(EInkPreset)
        case custom(layoutID: String)

        public var preset: EInkPreset? {
            if case let .preset(preset) = self { return preset }
            return nil
        }

        public var layoutID: String? {
            if case let .custom(layoutID) = self { return layoutID }
            return nil
        }

        private enum Tag: String, Codable { case preset, custom }
        private enum CodingKeys: String, CodingKey { case kind, preset, layoutID }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tag = c.lenient(Tag.self, .kind, .preset)
            switch tag {
            case .preset:
                self = .preset(c.lenient(EInkPreset.self, .preset, .quotaLedger))
            case .custom:
                self = .custom(layoutID: c.lenient(String.self, .layoutID, ""))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .preset(preset):
                try c.encode(Tag.preset, forKey: .kind)
                try c.encode(preset, forKey: .preset)
            case let .custom(layoutID):
                try c.encode(Tag.custom, forKey: .kind)
                try c.encode(layoutID, forKey: .layoutID)
            }
        }
    }

    public var id: String
    public var title: String
    public var kind: Kind
    /// `MenuBarFieldCatalog` field IDs ("claude.weekly"), in display order.
    public var quotaFieldIDs: [String]
    public var usagePeriods: [EInkUsagePeriod]

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        kind: Kind = .preset(.quotaLedger),
        quotaFieldIDs: [String] = [],
        usagePeriods: [EInkUsagePeriod] = EInkUsagePeriod.allCases
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.quotaFieldIDs = quotaFieldIDs
        self.usagePeriods = usagePeriods
    }

    public var sanitized: EInkSlide {
        var copy = self
        var seenFields = Set<String>()
        copy.quotaFieldIDs = quotaFieldIDs.filter { !$0.isEmpty && seenFields.insert($0).inserted }
        var seenPeriods = Set<EInkUsagePeriod>()
        copy.usagePeriods = usagePeriods.filter { seenPeriods.insert($0).inserted }
        return copy
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, quotaFieldIDs, usagePeriods }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPeriods = c.lenientOptional([String].self, .usagePeriods)
        self.init(
            id: c.lenient(String.self, .id, UUID().uuidString),
            title: c.lenient(String.self, .title, ""),
            kind: c.lenient(Kind.self, .kind, .preset(.quotaLedger)),
            quotaFieldIDs: c.lenient([String].self, .quotaFieldIDs, []),
            usagePeriods: rawPeriods.map { $0.compactMap(EInkUsagePeriod.init(rawValue:)) } ?? EInkUsagePeriod.allCases
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        try c.encode(quotaFieldIDs, forKey: .quotaFieldIDs)
        try c.encode(usagePeriods.map(\.rawValue), forKey: .usagePeriods)
    }
}

/// The four usage windows the presets can show. `today` starts at local
/// midnight; `week` and `month` are rolling 7- and 30-day windows.
public enum EInkUsagePeriod: String, Codable, CaseIterable, Hashable, Sendable {
    case today
    case week
    case month
    case allTime

    /// Uppercase caption exactly as the verified demo prints it.
    public var caption: String {
        switch self {
        case .today: "TODAY"
        case .week: "7 DAYS"
        case .month: "30 DAYS"
        case .allTime: "ALL TIME"
        }
    }
}
