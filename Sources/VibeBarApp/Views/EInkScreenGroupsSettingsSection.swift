import SwiftUI
import VibeBarCore

struct EInkScreenGroupsSettingsSection: View {
    let density: Theme.Density
    @ObservedObject var service: EInkSyncService
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var selectedGroupID: String?

    private var sync: EInkSyncSettings { settingsStore.settings.einkSync }
    private var selected: EInkScreenGroup? { sync.groups.first { $0.id == selectedGroupID } ?? sync.groups.first }

    var body: some View {
        SettingsSectionCard(title: L10n.Settings.Eink.ScreenGroups.title, density: density) {
            Text(L10n.Settings.Eink.ScreenGroups.intro).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(L10n.Settings.Eink.ScreenGroups.title, selection: Binding(
                    get: { selected?.id ?? "" }, set: { selectedGroupID = $0 }
                )) {
                    ForEach(sync.groups) { group in Text(group.name).tag(group.id) }
                }
                Button(L10n.Settings.Eink.ScreenGroups.addGroup) { addGroup() }
                    .disabled(sync.devices.count < 2)
            }
            if let group = selected {
                EInkScreenGroupEditor(group: group, service: service) { value in
                    var settings = settingsStore.settings
                    guard let i = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }) else { return }
                    settings.einkSync.groups[i] = value
                    settingsStore.settings = settings
                }
                .id(group.id)
                Button(L10n.Common.remove, role: .destructive) {
                    var settings = settingsStore.settings
                    settings.einkSync.groups.removeAll { $0.id == group.id }
                    settingsStore.settings = settings
                }
            }
        }
    }

    private func addGroup() {
        var settings = settingsStore.settings
        let group = EInkScreenGroup(name: L10n.Settings.Eink.ScreenGroups.title)
        settings.einkSync.groups.append(group)
        settingsStore.settings = settings
        selectedGroupID = group.id
    }
}

private struct EInkScreenGroupEditor: View {
    let group: EInkScreenGroup
    @ObservedObject var service: EInkSyncService
    var onChange: (EInkScreenGroup) -> Void
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var selectedFrameID: String?
    @State private var editingRegionID: String?
    @State private var selectedScreenID: String?
    @State private var precise = false
    @State private var plans: [String: EInkPreviewPlan] = [:]
    @State private var invalid = false
    @State private var pushResult: String?
    @State private var previewRevision = 0

