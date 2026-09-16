import SwiftUI
import VibeBarCore

struct EInkCreateGroupSheet: View {
    let devices: [EInkDeviceConfig]
    let onCreate: (EInkScreenGroup) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var name = ""
    @State private var vertical = true
    @State private var template = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Settings.Eink.ScreenGroups.addGroup).font(.title2)
            Text(L10n.Settings.Eink.Workflow.groupHelp).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.Settings.Eink.ScreenGroups.name, text: $name)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(devices) { device in
                        Toggle(device.alias.isEmpty ? device.id : device.alias, isOn: Binding(
                            get: { selected.contains(device.id) },
                            set: { if $0 { selected.insert(device.id) } else { selected.remove(device.id) } }
                        )).toggleStyle(.checkbox)
                    }
                }.padding(8)
            }.frame(maxHeight: 180)
            Picker(L10n.Settings.Eink.ScreenGroups.position, selection: $vertical) {
                Text(L10n.Settings.Eink.ScreenGroups.vertical).tag(true)
                Text(L10n.Settings.Eink.ScreenGroups.horizontal).tag(false)
            }.pickerStyle(.segmented)
            Picker(L10n.Settings.Eink.Workflow.template, selection: $template) {
                Text(L10n.Settings.Eink.Workflow.separate).tag(0)
                Text(L10n.Settings.Eink.Workflow.combined).tag(1)
                Text(L10n.Settings.Eink.Workflow.mixed).tag(2).disabled(selected.count < 3)
            }
            HStack {
                Text(L10n.Settings.Eink.Workflow.memberMinimum).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                Button(L10n.Settings.Eink.ScreenGroups.addGroup) { create() }.disabled(selected.count < 2)
            }
        }.padding(24).frame(width: 520)
    }

    private func create() {
        let picked = devices.filter { selected.contains($0.id) }
        var group = EInkGroupSlides.create(name: name.isEmpty ? picked.map(\.alias).joined(separator: " + ") : name,
                                          devices: picked, vertical: vertical)
        if template != 0 {
            group.frames = group.frames.map { frame in
                let regions = template == 1 ? frame.regions : Array(frame.regions.prefix(2))
                return EInkGroupSlides.merging(Set(regions.map(\.id)), in: frame)
            }
        }
        onCreate(group)
    }
}
