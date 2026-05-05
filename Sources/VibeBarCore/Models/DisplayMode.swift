import Foundation

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining
    case used

    public var label: String {
        switch self {
        case .remaining: return "Remaining"
        case .used: return "Used"
        }
    }
}