    private var devices: [EInkDeviceConfig] { settingsStore.settings.einkSync.devices }
    private var frame: EInkScreenFrame? { group.frames.first { $0.id == selectedFrameID } ?? group.frames.first }
    private var bounds: EInkRect? { group.bounds(for: group.screens.map(\.deviceID), devices: devices) }
    private var busy: Bool { group.screens.contains { service.isBusy($0.deviceID) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DebouncedSettingsTextField(prompt: L10n.Settings.Eink.ScreenGroups.name, value: binding(\.name))
            Toggle(L10n.Settings.Eink.ScreenGroups.enabled, isOn: binding(\.enabled))
            Text(L10n.Settings.Eink.ScreenGroups.sharedPlayback).font(.caption).foregroundStyle(.secondary)
            arrangement
            if invalid { Text(L10n.Settings.Eink.ScreenGroups.invalid).font(.caption).foregroundStyle(.orange) }
            Divider()
            timeline
            if let frame {
                DebouncedSettingsTextField(prompt: L10n.Settings.Eink.ScreenGroups.frameName,
                    value: Binding(get: { frame.title }, set: { title in updateFrame { $0.title = title } }))
                ForEach(frame.regions) { region in regionEditor(region) }
                Button(L10n.Settings.Eink.ScreenGroups.addRegion) {
                    let used = Set(frame.regions.flatMap(\.deviceIDs))
                    guard let id = group.screens.first(where: { !used.contains($0.deviceID) })?.deviceID else { return }
                    updateFrame { $0.regions.append(EInkScreenRegion(deviceIDs: [id], slide: defaultSlide(id))) }
                }
                Text(L10n.Settings.Eink.ScreenGroups.blank).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.Settings.Eink.pushNow) {
                    guard let id = group.screens.first?.deviceID else { return }
                    Task {
                        let result = await service.pushNow(deviceID: id, applying: settingsStore.settings.einkSync,
                                                          layouts: settingsStore.settings.einkCanvasLayouts)
                        pushResult = result.errorDetail ?? (result.succeeded ? L10n.Common.done : L10n.Settings.Eink.ScreenGroups.invalid)
                    }
                }.disabled(invalid || !group.enabled || busy || group.frames.isEmpty)
                if busy { ProgressView().controlSize(.small) }
                if let pushResult { Text(pushResult).font(.caption) }
            }
        }
        .task(id: previewRevision) { await rebuildPreview() }
        .onChange(of: group) { _, _ in previewRevision += 1 }
        .onChange(of: devices) { _, _ in previewRevision += 1 }
        .onChange(of: settingsStore.settings.einkCanvasLayouts) { _, _ in previewRevision += 1 }
        .onChange(of: selectedFrameID) { _, _ in previewRevision += 1 }
        .sheet(item: Binding(get: { editingRegionID.map(RegionSelection.init) }, set: { editingRegionID = $0?.id })) { selection in
            if let region = frame?.regions.first(where: { $0.id == selection.id }),
               let size = group.bounds(for: region.deviceIDs, devices: devices) {
                EInkGroupPageStudio(region: region, width: size.width, height: size.height, snapshot: service.previewSnapshot) { slide, layout in
                    var settings = settingsStore.settings
                    guard let gi = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }),
                          let fi = settings.einkSync.groups[gi].frames.firstIndex(where: { $0.id == frame?.id }),
                          let ri = settings.einkSync.groups[gi].frames[fi].regions.firstIndex(where: { $0.id == region.id }) else { return }
                    settings.einkSync.groups[gi].frames[fi].regions[ri].slide = slide
                    settings.einkCanvasLayouts[EInkRenderer.layoutKey(slide.kind.layoutID!, orientation: .degrees0)] = layout
                    settingsStore.settings = settings
                }
            }
        }
    }

    private struct RegionSelection: Identifiable { let id: String }

    private var arrangement: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.Settings.Eink.ScreenGroups.position).font(.headline)
                Spacer()
                Menu {
                    ForEach(devices) { device in
                        let claimed = settingsStore.settings.einkSync.groups.contains { $0.screens.contains { $0.id == device.id } }
                        Button(device.alias.isEmpty ? device.id : device.alias) {
                            setMember(device, included: true)
                            selectedScreenID = device.id
                        }.disabled(claimed)
                    }
                } label: { Label(L10n.Settings.Eink.ScreenGroups.addScreen, systemImage: "plus") }
                Menu {
                    Button(L10n.Settings.Eink.ScreenGroups.vertical) { arrange(vertical: true) }
                    Button(L10n.Settings.Eink.ScreenGroups.horizontal) { arrange(vertical: false) }
                } label: { Image(systemName: "rectangle.2.swap") }
                .help(L10n.Settings.Eink.ScreenGroups.position)
                if let id = selectedScreenID, let device = devices.first(where: { $0.id == id }) {
                    Button { setMember(device, included: false); selectedScreenID = nil } label: {
                        Image(systemName: "minus")
                    }.help(L10n.Settings.Eink.ScreenGroups.removeScreen)
                }
            }
            EInkScreenArrangementView(group: group, devices: devices, plans: plans,
                selection: $selectedScreenID, onChange: onChange)
            DisclosureGroup(L10n.Settings.Eink.ScreenGroups.precise, isExpanded: $precise) {
                if let id = selectedScreenID ?? group.screens.first?.id {
                    HStack {
                        Text(devices.first { $0.id == id }?.alias ?? id).font(.caption)
                        coordinate(id, axis: \.x, label: L10n.Settings.Eink.ScreenGroups.xPosition)
                        coordinate(id, axis: \.y, label: L10n.Settings.Eink.ScreenGroups.yPosition)
                    }.padding(.top, 6)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Eink.ScreenGroups.frames).font(.headline)
            number(L10n.Settings.Eink.ScreenGroups.seconds, path: \.secondsPerFrame, range: 10...86400)
            number(L10n.Settings.Eink.dataRefresh, path: \.dataRefreshMinutes, range: 1...1440)
            number(L10n.Settings.Eink.batteryRefresh, path: \.batteryRefreshMinutes, range: 1...1440)
            ForEach(Array(group.frames.enumerated()), id: \.element.id) { index, value in
                HStack {
                    Button { selectedFrameID = value.id } label: {
                        Text("\(index + 1). \(value.title)").fontWeight(frame?.id == value.id ? .semibold : .regular)
                    }
                    Spacer()
                    Button { moveFrame(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { moveFrame(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == group.frames.count - 1)
                    Button(L10n.Common.remove) { var copy = group; copy.frames.removeAll { $0.id == value.id }; onChange(copy) }
                }
            }
            Button(L10n.Settings.Eink.ScreenGroups.addFrame) {
                var copy = group
                let frame = EInkScreenFrame(title: L10n.Settings.Eink.ScreenGroups.frameName,
                    regions: group.screens.map { EInkScreenRegion(deviceIDs: [$0.deviceID], slide: defaultSlide($0.deviceID)) })
                copy.frames.append(frame); onChange(copy); selectedFrameID = frame.id
            }.disabled(group.screens.count < 2)
        }
    }

    private func regionEditor(_ region: EInkScreenRegion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(L10n.Settings.Eink.layout, selection: Binding(get: { region.slide.kind.preset?.rawValue ?? "custom" }, set: { raw in
                    guard let preset = EInkPreset(rawValue: raw) else { return }
                    updateRegion(region.id) { $0.slide.kind = .preset(preset) }
                })) {
                    if region.slide.kind.layoutID != nil { Text(L10n.Settings.Eink.customLayout).tag("custom") }
                    ForEach(EInkPreset.allCases.filter { $0 != .alert }, id: \.rawValue) { preset in Text(EInkNaming.preset(preset)).tag(preset.rawValue) }
                }
                Button(L10n.Common.remove) { updateFrame { $0.regions.removeAll { $0.id == region.id } } }
            }
            Menu(L10n.Settings.Eink.ScreenGroups.source) {
                ForEach(devices) { device in
                    ForEach(device.slides) { slide in
                        Button("\(device.alias) · \(slide.title.isEmpty ? (slide.kind.preset.map(EInkNaming.preset) ?? L10n.Settings.Eink.customLayout) : slide.title)") {
                            updateRegion(region.id) { $0.slide = slide }
                        }
                    }
                }
            }
            Text(L10n.Settings.Eink.ScreenGroups.screens).font(.caption)
            ForEach(group.screens) { screen in
                let usedElsewhere = frame?.regions.contains { $0.id != region.id && $0.deviceIDs.contains(screen.deviceID) } ?? false
                Toggle(devices.first { $0.id == screen.deviceID }?.alias ?? screen.deviceID, isOn: Binding(
                    get: { region.deviceIDs.contains(screen.deviceID) }, set: { included in
                        updateRegion(region.id) {
                            if included { $0.deviceIDs.append(screen.deviceID) } else { $0.deviceIDs.removeAll { $0 == screen.deviceID } }
                        }
                    }
                )).disabled(usedElsewhere)
            }
            Button(L10n.Settings.Eink.ScreenGroups.edit) { editingRegionID = region.id }.disabled(region.deviceIDs.isEmpty)
        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func binding<T>(_ path: WritableKeyPath<EInkScreenGroup, T>) -> Binding<T> {
        Binding(get: { group[keyPath: path] }, set: { value in var copy = group; copy[keyPath: path] = value; onChange(copy) })
    }
    private func number(_ title: String, path: WritableKeyPath<EInkScreenGroup, Int>, range: ClosedRange<Int>) -> some View {
        HStack { Text(title); DebouncedSettingsTextField(prompt: title, value: Binding(get: { String(group[keyPath: path]) }, set: {
            guard let n = Int($0) else { return }; var copy = group; copy[keyPath: path] = min(range.upperBound, max(range.lowerBound, n)); onChange(copy)
        })).frame(width: 80) }
    }
    private func coordinate(_ id: String, axis: WritableKeyPath<EInkScreenPlacement, Int>, label: String) -> some View {
        HStack { Text(label); DebouncedSettingsTextField(prompt: label, value: Binding(get: {
            String(group.screens.first { $0.id == id }?[keyPath: axis] ?? 0)
        }, set: { raw in
            guard let n = Int(raw), let i = group.screens.firstIndex(where: { $0.id == id }) else { return }
            var copy = group; copy.screens[i][keyPath: axis] = min(4096, max(-4096, n)); onChange(copy)
        })).frame(width: 70) }
    }
    private func setMember(_ device: EInkDeviceConfig, included: Bool) {
        var copy = group
        if included { copy.screens.append(EInkScreenPlacement(deviceID: device.id, y: bounds?.maxY ?? 0)) }
        else {
            copy.screens.removeAll { $0.id == device.id }
            for fi in copy.frames.indices {
                for ri in copy.frames[fi].regions.indices { copy.frames[fi].regions[ri].deviceIDs.removeAll { $0 == device.id } }
                copy.frames[fi].regions.removeAll { $0.deviceIDs.isEmpty }
            }
        }
        onChange(copy)
    }
    private func arrange(vertical: Bool) {
        var copy = group; var offset = 0
        for i in copy.screens.indices {
            guard let device = devices.first(where: { $0.id == copy.screens[i].id }) else { continue }
            let size = device.profile.frameSize(for: device.orientation)
            copy.screens[i].x = vertical ? 0 : offset; copy.screens[i].y = vertical ? offset : 0
            offset += vertical ? size.height : size.width
        }
        onChange(copy)
    }
    private func updateFrame(_ edit: (inout EInkScreenFrame) -> Void) {
        var copy = group; guard let i = copy.frames.firstIndex(where: { $0.id == frame?.id }) else { return }
        edit(&copy.frames[i]); onChange(copy)
    }
    private func updateRegion(_ id: String, _ edit: (inout EInkScreenRegion) -> Void) {
        updateFrame { frame in guard let i = frame.regions.firstIndex(where: { $0.id == id }) else { return }; edit(&frame.regions[i]) }
    }
    private func moveFrame(_ index: Int, by offset: Int) {
        var copy = group; copy.frames.swapAt(index, index + offset); onChange(copy)
    }
    private func defaultSlide(_ id: String) -> EInkSlide {
        devices.first { $0.id == id }?.slides.first ?? EInkSlide(id: UUID().uuidString, kind: .preset(.quotaLedger))
    }
    private func rebuildPreview() async {
        do { try EInkScreenGroupRenderer.validate(group, devices: devices); invalid = false } catch { invalid = true }
        await service.refreshPreviewSnapshot(includingFieldIDs: settingsStore.settings.einkSync.selectedQuotaFieldIDs(layouts: settingsStore.settings.einkCanvasLayouts))
        guard !Task.isCancelled, let frame, let snapshot = service.previewSnapshot,
              let boxes = try? EInkScreenGroupRenderer.boxes(group: group, frame: frame, devices: devices, snapshot: snapshot,
                                                           layouts: settingsStore.settings.einkCanvasLayouts) else { plans = [:]; return }
        var next: [String: EInkPreviewPlan] = [:]
        for screen in group.screens {
            guard let device = devices.first(where: { $0.id == screen.id }) else { continue }
            let size = device.profile.frameSize(for: device.orientation)
            next[screen.id] = EInkPreviewPlan(boxes: boxes[screen.id] ?? [], authoredWidth: size.width, authoredHeight: size.height,
                                            panelWidth: device.profile.width, panelHeight: device.profile.height, orientation: device.orientation)
        }
        plans = next
    }
}
