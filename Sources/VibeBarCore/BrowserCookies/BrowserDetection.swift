import Foundation
import os.lock
import SweetCookieKit

/// Browser presence + profile heuristics.
///
/// The point of this class is to avoid waking up the Chromium "Safe
/// Storage" Keychain prompt for browsers that aren't installed or
/// don't have any profile data on disk. SweetCookieKit will happily
/// try the keychain regardless; we filter the candidate browsers
/// before handing them off.
///
/// Results are cached per `(browser, probeKind)` for ten minutes;
/// `clearCache()` is exposed for the Settings panel "Re-check
/// browsers" action.
///
/// Ported from codexbar `BrowserDetection.swift`. macOS-only — vibe
/// bar doesn't ship for Linux/iOS.
public final class BrowserDetection: Sendable {
    public static let defaultCacheTTL: TimeInterval = 60 * 10

    private let cache = OSAllocatedUnfairLock<[CacheKey: CachedResult]>(initialState: [:])
    private let homeDirectory: String
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let fileExists: @Sendable (String) -> Bool
    private let directoryContents: @Sendable (String) -> [String]?

    private struct CachedResult {
        let value: Bool
        let timestamp: Date
    }

    private enum ProbeKind: Int, Hashable {
        case appInstalled
        case usableProfileData
        case usableCookieStore
    }

    private struct CacheKey: Hashable {
        let browser: Browser
        let kind: ProbeKind
    }

    /// Default initialiser routes home through `RealHomeDirectory`
    /// so the helper still works if the sandbox is ever re-enabled.
    public init(
        homeDirectory: String = RealHomeDirectory.path,
        cacheTTL: TimeInterval = BrowserDetection.defaultCacheTTL,
        now: @escaping @Sendable () -> Date = { Date() },
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        },
        directoryContents: @escaping @Sendable (String) -> [String]? = { path in
            try? FileManager.default.contentsOfDirectory(atPath: path)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.cacheTTL = cacheTTL
        self.now = now
        self.fileExists = fileExists
        self.directoryContents = directoryContents
    }

    public func isAppInstalled(_ browser: Browser) -> Bool {
        if browser == .safari { return true }
        return cachedBool(browser: browser, kind: .appInstalled) {
            self.detectAppInstalled(for: browser)
        }
    }

    /// Should a cookie import attempt for `browser` be allowed?
    /// Stricter than `isAppInstalled` — for Chromium browsers we
    /// require an actual cookie store on disk so we don't pop a
    /// Safe-Storage Keychain prompt for an installed-but-unused app.
    public func isCookieSourceAvailable(_ browser: Browser) -> Bool {
        if browser == .safari { return true }
        if requiresProfileValidation(browser) {
            return hasUsableCookieStore(browser)
        }
        return hasUsableProfileData(browser)
    }

    public func hasUsableProfileData(_ browser: Browser) -> Bool {
        cachedBool(browser: browser, kind: .usableProfileData) {
            self.detectUsableProfileData(for: browser)
        }
    }

    private func hasUsableCookieStore(_ browser: Browser) -> Bool {
        cachedBool(browser: browser, kind: .usableCookieStore) {
            self.detectUsableCookieStore(for: browser)
        }
    }

    public func clearCache() {
        cache.withLock { $0.removeAll() }
    }

    // MARK: - Detection

    private func cachedBool(browser: Browser, kind: ProbeKind, compute: () -> Bool) -> Bool {
        let nowDate = now()
        let key = CacheKey(browser: browser, kind: kind)
        if let cached = cache.withLock({ $0[key] }) {
            if nowDate.timeIntervalSince(cached.timestamp) < cacheTTL {
                return cached.value
            }
        }
        let result = compute()
        cache.withLock { $0[key] = CachedResult(value: result, timestamp: nowDate) }
        return result
    }

    private func detectAppInstalled(for browser: Browser) -> Bool {
        for path in applicationPaths(for: browser) where fileExists(path) {
            return true
        }
        return false
    }

    private func detectUsableProfileData(for browser: Browser) -> Bool {
        guard let profilePath = profilePath(for: browser, homeDirectory: homeDirectory) else {
            return false
        }
        guard fileExists(profilePath) else { return false }
        if requiresProfileValidation(browser) {
            return hasValidProfileDirectory(for: browser, at: profilePath)
        }
        return true
    }

    private func detectUsableCookieStore(for browser: Browser) -> Bool {
        guard let profilePath = profilePath(for: browser, homeDirectory: homeDirectory) else {
            return false
        }
        guard fileExists(profilePath) else { return false }
        return hasValidCookieStore(for: browser, at: profilePath)
    }

    private func applicationPaths(for browser: Browser) -> [String] {
        let name = browser.appBundleName
        return [
            "/Applications/\(name).app",
            "\(homeDirectory)/Applications/\(name).app"
        ]
    }

    private func profilePath(for browser: Browser, homeDirectory: String) -> String? {
        if browser == .safari {
            return "\(homeDirectory)/Library/Cookies/Cookies.binarycookies"
        }
        if let relativePath = browser.chromiumProfileRelativePath {
            return "\(homeDirectory)/Library/Application Support/\(relativePath)"
        }
        if let geckoFolder = browser.geckoProfilesFolder {
            return "\(homeDirectory)/Library/Application Support/\(geckoFolder)/Profiles"
        }
        return nil
    }

    private func requiresProfileValidation(_ browser: Browser) -> Bool {
        if browser == .safari { return false }
        if browser == .helium { return false }   // Helium uses a non-standard layout.
        if browser.usesGeckoProfileStore { return true }
        if browser.usesChromiumProfileStore { return true }
        return false
    }

    private func hasValidProfileDirectory(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = directoryContents(profilePath) else { return false }
        if browser.usesGeckoProfileStore {
            return contents.contains { $0.range(of: ".default", options: [.caseInsensitive]) != nil }
        }
        return contents.contains { name in
            name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
    }

    private func hasValidCookieStore(for browser: Browser, at profilePath: String) -> Bool {
        guard let contents = directoryContents(profilePath) else { return false }
        if browser.usesGeckoProfileStore {
            for name in contents where name.range(of: ".default", options: [.caseInsensitive]) != nil {
                let cookieDB = "\(profilePath)/\(name)/cookies.sqlite"
                if fileExists(cookieDB) { return true }
            }
            return false
        }
        for name in contents where name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") {
            let legacy = "\(profilePath)/\(name)/Cookies"
            let network = "\(profilePath)/\(name)/Network/Cookies"
            if fileExists(legacy) || fileExists(network) { return true }
        }
        return false
    }
}
