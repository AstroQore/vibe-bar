import AppKit
import SwiftUI
import SweetCookieKit
import VibeBarCore

/// The installed browsers Vibe Bar may read cookies from, each with a
/// switch. Lives in Settings › Misc Providers and in the setup assistant's
/// browser-cookies step; both edit `AppSettings.cookieImportBrowsers`.
///
/// Nothing chosen means every installed browser. Turning one off writes the
/// rest as the choice; turning the last one back on clears the choice, so a
/// user who only ever untick-and-reticks never ends up with a narrowed list
/// that happens to match the machine today and not tomorrow.
struct BrowserSelectionView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var available: [Browser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.Settings.Browsers.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.Common.refresh, action: refresh)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if available.isEmpty {
                Text(L10n.Settings.Browsers.none)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(available, id: \.rawValue) { browser in
                    Toggle(browser.displayName, isOn: binding(for: browser))
                        .font(.system(size: 12))
                }
                Text(L10n.Settings.Browsers.help)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if settingsStore.settings.cookieImportBrowsers != nil {
                    Button(L10n.Settings.Browsers.readAll) {
                        settingsStore.settings.cookieImportBrowsers = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            Divider().padding(.vertical, 4)
            BrowserDataAccessView(browsers: available)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        let detection = BrowserDetection()
        available = BrowserCookieImportPreference.available(using: detection)
    }

    private var chosen: [Browser] {
        settingsStore.settings.cookieImportBrowsers?.compactMap(Browser.init(rawValue:)) ?? available
    }

    private func binding(for browser: Browser) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(browser) },
            set: { isOn in
                var next = chosen.filter { $0 != browser }
                if isOn { next.append(browser) }
                // Back in catalogue order, so the list reads the same however
                // it was clicked together, and the whole set means no choice.
                let ordered = Browser.defaultImportOrder.filter(next.contains)
                settingsStore.settings.cookieImportBrowsers = ordered.count == available.count && !ordered.isEmpty
                    ? nil
                    : ordered.map(\.rawValue)
            }
        )
    }
}
