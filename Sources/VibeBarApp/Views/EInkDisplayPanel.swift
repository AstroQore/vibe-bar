import SwiftUI
import VibeBarCore

/// One row of the display roster: a screen on its own, or a group of screens
/// acting as one display.
///
/// Both wear the same chrome — chevron, name, sync switch — because to
/// everything below this line they *are* the same thing: a group is one
/// display with one set of settings and one page list. A group says so with a
/// glyph and the names of the screens behind it, and nothing else.
///
/// Collapsed panels build nothing: the detail view is only in the tree while
/// the row is open, so a roster of six screens does not assemble six previews
/// or ask six devices for their status.
struct EInkDisplayPanel: View {
    let entry: EInkDisplayRoster.Entry
    let density: Theme.Density
    @ObservedObject var service: EInkSyncService
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var expanded: Bool

    init(entry: EInkDisplayRoster.Entry, density: Theme.Density, service: EInkSyncService) {
        self.entry = entry
        self.density = density
        self.service = service
        _expanded = State(initialValue: entry.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let members {
                            // The one thing a group has to say at a glance:
                            // that it is several panels, and which ones.
                            Image(systemName: "rectangle.3.group")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(members)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Toggle(L10n.Settings.Eink.sync, isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if expanded {
                EInkDisplaysSettingsSection(density: density, service: service, subject: subject)
            }
        }
        .padding(.vertical, 8)
        .onChange(of: entry.isEnabled) { _, enabled in expanded = enabled }
    }

    private var subject: EInkDisplaysSettingsSection.Subject {
        switch entry {
        case let .device(device): .device(device.deviceID)
        case let .group(group): .group(group.id)
        }
    }

    private var title: String {
        switch entry {
        case let .device(device): device.alias.isEmpty ? device.deviceID : device.alias
        case let .group(group):
            group.name.isEmpty ? L10n.Settings.Eink.DeviceGroup.title : group.name
        }
    }

    /// The screens behind a group, so a row names what it owns without
    /// opening. A standalone screen already names itself.
    private var members: String? {
        guard case let .group(group) = entry else { return nil }
        let names = EInkDisplayRoster.memberNames(of: group, devices: settingsStore.settings.einkSync.devices)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { value in
                var settings = settingsStore.settings
                switch entry {
                case let .device(device):
                    guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == device.deviceID })
                    else { return }
                    settings.einkSync.devices[index].enabled = value
                case let .group(group):
                    guard let index = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }) else { return }
                    settings.einkSync.groups[index].enabled = value
                }
                settingsStore.settings = settings
                expanded = value
            }
        )
    }
}

extension EInkDisplayRoster.Entry {
    var isEnabled: Bool {
        switch self {
        case let .device(device): device.enabled
        case let .group(group): group.enabled
        }
    }
}
