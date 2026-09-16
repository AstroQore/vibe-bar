import SwiftUI
import VibeBarCore

/// Each standalone screen owns its expanded settings. Group members are
/// removed by the parent; there is never a second editor for the same owner.
struct EInkStandaloneDevicePanel: View {
    let device: EInkDeviceConfig
    let density: Theme.Density
    @ObservedObject var service: EInkSyncService
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var expanded: Bool

    init(device: EInkDeviceConfig, density: Theme.Density, service: EInkSyncService) {
        self.device = device; self.density = density; self.service = service
        _expanded = State(initialValue: device.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { expanded.toggle() } label: {
                    Label(device.alias.isEmpty ? device.id : device.alias,
                          systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.headline)
                }.buttonStyle(.plain)
                Spacer()
                Toggle(L10n.Settings.Eink.sync, isOn: Binding(get: { device.enabled }, set: { enabled in
                    var settings = settingsStore.settings
                    guard let index = settings.einkSync.devices.firstIndex(where: { $0.id == device.id }) else { return }
                    settings.einkSync.devices[index].enabled = enabled
                    settingsStore.settings = settings
                    expanded = enabled
                })).toggleStyle(.switch).controlSize(.small)
            }
            if expanded {
                EInkDisplaysSettingsSection(density: density, service: service, deviceID: device.id)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: device.enabled) { _, enabled in expanded = enabled }
    }
}
