import Foundation
import SweetCookieKit

/// A preferred-browser ordering for a single misc provider's cookie
/// import. Adapters consult `cookieImportCandidates(using:)` to drop
/// browsers that are blocked, uninstalled, or out of cooldown before
/// asking SweetCookieKit to read.
public typealias BrowserCookieImportOrder = [Browser]

extension Array where Element == Browser {
    /// Filter to browsers that are worth attempting a cookie read
    /// against right now — installed, with profile data on disk, and
    /// not in `BrowserCookieAccessGate`'s cooldown window.
    public func cookieImportCandidates(
        using detection: BrowserDetection,
        allowKeychainPrompt: Bool = false
    ) -> [Browser] {
        let candidates = filter { browser in
            if !allowKeychainPrompt,
               KeychainAccessGate.isDisabled,
               browser.usesKeychainForCookieDecryption {
                return false
            }
            return detection.isCookieSourceAvailable(browser)
        }
        if allowKeychainPrompt {
            // Manual imports may need the login-keychain password for
            // Chromium's "Safe Storage" secret. Try non-Keychain browsers
            // freely, but cap Chromium-style attempts at one browser per
            // click so a single import cannot fan out into a stack of
            // password prompts.
            var scoped = candidates.filter { !$0.usesKeychainForCookieDecryption }
            if let firstKeychainBrowser = candidates.first(where: \.usesKeychainForCookieDecryption) {
                scoped.append(firstKeychainBrowser)
            }
            return scoped
        }
        return candidates.filter { BrowserCookieAccessGate.shouldAttempt($0) }
    }

    /// Filter to browsers with usable profile data, ignoring the
    /// access gate. Useful for "what could the user enable?" UI.
    public func browsersWithProfileData(using detection: BrowserDetection) -> [Browser] {
        filter { detection.hasUsableProfileData($0) }
    }
}

/// Map between vibe-bar's small `BrowserKind` settings enum (saved
/// in `MiscProviderSettings.preferredBrowser`) and SweetCookieKit's
/// richer `Browser` taxonomy. One vibe-bar `BrowserKind` may expand
/// into multiple SweetCookieKit channels (Chrome → Chrome / Beta /
/// Canary).
extension BrowserKind {
    public var sweetCookieKitBrowsers: [Browser] {
        switch self {
        case .chrome:  return [.chrome, .chromeBeta, .chromeCanary]
        case .edge:    return [.edge, .edgeBeta, .edgeCanary]
        case .brave:   return [.brave, .braveBeta, .braveNightly]
        case .arc:     return [.arc, .arcBeta, .arcCanary]
        case .safari:  return [.safari]
        case .firefox: return [.firefox, .zen]
        }
    }
}
