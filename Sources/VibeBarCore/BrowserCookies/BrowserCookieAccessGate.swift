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
    /// - a non-interactive Keychain preflight reports
    ///   `interactionRequired` (we'd prompt if we tried for real).
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

        let requiresInteraction = chromiumKeychainRequiresInteraction()
        return lock.withLock { state in
            loadIfNeeded(&state)
            if requiresInteraction {
                state.deniedUntilByBrowser[browser.rawValue] = now.addingTimeInterval(cooldownInterval)
                persist(state)
                SafeLog.info("Browser cookie access for \(browser.displayName) requires Keychain interaction; suppressing for \(Int(cooldownInterval / 60))m")
                return false
            }
            return true
        }
    }

    /// Record an explicit denial coming back from SweetCookieKit's
    /// own error path. Re-uses the same cooldown window.
    public static func recordIfNeeded(_ error: Error, now: Date = Date()) {
        guard let err = error as? BrowserCookieError else { return }
        guard case .accessDenied = err else { return }
        recordDenied(for: err.browser, now: now)
    }

    public static func recordDenied(for browser: Browser, now: Date = Date()) {
        guard browser.usesKeychainForCookieDecryption else { return }
        let blockedUntil = now.addingTimeInterval(cooldownInterval)
        lock.withLock { state in
            loadIfNeeded(&state)
            state.deniedUntilByBrowser[browser.rawValue] = blockedUntil
            persist(state)
        }
        SafeLog.info("Browser cookie access denied for \(browser.displayName); cooldown until \(blockedUntil)")
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

    private static func chromiumKeychainRequiresInteraction() -> Bool {
        for label in safeStorageLabels {
            switch KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account) {
            case .allowed:
                return false
            case .interactionRequired:
                return true
            case .notFound, .failure:
                continue
            }
        }
        return false
    }

    private static let safeStorageLabels: [(service: String, account: String)] = Browser.safeStorageLabels

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
    var usesKeychainForCookieDecryption: Bool {
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
        @unknown default:
            // Treat unknown future browsers conservatively: assume
            // they're Chromium-derived and gate them. False positive
            // here just means we run an extra preflight; false
            // negative would mean a Keychain prompt loop.
            return true
        }
    }
}
