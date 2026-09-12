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

    /// Every quota field id any slide holds, whatever preset it currently
    /// draws.
    ///
    /// This is the *keep* set, not the *draw* set, and the difference matters:
    /// a slide switched to a usage layout still carries the buckets it had, and
    /// pruning them from `QuotaFieldRegistry` because nothing is drawing them
    /// today would empty the picker the moment the user switched back.
    public var referencedQuotaFieldIDs: Set<String> {
        var result = Set<String>()
        for device in devices {
            for slide in device.slides {
                result.formUnion(slide.quotaFieldIDs)
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

    /// The device used to floor this at 30 s. The owner asked for a wider,
    /// typeable range, and the floor was never a device limit — it was a
    /// guess about how often a panel should flash.
    public static let minimumSecondsPerSlide = 10
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

// MARK: - Playback mode

/// The three ways a device moves between slides, as one flat choice.
///
/// Split out of `EInkPlayback` because the owner's review found the bug the
/// old shape guaranteed: "seconds per slide" lived *inside* the carousel case,
/// so switching to One slide and back threw the number away and put 300 back.
/// The mode and the cadence are independent settings and are now stored that
/// way.
public enum EInkPlaybackMode: String, Codable, CaseIterable, Sendable {
    case single
    case deviceLoop
    case appTimer
}

// MARK: - Alerts, tap link, quiet hours

/// When the engine replaces the panel with the alert slide.
public struct EInkAlertConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// A bucket at or below this much quota left alerts. `atRisk` alerts
    /// whatever this says.
    public var thresholdPercent: Int

    public static let minimumThresholdPercent = 1
    public static let maximumThresholdPercent = 99
    public static let defaultThresholdPercent = 10

    public init(enabled: Bool = true, thresholdPercent: Int = EInkAlertConfig.defaultThresholdPercent) {
        self.enabled = enabled
        self.thresholdPercent = thresholdPercent
    }

    public var sanitized: EInkAlertConfig {
        EInkAlertConfig(
            enabled: enabled,
            thresholdPercent: min(Self.maximumThresholdPercent, max(Self.minimumThresholdPercent, thresholdPercent))
        )
    }

    private enum CodingKeys: String, CodingKey { case enabled, thresholdPercent }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: c.lenient(Bool.self, .enabled, true),
            thresholdPercent: c.lenient(Int.self, .thresholdPercent, Self.defaultThresholdPercent)
        )
    }
}

/// What the panel opens when it is tapped (the Quote/0 is NFC-tappable, and
/// the phone follows the payload's `link`).
public enum EInkTapLink: Codable, Equatable, Sendable {
    case none
    /// The Vibe Bar remote dashboard, resolved at push time and omitted when
    /// Remote is not configured on this Mac.
    case remoteDashboard
    case custom(String)

    /// The URL to send, or `nil` for no link at all.
    ///
    /// HTTPS only, and never a URL with credentials in it: the value is
    /// user-entered and ends up on a phone that taps the panel.
    public func url(remoteDashboard: URL?) -> URL? {
        switch self {
        case .none:
            return nil
        case .remoteDashboard:
            return remoteDashboard.flatMap(Self.allowed)
        case let .custom(raw):
            return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(Self.allowed)
        }
    }

    static func allowed(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private enum Tag: String, Codable { case none, remoteDashboard, custom }
    private enum CodingKeys: String, CodingKey { case kind, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.lenient(Tag.self, .kind, .none) {
        case .none: self = .none
        case .remoteDashboard: self = .remoteDashboard
        case .custom: self = .custom(c.lenient(String.self, .url, ""))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode(Tag.none, forKey: .kind)
        case .remoteDashboard: try c.encode(Tag.remoteDashboard, forKey: .kind)
        case let .custom(raw):
            try c.encode(Tag.custom, forKey: .kind)
            try c.encode(raw, forKey: .url)
        }
    }
}

/// The device's own sleep window, written through `POST /settings`.
public struct EInkQuietHours: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// `HH:mm`, the device's own format.
    public var start: String
    public var end: String

    public init(enabled: Bool = false, start: String = "23:00", end: String = "07:00") {
        self.enabled = enabled
        self.start = start
        self.end = end
    }

    /// A device-acceptable window, or `nil` when either end is unreadable.
    public var window: (start: String, end: String)? {
        guard let start = Self.normalized(start), let end = Self.normalized(end) else { return nil }
        return (start, end)
    }

