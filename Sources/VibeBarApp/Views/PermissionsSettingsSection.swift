import AppKit
import ServiceManagement
import SwiftUI
import SweetCookieKit
import VibeBarCore

struct PermissionsSettingsSection: View {
    let density: Theme.Density
    @State private var browsers: [Browser] = []
    @State private var automation: [String: AppPermissionDiagnostics.Status] = [:]
    @State private var keychain: [String: AppPermissionDiagnostics.Status] = [:]
    @State private var loginItem: AppPermissionDiagnostics.Status = .unknown
    @State private var checking = false
    @State private var refreshGeneration = 0

    private let terminals = ["com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm"]

    var body: some View {
        SettingsSectionCard(title: L10n.Platform.Macos.Permissions.title, density: density) {
            Text(L10n.Platform.Macos.Permissions.help)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.Common.refresh) { refreshGeneration += 1 }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.Platform.Macos.Permissions.systemSettings) {
                    AppPermissionDiagnostics.openPane("")
                }
                .buttonStyle(.link)
            }
            Divider()
            HStack {
                Text(L10n.Platform.Macos.Permissions.automation).font(.caption.weight(.semibold))
                Spacer()
                Button(L10n.Platform.Macos.Permissions.automationSettings) {
                    AppPermissionDiagnostics.openPane("Privacy_Automation")
                }.buttonStyle(.link).font(.caption)
            }
            ForEach(terminals.keys.sorted(), id: \.self) { id in
                statusRow(terminals[id] ?? id, status: automation[id])
            }
            Divider()
            HStack {
                Text(L10n.Platform.Macos.Permissions.keychain).font(.caption.weight(.semibold))
                Spacer()
                Button(L10n.Platform.Macos.Permissions.openKeychain) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.link).font(.caption)
            }
            statusRow(L10n.Platform.Macos.Permissions.vault, status: keychain["vault"])
            ForEach(browsers.filter(\.usesKeychainForCookieDecryption), id: \.rawValue) { browser in
                statusRow(browser.displayName, status: keychain[browser.rawValue])
            }
            Divider()
            statusRow(L10n.Platform.Macos.Permissions.loginItems, status: loginItem)
            HStack {
                Button(L10n.Platform.Macos.Permissions.loginItemsSettings) {
                    SMAppService.openSystemSettingsLoginItems()
                }.buttonStyle(.link)
                Spacer()
            }.font(.caption)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.Platform.Macos.Permissions.fullDisk)
                Spacer()
                Text(L10n.Platform.Macos.Permissions.confirmInSettings).foregroundStyle(.secondary)
                Button(L10n.Settings.Browsers.openFullDisk) {
                    AppPermissionDiagnostics.openPane("Privacy_AllFiles")
                }.buttonStyle(.link)
            }.font(.caption)
            Divider()
            BrowserDataAccessView(browsers: browsers, compact: true)
            DisclosureGroup(L10n.Workbench.Sessions.details) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Platform.Macos.Permissions.automationHelp)
                    Text(L10n.Platform.Macos.Permissions.keychainHelp)
                    Text(L10n.Platform.Macos.Permissions.loginItemsHelp)
                    Text(L10n.Platform.Macos.Permissions.fullDiskHelp)
                    Text(L10n.Platform.Macos.Permissions.unused)
                    Text(L10n.Platform.Macos.Permissions.notRequired)
                }.foregroundStyle(.secondary)
            }.font(.caption)
        }
        .task(id: refreshGeneration) { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshGeneration += 1
        }
    }

    private func refresh() async {
        checking = true
        browsers = BrowserCookieImportPreference.available()
        loginItem = AppPermissionDiagnostics.loginItem
        let running = terminals.keys.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        let currentBrowsers = browsers
        let result = await Task.detached(priority: .utility) {
            let automation = Dictionary(uniqueKeysWithValues: running.map { ($0, AppPermissionDiagnostics.automation(bundleID: $0)) })
            var keychain = Dictionary(uniqueKeysWithValues: currentBrowsers.filter(\.usesKeychainForCookieDecryption).map {
                ($0.rawValue, AppPermissionDiagnostics.browserKeychain($0))
            })
            keychain["vault"] = AppPermissionDiagnostics.keychain(
                service: VibeBarCredentialVault.keychainService, account: VibeBarCredentialVault.keychainAccount
            )
            return (automation, keychain)
        }.value
        guard !Task.isCancelled else { return }
        automation = terminals.mapValues { _ in .targetNotRunning }.merging(result.0) { _, new in new }
        keychain = result.1
        checking = false
    }

    private func statusRow(_ title: String, status: AppPermissionDiagnostics.Status?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(label(status)).foregroundStyle(color(status))
        }
        .font(.caption)
    }

    private func color(_ status: AppPermissionDiagnostics.Status?) -> Color {
        switch status {
        case .allowed, .enabled: .green
        case .denied, .approvalNeeded: .orange
        default: .secondary
        }
    }

    private func label(_ status: AppPermissionDiagnostics.Status?) -> String {
        switch status {
        case .none: L10n.Settings.notChecked
        case .allowed: L10n.Platform.Macos.Permissions.allowed
        case .denied: L10n.Platform.Macos.Permissions.denied
        case .approvalNeeded: L10n.Platform.Macos.Permissions.needsApproval
        case .targetNotRunning: L10n.Platform.Macos.Permissions.targetNotRunning
        case .unknown: L10n.Platform.Macos.Permissions.unknown
        case .itemVisible: L10n.Platform.Macos.Permissions.itemVisible
        case .itemMissing: L10n.Platform.Macos.Permissions.itemMissing
        case .disabled: L10n.Platform.Macos.Permissions.keychainDisabled
        case .enabled: L10n.Platform.Macos.Permissions.enabled
        case .notRegistered: L10n.Platform.Macos.Permissions.notRegistered
        }
    }
}
