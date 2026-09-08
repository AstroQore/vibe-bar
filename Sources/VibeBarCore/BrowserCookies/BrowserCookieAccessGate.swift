import Foundation
import os.lock
import SweetCookieKit

/// Per-browser cooldown that suppresses repeated Chromium "Safe
/// Storage" Keychain prompts after the user has denied one.
///
/// Without this gate, SweetCookieKit will dutifully ask Keychain for
/// the Chrome / Edge / Brave / Arc Safe Storage password every time
/// we try to read cookies. If the user clicks "Don't Allow" once,
/// macOS keeps showing the prompt on every subsequent attempt — a
/// menu-bar app that refreshes every ten minutes turns into spam.
///
/// The gate persists a denial timestamp per browser in
/// `UserDefaults` and skips access for a 6-hour window. Calls during
/// the cooldown silently return "no records" instead of touching
/// Keychain at all. Adapters call `BrowserCookieClient.vibeBarRecords(...)`
/// — defined as an extension below — to flow through the gate.
///
/// Ported from codexbar `BrowserCookieAccessGate.swift`.
public enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntilByBrowser: [String: Date] = [:]
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "vibebarBrowserCookieAccessDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6

    /// Decide whether to attempt a cookie read for `browser`. Returns
    /// `false` when:
    /// - the user disabled all Keychain access via
    ///   `KeychainAccessGate.isDisabled` and this browser needs
    ///   Keychain to decrypt cookies, or
    /// - the cooldown window from a prior denial is still active, or
    /// - a non-interactive Keychain preflight of *this browser's* Safe
    ///   Storage item reports `interactionRequired` (we'd prompt if we
    ///   tried for real), or
    /// - that item does not exist at all — there is no key to decrypt
    ///   with, so the read could only fail, and a failure that is not a
    ///   refusal must not park the browser in a denial cooldown.
    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return true }
        guard !KeychainAccessGate.isDisabled else { return false }

        let shouldCheckKeychain = lock.withLock { state in
            loadIfNeeded(&state)
            if let blockedUntil = state.deniedUntilByBrowser[browser.rawValue] {
                if blockedUntil > now {
                    return false
                }
                state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
                persist(state)
            }
            return true
        }
        guard shouldCheckKeychain else { return false }

        switch keychainPreflight(for: browser) {
        case .allowed:
            return true
        case .absent:
            return false
        case .interactionRequired:
            return lock.withLock { state in
                loadIfNeeded(&state)
                state.deniedUntilByBrowser[browser.rawValue] = now.addingTimeInterval(cooldownInterval)
                persist(state)
                SafeLog.info("Browser cookie access for \(browser.displayName) requires Keychain interaction; suppressing for \(Int(cooldownInterval / 60))m")
                return false
            }
        }
    }

    /// What a silent read of `browser`'s Safe Storage item would meet.
    enum Preflight: Equatable {
        /// The item is readable now, without a prompt.
        case allowed
        /// The item exists but reading it would prompt.
        case interactionRequired
        /// No item under any of the browser's labels: nothing to decrypt with.
        case absent
    }

    /// The Keychain lookup the preflight runs. A seam for tests, which
    /// cannot put items in the login keychain.
    nonisolated(unsafe) static var preflight: @Sendable (_ service: String, _ account: String?) -> KeychainAccessPreflight.Outcome = {
        KeychainAccessPreflight.checkGenericPassword(service: $0, account: $1)
    }

    /// Preflights the browser's own labels — Chrome's item being readable
    /// says nothing about Atlas's — falling back to every catalogued label
    /// for a channel the catalogue lists none for, the way SweetCookieKit
    /// itself resolves the key.
    static func keychainPreflight(for browser: Browser) -> Preflight {
        let own = browser.safeStorageLabels
        let labels = own.isEmpty ? Browser.safeStorageLabels : own
        var interaction = false
        for label in labels {
            switch preflight(label.service, label.account) {
            case .allowed:
                return .allowed
            case .interactionRequired:
                interaction = true
            case .notFound, .failure:
                continue
            }
        }
        return interaction ? .interactionRequired : .absent
    }

    /// Record an explicit denial coming back from SweetCookieKit's
    /// own error path. Re-uses the same cooldown window.
    ///
    /// Returns the cooldown it installed, so a caller that is classifying
    /// one import attempt can tell "this browser refused us just now" from
    /// "some browser is in a cooldown from an unrelated earlier import".
    @discardableResult
    public static func recordIfNeeded(_ error: Error, now: Date = Date()) -> Cooldown? {
        guard let err = error as? BrowserCookieError else { return nil }
        guard case .accessDenied = err else { return nil }
        return recordDenied(for: err.browser, now: now)
    }

    @discardableResult
    public static func recordDenied(for browser: Browser, now: Date = Date()) -> Cooldown? {
        guard browser.usesKeychainForCookieDecryption else { return nil }
        let blockedUntil = now.addingTimeInterval(cooldownInterval)
        lock.withLock { state in
            loadIfNeeded(&state)
            state.deniedUntilByBrowser[browser.rawValue] = blockedUntil
            persist(state)
        }
        SafeLog.info("Browser cookie access denied for \(browser.displayName); cooldown until \(blockedUntil)")
        return Cooldown(browserName: browser.displayName, until: blockedUntil)
    }

    /// One browser currently inside its denial cooldown.
    public struct Cooldown: Equatable, Sendable {
        /// Human-readable browser name, e.g. "Google Chrome".
        public let browserName: String
        public let until: Date

        public init(browserName: String, until: Date) {
            self.browserName = browserName
            self.until = until
        }
    }

    /// When `browser` may be asked for cookies again, or `nil` if it is
    /// not in a cooldown right now.
    public static func blockedUntil(_ browser: Browser, now: Date = Date()) -> Date? {
        lock.withLock { state in
            loadIfNeeded(&state)
            guard let blockedUntil = state.deniedUntilByBrowser[browser.rawValue],
                  blockedUntil > now else { return nil }
            return blockedUntil
        }
    }

    /// Every browser currently suppressed, soonest expiry first.
    ///
    /// The import UI needs this because a cooldown looks exactly like "no
    /// session found" from the outside: the gate short-circuits before
    /// touching Keychain, so the importer honestly finds nothing and used
    /// to tell the user to go sign in again — advice that could not
    /// possibly help.
    ///
    /// A cooldown on a browser that is no longer installed is left out:
    /// nothing will read that browser again, so a card saying it "declined"
    /// would only send the user looking for a browser that is not there.
    public static func activeCooldowns(now: Date = Date(), detection: BrowserDetection = BrowserDetection()) -> [Cooldown] {
        let raw: [String: Date] = lock.withLock { state in
            loadIfNeeded(&state)
            return state.deniedUntilByBrowser
        }
        return raw
            .filter { $0.value > now }
            .filter { key, _ in Browser(rawValue: key).map(detection.isAppInstalled) ?? true }
            .map { key, value in
                Cooldown(
                    browserName: Browser(rawValue: key)?.displayName ?? key,
                    until: value
                )
            }
            .sorted { $0.until < $1.until }
    }

    /// Wipe persisted denials. Exposed for the Settings panel "Reset
    /// browser-cookie cooldown" button as well as the test suite.
    public static func reset() {
        lock.withLock { state in
            state.loaded = true
            state.deniedUntilByBrowser.removeAll()
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] else {
            return
        }
        state.deniedUntilByBrowser = raw.compactMapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func persist(_ state: State) {
        let raw = state.deniedUntilByBrowser.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}

extension BrowserCookieClient {
    /// Convenience over `records(matching:in:logger:)` that consults
    /// `BrowserCookieAccessGate` first and short-circuits to an empty
    /// result if the gate vetoes the attempt. This is the entry point
    /// every misc-provider importer should use.
    public func vibeBarRecords(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        allowKeychainPrompt: Bool = false,
        logger: ((String) -> Void)? = nil
    ) throws -> [BrowserCookieStoreRecords] {
        guard allowKeychainPrompt || BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
        do {
            return try records(matching: query, in: browser, logger: logger)
        } catch {
            BrowserCookieAccessGate.recordIfNeeded(error)
            throw error
        }
    }
}

/// Vibe-bar-internal extension on SweetCookieKit's `Browser`
/// telling us whether the browser stores its cookie-decryption key
/// in the macOS Keychain (and therefore needs the access gate).
extension Browser {
    public var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia:
            return true
        default:
            // Treat unknown future browsers conservatively: assume
            // they're Chromium-derived unless their enum label clearly says
            // Firefox. False positive
            // here just means we run an extra preflight; false
            // negative would mean a Keychain prompt loop.
            return !String(describing: self).localizedCaseInsensitiveContains("firefox")
        }
    }
}
