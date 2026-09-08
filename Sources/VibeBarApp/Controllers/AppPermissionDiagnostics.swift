import AppKit
import Carbon
import ServiceManagement
import SweetCookieKit
import VibeBarCore

/// Public API checks only. No TCC database reads, consent prompts or commands
/// sent to other applications. Results describe their exact probe scope.
enum AppPermissionDiagnostics {
    enum Status: Sendable {
        case allowed, denied, approvalNeeded, targetNotRunning, unknown
        case itemVisible, itemMissing, disabled, enabled, notRegistered
    }

    static func automation(bundleID: String) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
        )
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .approvalNeeded
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .unknown
        }
    }

    static func keychain(service: String, account: String?) -> Status {
        guard !DemoMode.isEnabled else { return .unknown }
        guard !KeychainAccessGate.isDisabled else { return .disabled }
        switch KeychainAccessPreflight.checkGenericPassword(service: service, account: account) {
        case .allowed: return .itemVisible
        case .interactionRequired: return .approvalNeeded
        case .notFound: return .itemMissing
        case .failure: return .unknown
        }
    }

    static func browserKeychain(_ browser: Browser) -> Status {
        guard !DemoMode.isEnabled else { return .unknown }
        guard !KeychainAccessGate.isDisabled else { return .disabled }
        let results = browser.safeStorageLabels.map { keychain(service: $0.service, account: $0.account) }
        if results.contains(where: { if case .itemVisible = $0 { true } else { false } }) { return .itemVisible }
        if results.contains(where: { if case .approvalNeeded = $0 { true } else { false } }) { return .approvalNeeded }
        if results.contains(where: { if case .unknown = $0 { true } else { false } }) { return .unknown }
        return .itemMissing
    }

    @MainActor
    static var loginItem: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .approvalNeeded
        case .notRegistered: .notRegistered
        case .notFound: .unknown
        @unknown default: .unknown
        }
    }

    @MainActor
    static func openPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
