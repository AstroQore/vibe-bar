import SwiftUI
import VibeBarCore

struct EInkScreenGroupsSettingsSection: View {
    let density: Theme.Density
    @ObservedObject var service: EInkSyncService
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var creating = false
    private var sync: EInkSyncSettings { settingsStore.settings.einkSync }
    private var available: [EInkDeviceConfig] { sync.devices.filter { sync.owningGroup(for: $0.id) == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            SettingsSectionCard(title: L10n.Settings.Eink.ScreenGroups.title, density: density) {
                Text(L10n.Settings.Eink.Workflow.groupHelp).font(.caption).foregroundStyle(.secondary)
                if !sync.apiKeyPresent { Text(L10n.Settings.Eink.needsKey).font(.caption) }
                Toggle(L10n.Settings.Eink.sync, isOn: Binding(get: { sync.syncEnabled }, set: { value in
                    var settings = settingsStore.settings; settings.einkSync.syncEnabled = value; settingsStore.settings = settings
                })).toggleStyle(.switch).disabled(!sync.apiKeyPresent)
                Button(L10n.Settings.Eink.ScreenGroups.addGroup) { creating = true }.disabled(available.count < 2)
            }
            ForEach(sync.groups) { group in
                SettingsSectionCard(title: group.name, density: density) {
                    EInkScreenGroupEditor(group: group, service: service) { value in
                        var settings = settingsStore.settings
                        guard let i = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }) else { return }
                        let imported = EInkGroupSlides.importingLayouts(value, devices: settings.einkSync.devices, layouts: settings.einkCanvasLayouts)
                        settings.einkSync.groups[i] = imported.group
                        settings.einkCanvasLayouts.merge(imported.additions) { _, new in new }
                        settingsStore.settings = settings
                    }
                    Button(L10n.Settings.Eink.Workflow.ungroup, role: .destructive) {
                        var settings = settingsStore.settings
                        settings.einkSync.groups.removeAll { $0.id == group.id }
                        settingsStore.settings = settings
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            EInkCreateGroupSheet(devices: available) { group in
                var settings = settingsStore.settings
                var group = group
                group.behavior = group.resolvedBehavior(devices: settings.einkSync.devices)
                let imported = EInkGroupSlides.importingLayouts(group, devices: settings.einkSync.devices, layouts: settings.einkCanvasLayouts)
                settings.einkSync.groups.append(imported.group)
                settings.einkCanvasLayouts.merge(imported.additions) { _, new in new }
                settingsStore.settings = settings
                creating = false
            }.vibeBarNoInitialFocus()
        }
    }
}

private struct EInkScreenGroupEditor: View {
    let group: EInkScreenGroup
    @ObservedObject var service: EInkSyncService
    var onChange: (EInkScreenGroup) -> Void
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var quotaService: QuotaService
    @State private var selectedFrameID: String?
    @State private var studioRequest: StudioRequest?
    @State private var confirmingStudioPages = false
    @State private var pendingStudioRegion: String?
    @State private var selectedScreenID: String?
    @State private var precise = false
    @State private var tapDraft = ""
    @State private var plans: [String: EInkPreviewPlan] = [:]
    @State private var invalid = false
    @State private var pushResult: String?
    @State private var previewRevision = 0
    @State private var previewPage = 0
    @State private var previewPageCount = 1

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
            sharedSettings
            slideList
            if let frame {
                DebouncedSettingsTextField(prompt: L10n.Common.name,
                    value: Binding(get: { frame.title }, set: { title in updateFrame { $0.title = title } }))
                ForEach(frame.regions) { region in regionEditor(region) }

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
        .onChange(of: selectedFrameID) { _, _ in previewPage = 0; previewRevision += 1 }
        .onChange(of: previewPage) { _, _ in previewRevision += 1 }
        .confirmationDialog(L10n.Settings.Eink.Workflow.editPages, isPresented: $confirmingStudioPages, titleVisibility: .visible, presenting: pendingStudioRegion) { id in
            Button(L10n.Settings.Eink.Workflow.materializePages) { materializeAndEdit(id) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in Text(L10n.Settings.Eink.Workflow.editPagesDetail) }
        .sheet(item: $studioRequest) { request in
            EInkGroupPageStudio(region: request.region, width: request.width, height: request.height, snapshot: request.snapshot) { slide, layout in
                var settings = settingsStore.settings
                guard let gi = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }),
                      let fi = settings.einkSync.groups[gi].frames.firstIndex(where: { $0.id == request.frameID }),
                      let ri = settings.einkSync.groups[gi].frames[fi].regions.firstIndex(where: { $0.id == request.region.id }) else { return }
                settings.einkSync.groups[gi].frames[fi].regions[ri].slide = slide
                settings.einkCanvasLayouts[EInkRenderer.layoutKey(slide.kind.layoutID!, orientation: .degrees0)] = layout
                settingsStore.settings = settings
            }.vibeBarNoInitialFocus()
        }
    }

