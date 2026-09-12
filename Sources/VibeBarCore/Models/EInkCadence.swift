import Foundation

/// The three numbers a device's refresh rhythm is made of, and the one place
/// that decides what a typed one means.
///
/// Round 1 offered steppers only, which made "every four hours" twelve clicks
/// and "once a day" ninety-six. Typing is the fix, and typing needs an answer
/// to the questions a stepper never asks: what is `2 40`, what is an empty
/// field, what is `99999`. Keeping that answer in Core rather than in the
/// settings view is what lets it be tested — the view holds a draft string and
/// nothing else.
public enum EInkCadence: String, CaseIterable, Sendable {
    case dataRefreshMinutes
    case batteryRefreshMinutes
    case secondsPerSlide

    public var range: ClosedRange<Int> {
        switch self {
        case .dataRefreshMinutes:
            EInkDeviceConfig.minimumDataRefreshMinutes...EInkDeviceConfig.maximumDataRefreshMinutes
        case .batteryRefreshMinutes:
            EInkDeviceConfig.minimumBatteryRefreshMinutes...EInkDeviceConfig.maximumBatteryRefreshMinutes
        case .secondsPerSlide:
            EInkPlayback.minimumSecondsPerSlide...EInkPlayback.maximumSecondsPerSlide
        }
    }

    public var defaultValue: Int {
        switch self {
        case .dataRefreshMinutes: EInkDeviceConfig.defaultDataRefreshMinutes
        case .batteryRefreshMinutes: EInkDeviceConfig.defaultBatteryRefreshMinutes
        case .secondsPerSlide: EInkDeviceConfig.defaultSecondsPerSlide
        }
    }

    /// The step a stepper click moves by. One minute is a useful click; one
    /// second is not, on a field whose top end is a day.
    public var step: Int {
        switch self {
        case .dataRefreshMinutes, .batteryRefreshMinutes: 1
        case .secondsPerSlide: 30
        }
    }

    public func value(in device: EInkDeviceConfig) -> Int {
        switch self {
        case .dataRefreshMinutes: device.dataRefreshMinutes
        case .batteryRefreshMinutes: device.batteryRefreshMinutes
        case .secondsPerSlide: device.secondsPerSlide
        }
    }

    public func apply(_ value: Int, to device: inout EInkDeviceConfig) {
        switch self {
        case .dataRefreshMinutes: device.dataRefreshMinutes = clamped(value)
        case .batteryRefreshMinutes: device.batteryRefreshMinutes = clamped(value)
        case .secondsPerSlide: device.secondsPerSlide = clamped(value)
        }
    }

    public func clamped(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// What a typed field commits.
    ///
    /// Anything that is not a digit is dropped rather than rejected — a reader
    /// who types "15 min" or "1,440" meant a number, and a field that silently
    /// refuses to commit is worse than one that takes the number out of the
    /// sentence. A field with no digits at all keeps `current`, which is what
    /// "I selected everything and pressed delete" should do.
    public func parse(_ text: String, current: Int) -> Int {
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digits.isEmpty else { return clamped(current) }
        // A pasted essay is not a cadence; 9 digits is already far past the
        // top of every range and keeps `Int` out of trouble on 32-bit.
        guard let parsed = Int(String(String.UnicodeScalarView(digits.prefix(9)))) else {
            return clamped(current)
        }
        return clamped(parsed)
    }
}
