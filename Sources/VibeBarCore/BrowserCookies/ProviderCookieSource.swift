import Foundation

/// Where a provider's cookie should come from.
///
/// `auto`   — try cached / browser auto-import / manual paste in order.
/// `manual` — only use the user-pasted `Cookie:` header.
/// `off`    — don't attempt any cookie source (forces API/OAuth modes).
public enum ProviderCookieSource: String, Codable, CaseIterable, Sendable {
    case auto
    case manual
    case off
}

/// Browsers we can import cookies from. Mirrors the set SweetCookieKit
/// supports on macOS. Used as a per-provider override for the import
/// order — defaults flow through `BrowserCookieImportOrder`.
public enum BrowserKind: String, Codable, CaseIterable, Sendable {
    case chrome
    case edge
    case brave
    case arc
    case safari
    case firefox

    public var displayName: String {
        switch self {
        case .chrome:  return "Google Chrome"
        case .edge:    return "Microsoft Edge"
        case .brave:   return "Brave"
        case .arc:     return "Arc"
        case .safari:  return "Safari"
        case .firefox: return "Firefox"
        }
    }
}