    /// `HH:mm` with both parts in range, or `nil`.
    public static func normalized(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    public var sanitized: EInkQuietHours {
        EInkQuietHours(
            enabled: enabled,
            start: Self.normalized(start) ?? "23:00",
            end: Self.normalized(end) ?? "07:00"
        )
    }

    private enum CodingKeys: String, CodingKey { case enabled, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: c.lenient(Bool.self, .enabled, false),
            start: c.lenient(String.self, .start, "23:00"),
            end: c.lenient(String.self, .end, "07:00")
        )
    }
}

// MARK: - Device

public struct EInkDeviceConfig: Codable, Equatable, Identifiable, Sendable {
    public var deviceID: String
    public var alias: String
    public var profile: EInkDeviceProfile
    public var enabled: Bool
    public var orientation: EInkOrientation
    /// How the device moves between slides.
    public var playbackMode: EInkPlaybackMode
    /// Kept whatever the mode is — see `EInkPlaybackMode`.
    public var secondsPerSlide: Int
    /// The slide `single` shows. Kept across a switch to a carousel and back
    /// for the same reason `secondsPerSlide` is.
    public var singleSlideID: String
    public var alerts: EInkAlertConfig
    public var tapLink: EInkTapLink
    public var quietHours: EInkQuietHours
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
    public static let maximumDataRefreshMinutes = 1440
    public static let defaultBatteryRefreshMinutes = 60
    public static let minimumBatteryRefreshMinutes = 1
    public static let maximumBatteryRefreshMinutes = 1440
    public static let defaultSecondsPerSlide = 300

    public init(
        deviceID: String,
        alias: String = "",
        profile: EInkDeviceProfile = .quote0,
        enabled: Bool = false,
        orientation: EInkOrientation = .degrees0,
        playbackMode: EInkPlaybackMode = .single,
        secondsPerSlide: Int = EInkDeviceConfig.defaultSecondsPerSlide,
        singleSlideID: String = "",
        alerts: EInkAlertConfig = EInkAlertConfig(),
        tapLink: EInkTapLink = .none,
        quietHours: EInkQuietHours = EInkQuietHours(),
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
        self.playbackMode = playbackMode
        self.secondsPerSlide = secondsPerSlide
        self.singleSlideID = singleSlideID
        self.alerts = alerts
        self.tapLink = tapLink
        self.quietHours = quietHours
        self.dataRefreshMinutes = dataRefreshMinutes
        self.batteryRefreshMinutes = batteryRefreshMinutes
        self.taskKeys = taskKeys
        self.slides = slides
    }

    /// Convenience initializer keeping the round 1 call shape, so callers
    /// that think in `EInkPlayback` do not have to be rewritten.
    public init(
        deviceID: String,
        alias: String = "",
        profile: EInkDeviceProfile = .quote0,
        enabled: Bool = false,
        orientation: EInkOrientation = .degrees0,
        playback: EInkPlayback,
        dataRefreshMinutes: Int = EInkDeviceConfig.defaultDataRefreshMinutes,
        batteryRefreshMinutes: Int = EInkDeviceConfig.defaultBatteryRefreshMinutes,
        taskKeys: [String] = [],
        slides: [EInkSlide] = []
    ) {
        self.init(
            deviceID: deviceID,
            alias: alias,
            profile: profile,
            enabled: enabled,
            orientation: orientation,
            dataRefreshMinutes: dataRefreshMinutes,
            batteryRefreshMinutes: batteryRefreshMinutes,
            taskKeys: taskKeys,
            slides: slides
        )
        self.playback = playback
    }

    /// The mode and the cadence read as one value, for the push planner and
    /// the carousel loop that only ever ask "which slide, how often".
    ///
    /// Writing it back never loses the other half: setting `.single` keeps
    /// `secondsPerSlide`, and setting a carousel keeps `singleSlideID`.
    public var playback: EInkPlayback {
        get {
            switch playbackMode {
            case .single: return .single(slideID: singleSlideID)
            case .deviceLoop: return .carousel(driver: .deviceLoop, secondsPerSlide: secondsPerSlide)
            case .appTimer: return .carousel(driver: .appTimer, secondsPerSlide: secondsPerSlide)
            }
        }
        set {
            switch newValue {
            case let .single(slideID):
                playbackMode = .single
                singleSlideID = slideID
            case let .carousel(driver, seconds):
                playbackMode = driver == .appTimer ? .appTimer : .deviceLoop
                secondsPerSlide = seconds
            }
        }
    }

    public func slide(id: String) -> EInkSlide? { slides.first { $0.id == id } }

