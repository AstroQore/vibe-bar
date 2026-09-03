import Foundation

/// The release stream Vibe Bar asks Sparkle to follow.
///
/// Sparkle always includes its untagged default channel. Selecting Dev adds
/// the `dev` channel on top, so preview users can still receive a newer Main
/// security or compatibility release.
public enum UpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case main
    case dev

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .main:
            return L10n.Settings.updateChannelMain
        case .dev:
            return L10n.Settings.updateChannelDev
        }
    }

    public var detail: String {
        switch self {
        case .main:
            return L10n.Settings.updateChannelMainDetail
        case .dev:
            return L10n.Settings.updateChannelDevDetail
        }
    }

    /// Channel names returned from `SPUUpdaterDelegate`.
    ///
    /// An empty set means Sparkle's default (Main) channel only.
    public var additionalSparkleChannels: Set<String> {
        switch self {
        case .main:
            return []
        case .dev:
            return ["dev"]
        }
    }
}
