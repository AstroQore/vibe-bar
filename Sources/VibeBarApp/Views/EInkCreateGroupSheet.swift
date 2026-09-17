import SwiftUI
import VibeBarCore

/// Making a group: which screens, what it is called, how they hang, and what
/// the first page does with them.
///
/// Four decisions, all of them reversible from the group's own panel
/// afterwards — the arrangement on its canvas, the page shape on every page's
/// Screens control. The sheet asks only what the roster cannot guess.
struct EInkCreateGroupSheet: View {
    let devices: [EInkDeviceConfig]
    let onCreate: (EInkScreenGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var name = ""
    @State private var vertical = true
    @State private var mode: EInkScreenMode = .combined

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Settings.Eink.DeviceGroup.title).font(.title2)
            Text(L10n.Settings.Eink.Workflow.groupHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L10n.Settings.Eink.ScreenGroups.name, text: $name)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(devices) { device in
                        Toggle(
                            device.alias.isEmpty ? device.deviceID : device.alias,
                            isOn: Binding(
                                get: { selected.contains(device.deviceID) },
                                set: { value in
                                    if value { selected.insert(device.deviceID) } else { selected.remove(device.deviceID) }
                                }
                            )
                        )
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 180)

            Picker(L10n.Settings.Eink.ScreenGroups.position, selection: $vertical) {
                Text(L10n.Settings.Eink.ScreenGroups.vertical).tag(true)
                Text(L10n.Settings.Eink.ScreenGroups.horizontal).tag(false)
            }
            .pickerStyle(.segmented)

            // Only the two shapes that make sense before a page exists. A
            // mixed page is a per-page decision, and the Screens control on
            // the page itself is where it is made.
            Picker(L10n.Settings.Eink.Workflow.template, selection: $mode) {
                Text(L10n.Settings.Eink.Workflow.combined).tag(EInkScreenMode.combined)
                Text(L10n.Settings.Eink.Workflow.separate).tag(EInkScreenMode.separate)
            }

            HStack {
                Text(L10n.Settings.Eink.Workflow.memberMinimum)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                Button(L10n.Settings.Eink.DeviceGroup.create) { create() }
                    .disabled(selected.count < 2)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func create() {
        let picked = devices.filter { selected.contains($0.deviceID) }
        guard picked.count >= 2 else { return }
        let fallback = picked.map { $0.alias.isEmpty ? $0.deviceID : $0.alias }.joined(separator: " + ")
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            EInkGroupSlides.create(
                name: trimmed.isEmpty ? fallback : trimmed,
                devices: picked,
                vertical: vertical,
                mode: mode
            )
        )
    }
}