    /// The slide a single-display device shows: the named one, else the first.
    public var resolvedSingleSlide: EInkSlide? {
        if playbackMode == .single, let match = slide(id: singleSlideID) { return match }
        return slides.first
    }

    public var sanitized: EInkDeviceConfig {
        var copy = self
        copy.profile = profile.sanitized
        copy.dataRefreshMinutes = max(
            Self.minimumDataRefreshMinutes,
            min(Self.maximumDataRefreshMinutes, dataRefreshMinutes)
        )
        copy.batteryRefreshMinutes = max(
            Self.minimumBatteryRefreshMinutes,
            min(Self.maximumBatteryRefreshMinutes, batteryRefreshMinutes)
        )
        copy.secondsPerSlide = max(
            EInkPlayback.minimumSecondsPerSlide,
            min(EInkPlayback.maximumSecondsPerSlide, secondsPerSlide)
        )
        copy.alerts = alerts.sanitized
        copy.quietHours = quietHours.sanitized
        var seenTasks = Set<String>()
        copy.taskKeys = taskKeys.filter { !$0.isEmpty && seenTasks.insert($0).inserted }
        var seenSlides = Set<String>()
        copy.slides = slides
            .filter { !$0.id.isEmpty && seenSlides.insert($0.id).inserted }
            .map { $0.sanitized.fitted(to: copy.orientation) }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, alias, profile, enabled, orientation, playback
        case playbackMode, secondsPerSlide, singleSlideID, alerts, tapLink, quietHours
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
            alerts: c.lenient(EInkAlertConfig.self, .alerts, EInkAlertConfig()),
            tapLink: c.lenient(EInkTapLink.self, .tapLink, .none),
            quietHours: c.lenient(EInkQuietHours.self, .quietHours, EInkQuietHours()),
            dataRefreshMinutes: c.lenient(Int.self, .dataRefreshMinutes, Self.defaultDataRefreshMinutes),
            batteryRefreshMinutes: c.lenient(Int.self, .batteryRefreshMinutes, Self.defaultBatteryRefreshMinutes),
            taskKeys: c.lenient([String].self, .taskKeys, []),
            slides: c.lenient([EInkSlide].self, .slides, [])
        )
        // Round 1 wrote one `playback` object; round 2 writes three fields.
        // Seeding from the old value first and then letting the new keys win
        // is what makes a file written by either build read correctly, and
        // what stops a downgrade-then-upgrade from losing the cadence.
        if let legacy = c.lenientOptional(EInkPlayback.self, .playback) {
            playback = legacy.sanitized
        }
        if let mode = c.lenientOptional(EInkPlaybackMode.self, .playbackMode) {
            playbackMode = mode
        }
        if let seconds = c.lenientOptional(Int.self, .secondsPerSlide) {
            secondsPerSlide = seconds
        }
        if let slideID = c.lenientOptional(String.self, .singleSlideID) {
            singleSlideID = slideID
        }
        secondsPerSlide = max(
            EInkPlayback.minimumSecondsPerSlide,
            min(EInkPlayback.maximumSecondsPerSlide, secondsPerSlide)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(alias, forKey: .alias)
        try c.encode(profile, forKey: .profile)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(orientation.rawValue, forKey: .orientation)
        // Both shapes: an older build reads `playback` and keeps working.
        try c.encode(playback, forKey: .playback)
        try c.encode(playbackMode, forKey: .playbackMode)
        try c.encode(secondsPerSlide, forKey: .secondsPerSlide)
        try c.encode(singleSlideID, forKey: .singleSlideID)
        try c.encode(alerts, forKey: .alerts)
        try c.encode(tapLink, forKey: .tapLink)
        try c.encode(quietHours, forKey: .quietHours)
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
    /// Header / footer / slot order / per-slot labels. `.default` reproduces
    /// the round 1 panel exactly.
    public var options: EInkSlideOptions

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        kind: Kind = .preset(.quotaLedger),
        quotaFieldIDs: [String] = [],
        usagePeriods: [EInkUsagePeriod] = EInkUsagePeriod.allCases,
        options: EInkSlideOptions = .default
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.quotaFieldIDs = quotaFieldIDs
        self.usagePeriods = usagePeriods
        self.options = options
    }

    /// Per-slot label overrides. Stored inside `options` so one struct carries
    /// everything the slide editor writes.
    public var customLabels: [String: String] {
        get { options.customLabels }
        set { options.customLabels = newValue }
    }

