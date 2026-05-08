import Foundation
import SweetCookieKit

/// User-facing kill switch for any Keychain access vibe-bar would
/// otherwise attempt — including SweetCookieKit's Chromium
/// "Safe Storage" decryption.
///
/// The flag is a single static so the misc-providers settings panel
/// can toggle it from anywhere in the app. Flipping it to `true`
/// also flips SweetCookieKit's own gate so cookie imports stop
/// trying to talk to Keychain at all.
///
/// Ported from codexbar `KeychainAccessGate.swift`, simplified —
/// no UserDefaults persistence yet (the toggle resets on relaunch).
public enum KeychainAccessGate {
    /// Backing storage. `nonisolated(unsafe)` matches the codexbar
    /// pattern: this is read on every Keychain attempt across many
    /// actors, but only mutated from the main actor in response to a
    /// user toggle.
    private nonisolated(unsafe) static var _isDisabled: Bool = false

    public static var isDisabled: Bool {
        get { _isDisabled }
        set {
            _isDisabled = newValue
            BrowserCookieKeychainAccessGate.isDisabled = newValue
        }
    }

    /// Re-sync SweetCookieKit's gate with our flag. Call from app
    /// startup before any cookie import runs.
    public static func bootstrap() {
        BrowserCookieKeychainAccessGate.isDisabled = _isDisabled
    }
}