    private struct StudioRequest: Identifiable {
        let id = UUID()
        let frameID: String
        let region: EInkScreenRegion
        let width: Int
        let height: Int
        let snapshot: EInkDataSnapshot
    }

    private func openStudio(_ region: EInkScreenRegion, in frame: EInkScreenFrame, snapshot: EInkDataSnapshot) {
        guard let bounds = group.bounds(for: region.deviceIDs, devices: devices) else { return }
        studioRequest = StudioRequest(frameID: frame.id, region: region, width: bounds.width, height: bounds.height, snapshot: snapshot)
    }

    private func editRegion(_ id: String) {
        guard let frame, let region = frame.regions.first(where: { $0.id == id }), let snapshot = service.previewSnapshot else { return }
        var owner = group; owner.frames = [frame]; owner.playbackMode = .appTimer
        if EInkPagination.frames(owner, devices: devices, snapshot: snapshot).count > 1 {
            pendingStudioRegion = id; confirmingStudioPages = true
        } else { openStudio(region, in: frame, snapshot: snapshot) }
    }

    private func materializeAndEdit(_ id: String) {
        guard let frame, let ri = frame.regions.firstIndex(where: { $0.id == id }),
              let fi = group.frames.firstIndex(where: { $0.id == frame.id }),
              let snapshot = service.previewSnapshot else { return }
        var pages = EInkPagination.materializedFrames(frame, group: group, devices: devices, snapshot: snapshot)
        let index = min(previewPage, pages.count - 1)
        if !frame.title.isEmpty {
            for i in pages.indices { pages[i].title = frame.title + " · " + String(i + 1) }
        }
        var copy = group
        copy.frames.replaceSubrange(fi...fi, with: pages)
        if copy.playbackMode == .single { copy.singleSlideID = pages[index].id }
        onChange(copy)
        selectedFrameID = pages[index].id
        previewPage = 0
        openStudio(pages[index].regions[ri], in: pages[index], snapshot: snapshot)
    }

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
                    }.disabled(group.screens.count <= 2).help(L10n.Settings.Eink.ScreenGroups.removeScreen)
                }
            }
            if let id = selectedScreenID, let device = devices.first(where: { $0.id == id }) {
                Picker(L10n.Settings.Eink.orientation, selection: Binding(get: { device.orientation }, set: { orientation in
                    var settings = settingsStore.settings
                    guard let i = settings.einkSync.devices.firstIndex(where: { $0.id == id }) else { return }
                    settings.einkSync.devices[i].orientation = orientation
                    settingsStore.settings = settings
                })) {
                    ForEach(EInkOrientation.allCases, id: \.rawValue) { orientation in
                        Text("\(orientation.rawValue)°").tag(orientation)
                    }
                }.pickerStyle(.segmented)
            }
            EInkScreenArrangementView(group: group, devices: devices, plans: plans,
                selection: $selectedScreenID, onChange: onChange)
            if previewPageCount > 1 {
                HStack {
                    Button { previewPage = max(0, previewPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(previewPage == 0)
                    Text("\(previewPage + 1) / \(previewPageCount)").monospacedDigit()
                    Button { previewPage = min(previewPageCount - 1, previewPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(previewPage == previewPageCount - 1)
                }
            }
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

    private var slideList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Eink.slides).font(.headline)
            ForEach(Array(group.frames.enumerated()), id: \.element.id) { index, value in
                HStack {
                    Button {
                        selectedFrameID = value.id
                        if group.playbackMode == .single {
                            var copy = group; copy.singleSlideID = value.id; onChange(copy)
                        }
                    } label: {
                        Text(value.title.isEmpty ? L10n.Settings.Eink.Workflow.slideNumber(number: index + 1) : value.title).fontWeight(frame?.id == value.id ? .semibold : .regular)
                    }
                    Spacer()
                    Button { moveFrame(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { moveFrame(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == group.frames.count - 1)
                    Button(L10n.Common.remove) { var copy = group; copy.frames.removeAll { $0.id == value.id }; onChange(copy) }
                }
            }
            Button(L10n.Settings.Eink.addSlide) {
                var copy = group
                let frame = EInkScreenFrame(title: "",
                    regions: group.screens.map { EInkScreenRegion(deviceIDs: [$0.deviceID], slide: defaultSlide($0.deviceID)) })
                copy.frames.append(frame)
                if copy.playbackMode == .single { copy.singleSlideID = frame.id }
                onChange(copy); selectedFrameID = frame.id
            }.disabled(group.screens.count < 2)
        }
    }

    private func regionEditor(_ region: EInkScreenRegion) -> some View {
        let bounds = group.bounds(for: region.deviceIDs, devices: devices) ?? EInkRect(x: 0, y: 0, width: 296, height: 152)
        let proxy = EInkDeviceConfig(deviceID: region.id, profile: EInkDeviceProfile(width: bounds.width, height: bounds.height), slides: [region.slide])
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(regionName(region)).font(.headline)
                Spacer()
                if region.deviceIDs.count > 1 {
                    Button(L10n.Settings.Eink.Workflow.splitSlides) {
                        updateFrame { $0 = EInkGroupSlides.splitting(region.id, in: $0) }
                    }
                }
                Menu(L10n.Settings.Eink.Workflow.mergeSlides) {
                    ForEach(frame?.regions.filter { $0.id != region.id } ?? []) { other in
                        Button(regionName(other)) {
                            updateFrame { $0 = EInkGroupSlides.merging([region.id, other.id], in: $0) }
                        }
                    }
                }.disabled((frame?.regions.count ?? 0) < 2)
            }
            EInkSlidesEditor(device: proxy, selectedSlideID: .constant(region.slide.id),
                sections: EInkFieldSection.sections(registry: quotaService.fieldRegistry), plan: nil,
                availableQuotaFieldIDs: availableFields, snapshot: service.previewSnapshot,
                showsSlideList: false, showsPreview: false, showsTitleEditor: false,
                onDeviceChange: { changed in
                    if let slide = changed.slides.first { updateRegion(region.id) { $0.slide = slide } }
                }, onOpenStudio: { _ in editRegion(region.id) })
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func regionName(_ region: EInkScreenRegion) -> String {
        region.deviceIDs.map { id in devices.first { $0.id == id }.map { $0.alias.isEmpty ? id : $0.alias } ?? id }.joined(separator: " + ")
    }

    private var availableFields: [String] {
        let live = ToolType.allCases.flatMap { tool in
            (environment.quota(for: tool)?.buckets ?? []).map { MenuBarFieldCatalog.fieldId(tool: tool, bucketId: $0.id) }
        }
        return EInkSlide.defaultQuotaFieldIDs(live: live)
    }

    private var sharedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Settings.Eink.Workflow.sharedSettings).font(.headline)
            Picker(L10n.Settings.Eink.playback, selection: Binding(get: { group.playbackMode ?? .appTimer }, set: { mode in
                var copy = group; copy.playbackMode = mode
                copy.singleSlideID = frame?.id
                onChange(copy)
            })) {
                Text(L10n.Settings.Eink.Playback.single).tag(EInkPlaybackMode.single)
                Text(L10n.Settings.Eink.Playback.appTimer).tag(EInkPlaybackMode.appTimer)
            }.pickerStyle(.segmented)
            number(L10n.Settings.Eink.secondsPerSlide, path: \.secondsPerFrame, range: 10...86400)
            number(L10n.Settings.Eink.dataRefresh, path: \.dataRefreshMinutes, range: 1...1440)
            number(L10n.Settings.Eink.batteryRefresh, path: \.batteryRefreshMinutes, range: 1...1440)
            if let device = behaviorDevice {
                Toggle(L10n.Settings.Eink.alerts, isOn: memberBinding(\.alerts.enabled, fallback: device.alerts.enabled))
                Stepper("\(L10n.Settings.Eink.alertThreshold) · \(device.alerts.thresholdPercent)%", value: memberBinding(\.alerts.thresholdPercent, fallback: device.alerts.thresholdPercent), in: 1...99)
                Text(L10n.Settings.Eink.ScreenGroups.alertDetail).font(.caption2).foregroundStyle(.secondary)
                Picker(L10n.Settings.Eink.tapLink, selection: Binding(get: {
                    switch device.tapLink { case .none: "none"; case .remoteDashboard: "remote"; case .custom: "custom" }
                }, set: { choice in
                    if case let .custom(url) = device.tapLink { tapDraft = url }
                    let value: EInkTapLink = choice == "remote" ? .remoteDashboard : (choice == "custom" ? .custom(tapDraft) : .none)
                    memberBinding(\.tapLink, fallback: device.tapLink).wrappedValue = value
                })) {
                    Text(L10n.Workbench.Filter.none).tag("none")
                    Text(L10n.Settings.Eink.TapLink.remote).tag("remote")
                    Text(L10n.Settings.Eink.TapLink.custom).tag("custom")
                }
                if case let .custom(url) = device.tapLink {
                    DebouncedSettingsTextField(prompt: L10n.Settings.Eink.tapLink, value: Binding(get: { url }, set: { value in
                        tapDraft = value
                        memberBinding(\.tapLink, fallback: device.tapLink).wrappedValue = .custom(value)
                    }))
                }
                Toggle(L10n.Settings.Eink.quietHours, isOn: memberBinding(\.quietHours.enabled, fallback: device.quietHours.enabled))
                HStack {
                    DebouncedSettingsTextField(prompt: L10n.Usage.Filters.customRangeFrom, value: memberBinding(\.quietHours.start, fallback: device.quietHours.start))
                    DebouncedSettingsTextField(prompt: L10n.Settings.Eink.QuietHours.until, value: memberBinding(\.quietHours.end, fallback: device.quietHours.end))
                }.disabled(!device.quietHours.enabled)
            }
        }
    }

    private var behaviorDevice: EInkDeviceConfig? {
        guard var device = devices.first(where: { $0.id == group.screens.first?.id }) else { return nil }
        let behavior = group.resolvedBehavior(devices: devices)
        device.alerts = behavior.alerts; device.tapLink = behavior.tapLink; device.quietHours = behavior.quietHours
        return device
    }

    private func memberBinding<T>(_ path: WritableKeyPath<EInkDeviceConfig, T>, fallback: T) -> Binding<T> {
        Binding(get: { behaviorDevice?[keyPath: path] ?? fallback }, set: { value in
            var settings = settingsStore.settings
            guard var device = behaviorDevice,
                  let index = settings.einkSync.groups.firstIndex(where: { $0.id == group.id }) else { return }
            device[keyPath: path] = value
            settings.einkSync.groups[index].behavior = EInkGroupBehavior(device: device)
            settingsStore.settings = settings
        })
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
        if included { copy = EInkGroupSlides.adding(device, to: group, devices: devices) }
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
        guard !Task.isCancelled, let frame, let snapshot = service.previewSnapshot else { plans = [:]; return }
        var selected = group; selected.frames = [frame]; selected.playbackMode = .appTimer
        let pages = EInkPagination.frames(selected, devices: devices, snapshot: snapshot)
        previewPageCount = pages.count
        previewPage = min(previewPage, max(0, pages.count - 1))
        guard let boxes = try? EInkScreenGroupRenderer.boxes(group: group, frame: pages[previewPage], devices: devices, snapshot: snapshot,
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
