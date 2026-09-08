import AppKit
import Security
import SwiftUI
import SweetCookieKit
import VibeBarCore

/// Explicit, in-process checks keep macOS permission attribution on Vibe Bar.
/// Never queries TCC.db or reads/decrypts credentials to infer authorization.
struct BrowserDataAccessView: View {
    let browsers: [Browser]
    var compact = false
    @State private var results: [Browser: BrowserDataAccessProbe.Status] = [:]
    @State private var checking: Browser?
    @State private var generation = 0
    @State private var showGuidance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Browsers.permissionsTitle)
                .font(.system(size: 12, weight: .semibold))
            if !compact {
                Text(L10n.Settings.Browsers.checkHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(browsers, id: \.rawValue) { browser in
                HStack {
                    Text(browser.displayName)
                    Spacer()
                    Text(label(results[browser]))
                        .foregroundStyle(results[browser] == .denied || results[browser] == .partial ? Color.orange : .secondary)
                    if checking == browser {
                        ProgressView().controlSize(.small)
                    }
                    Button(L10n.Settings.Browsers.checkAccess) { check(browser) }
                        .disabled(checking != nil)
                }
                .font(.caption)
            }
            if compact {
                DisclosureGroup(L10n.Workbench.Sessions.details, isExpanded: $showGuidance) { guidance }
                    .font(.caption)
            } else {
                guidance
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Permissions may have changed while in Settings. An older read
            // must never overwrite the now-unknown state after returning.
            if checking == nil {
                generation += 1
                results = [:]
            }
        }
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Browsers.permissionGuide)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.Settings.Browsers.openPermissions) {
                openPrivacyPane("Privacy_FilesAndFolders")
            }
            .buttonStyle(.link)
            if usesAdHocSigning {
                Text(L10n.Settings.Browsers.signatureWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(L10n.Settings.Browsers.runningApp(path: Bundle.main.bundleURL.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            DisclosureGroup(L10n.Settings.Browsers.openFullDisk) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.Settings.Browsers.fullDiskHelp)
                    Button(L10n.Settings.Browsers.openFullDisk) {
                        openPrivacyPane("Privacy_AllFiles")
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption)
            Link(L10n.Settings.Browsers.appleNotes,
                 destination: URL(string: "https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes")!)
                .font(.caption)
        }
    }

    private func check(_ browser: Browser) {
        checking = browser
        let requestedGeneration = generation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                BrowserDataAccessProbe().check(browser)
            }.value
            if requestedGeneration == generation {
                results[browser] = result
                if result == .denied || result == .partial || result == .failed { showGuidance = true }
            }
            checking = nil
        }
    }

    private func label(_ status: BrowserDataAccessProbe.Status?) -> String {
        switch status {
        case .none: L10n.Settings.notChecked
        case .readable: L10n.Settings.Browsers.readable
        case .denied: L10n.Settings.Browsers.denied
        case .missing: L10n.Settings.Browsers.missing
        case .failed: L10n.Settings.Browsers.failed
        case .partial: L10n.Settings.Browsers.partial
        }
    }

    private var usesAdHocSigning: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let info = info as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc)
    }

    private func openPrivacyPane(_ pane: String) {
        let target = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        if !NSWorkspace.shared.open(target) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}
