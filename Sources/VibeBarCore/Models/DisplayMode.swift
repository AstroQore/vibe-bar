import Foundation

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining
    case used

    public var label: String {
        switch self {
        case .remaining: return L10n.Settings.displayModeRemaining
        case .used: return L10n.Settings.displayModeUsed
        }
    }
}
