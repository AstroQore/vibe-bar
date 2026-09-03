import Foundation

/// Where the Sessions page sends a resume command.
///
/// `copyOnly` is a real choice rather than only a fallback: driving
/// Terminal or iTerm needs an Automation approval, and someone who would
/// rather paste the line into the terminal they already have open should
/// not have to grant one to use the feature.
public enum PreferredTerminal: String, Codable, CaseIterable, Sendable {
    case terminal
    case iterm2
    case copyOnly

    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2:   return "iTerm2"
        case .copyOnly: return L10n.Settings.terminalCopyOnly
        }
    }
}