    /// The quota buckets this slide draws, in the order the editor put them.
    public var orderedQuotaFieldIDs: [String] { options.ordered(quotaFieldIDs) }

    /// The usage windows this slide draws, in the order the editor put them.
    public func orderedUsagePeriods(_ periods: [EInkUsagePeriod]) -> [EInkUsagePeriod] {
        let ordered = options.ordered(periods.map(\.rawValue))
        return ordered.compactMap(EInkUsagePeriod.init(rawValue:))
    }

    public var sanitized: EInkSlide {
        var copy = self
        var seenFields = Set<String>()
        copy.quotaFieldIDs = quotaFieldIDs.filter { !$0.isEmpty && seenFields.insert($0).inserted }
        var seenPeriods = Set<EInkUsagePeriod>()
        copy.usagePeriods = usagePeriods.filter { seenPeriods.insert($0).inserted }
        copy.options = options.sanitized
        return copy
    }

    /// The buckets a new slide should start with, given what the account
    /// actually exposes.
    ///
    /// The verified priority order first, narrowed to what is live, then
    /// anything else the account has. The narrowing is the point: on a
    /// Gemini-only account the global order's first five are all absent, so a
    /// slide seeded from the catalog fills to capacity with rows
    /// `EInkDataSnapshot.quotaRows` then filters out — a blank panel the user
    /// has to repair by deselecting providers they never chose.
    public static func defaultQuotaFieldIDs(live: [String]) -> [String] {
        let priority = EInkDataAssembler.defaultQuotaPriority.map(\.fieldID)
        guard !live.isEmpty else { return priority }
        let liveSet = Set(live)
        var seen = Set<String>()
        var ordered = priority.filter { liveSet.contains($0) && seen.insert($0).inserted }
        ordered += live.filter { seen.insert($0).inserted }
        return ordered
    }

    /// A ready-to-draw quota slide.
    ///
    /// Seeded with the buckets the renderer would have fallen back to anyway,
    /// because an empty selection means "Vibe Bar's own order" there while the
    /// picker reads it as "nothing chosen" — every box off above a panel
    /// showing five rows. Writing the defaults down makes the two agree, and
    /// makes the first thing the user does *edit* a selection rather than
    /// discover one.
    public static func defaultQuotaSlide(
        preset: EInkPreset = .quotaLedger,
        orientation: EInkOrientation = .degrees0,
        available: [String] = EInkDataAssembler.defaultQuotaPriority.map(\.fieldID)
    ) -> EInkSlide {
        EInkSlide(
            kind: .preset(preset),
            quotaFieldIDs: Array(
                EInkSlide.defaultQuotaFieldIDs(live: available)
                    .prefix(preset.capacity(for: orientation))
            )
        )
    }

    /// Trims the selection to what the layout has room for at this
    /// orientation.
    ///
    /// Capacity is orientation-dependent — the quota layouts hold six in
    /// portrait and five in landscape — so a rotation can leave a slide
    /// carrying more than it can draw. The renderer already takes a prefix, so
    /// the extra rows were invisible; what they were not is *honest*, because
    /// the picker kept counting them and the reader kept looking for a row the
    /// panel was never going to print.
    public func fitted(to orientation: EInkOrientation) -> EInkSlide {
        guard let preset = kind.preset else { return self }
        let capacity = max(0, preset.capacity(for: orientation))
        var copy = self
        switch preset.selectionAxis {
        case .quotaFields:
            copy.quotaFieldIDs = Array(quotaFieldIDs.prefix(capacity))
        case .usagePeriods:
            copy.usagePeriods = Array(usagePeriods.prefix(capacity))
        case .harnessRows, .none:
            break
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, quotaFieldIDs, usagePeriods, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPeriods = c.lenientOptional([String].self, .usagePeriods)
        self.init(
            id: c.lenient(String.self, .id, UUID().uuidString),
            title: c.lenient(String.self, .title, ""),
            kind: c.lenient(Kind.self, .kind, .preset(.quotaLedger)),
            quotaFieldIDs: c.lenient([String].self, .quotaFieldIDs, []),
            usagePeriods: rawPeriods.map { $0.compactMap(EInkUsagePeriod.init(rawValue:)) } ?? EInkUsagePeriod.allCases,
            options: c.lenient(EInkSlideOptions.self, .options, .default)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        try c.encode(quotaFieldIDs, forKey: .quotaFieldIDs)
        try c.encode(usagePeriods.map(\.rawValue), forKey: .usagePeriods)
        try c.encode(options, forKey: .options)
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
