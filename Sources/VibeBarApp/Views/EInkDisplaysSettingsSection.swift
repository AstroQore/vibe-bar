import AppKit
import SwiftUI
import VibeBarCore

/// Settings › E-ink Displays.
///
/// One destination, one roster: the access card, then one expandable panel per
/// display. A display is a screen on its own or a group of screens acting as
/// one, and the two are peers — same chrome, same two cards inside, same
/// controls in the same order. A group is one display with one set of
/// settings and one page list; that is the whole idea, and this file is where
/// it is kept honest.
///
/// The two cards, in the order the work happens: set the display up (which
/// way it hangs — or, for a group, how its screens are arranged — how often it
/// redraws, what it plays, when it is quiet, what a tap opens), then author
/// what it shows (slides). The chrome is the ordinary `SettingsSectionCard`
/// recipe — no glass — and only the previews and the read-back thumbnail are
/// drawn as paper, because those are the device.
///
/// Everything is drawn the way it is read: the orientation picker is four
/// upright panels in a device outline whose notch marks the hardware's top
/// edge, the read-back PNG is turned upright before it is shown, and a group's
/// screens are drawn where they hang.
///
/// Fluency notes, since this pane derives more than most:
/// - The preview plans — a device's four orientations, a group's screens —
///   are rebuilt in `onAppear` / `onChange` / `task`, never in `body`, and
///   they are what the pickers and the arrangement canvas draw too.
/// - The bucket picker's sections are cached the way
///   `MiniWindowsSettingsSection` caches them.
/// - Every free-text and numeric field goes through
///   `DebouncedSettingsTextField`; nothing here writes `AppSettings` per
///   keystroke.
/// - A collapsed roster panel does not put this view in the tree at all, so
///   nothing is assembled for a display nobody has opened.
struct EInkDisplaysSettingsSection: View {
    /// What this instance is showing: the roster, or one display's detail.
    enum Subject: Equatable {
        case roster
        case device(String)
        case group(String)
    }

    let density: Theme.Density
    @ObservedObject var service: EInkSyncService
    var subject: Subject = .roster

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    @State private var selectedSlideID: String?
    @State private var isFetchingDevices = false
    @State private var fetchStatus: String?
    @State private var isScanningLoop = false
    @State private var pushStatus: String?
    @State private var pushTask: Task<Void, Never>?
    /// The device a manual push is running for. The selection can move while
    /// it runs, and cancelling "the selected device" would then stop the wrong
    /// panel and leave the real one grinding through its retries.
    @State private var pushingDeviceID: String?
    @State private var renderImage: NSImage?
    /// The read-back raster already turned upright.
    ///
    /// Turning it is a `lockFocus` and a redraw, and a settings write fans out
    /// to every subscriber — so doing it in `body` would redraw the panel
    /// raster on the main thread every time an unrelated control moved. It is
    /// computed when the image or the orientation changes and never in `body`.
    @State private var uprightRenderImage: NSImage?
    @State private var snapshot: EInkDataSnapshot?
    @State private var previews: [Int: EInkPreviewPlan] = [:]
    @State private var pickerSections: [EInkFieldSection] = []
    /// The last custom tap address typed for a display, per display.
    ///
    /// `EInkTapLink` carries the string inside its `.custom` case, so picking
    /// None or the dashboard drops it. Keeping the draft here is what makes
    /// flipping away and back the harmless act the picker implies.
    @State private var tapLinkDrafts: [String: String] = [:]

    // Roster
    @State private var isCreatingGroup = false

    // Group detail
    /// Which region of the selected page the editor is editing. `nil` means
    /// the first one, which is what a combined page always has.
    @State private var selectedRegionID: String?
    /// The screen the arrangement canvas has selected, for its orientation
    /// picker, its coordinates and its remove button.
    @State private var selectedScreenID: String?
    @State private var isPreciseExpanded = false
    @State private var isConfirmingUngroup = false
    @State private var groupPlans: [String: EInkPreviewPlan] = [:]
    @State private var groupPreviewPage = 0
    @State private var groupPreviewPageCount = 1
    @State private var isArrangementInvalid = false
    @State private var groupRevision = 0
    @State private var studioRequest: StudioRequest?
    @State private var isConfirmingStudioPages = false
    @State private var pendingStudioPageID: String?

    private var sync: EInkSyncSettings { settingsStore.settings.einkSync }
    private var devices: [EInkDeviceConfig] { sync.devices }

    private var selectedDevice: EInkDeviceConfig? {
        guard case let .device(id) = subject else { return nil }
        return sync.device(id: id)
    }

    private var selectedGroup: EInkScreenGroup? {
        guard case let .group(id) = subject else { return nil }
        return sync.groups.first { $0.id == id }
    }

    private var selectedSlide: EInkSlide? {
        guard let device = selectedDevice else { return nil }
        if let selectedSlideID, let match = device.slide(id: selectedSlideID) { return match }
        return device.slides.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            switch subject {
            case .roster:
                roster
            case .device:
                if let device = selectedDevice {
                    deviceCard(device)
                    slidesCard(device, group: nil)
                }
            case .group:
                if let group = selectedGroup {
                    deviceCard(groupConfig(group))
                    slidesCard(slidesConfig(group), group: groupContext(group))
                }
            }
        }
        .onAppear {
            guard subject != .roster else { return }
            rebuildPickerSections()
            Task { await loadSnapshotAndPreviews() }
        }
        .onChange(of: quotaService.fieldRegistry) { _, _ in rebuildPickerSections() }
        .onChange(of: previewSignature) { _, _ in
            if selectedDevice != nil { Task { await refreshPreview() } }
        }
        .onChange(of: selectedDevice?.deviceID) { _, _ in
            guard selectedDevice != nil else { return }
            renderImage = nil
            uprightRenderImage = nil
            pushStatus = nil
            Task { await refreshDeviceStatus() }
        }
        .onChange(of: selectedDevice?.orientation) { _, _ in rebuildUprightRender() }
        .onChange(of: selectedGroup) { _, _ in groupRevision += 1 }
        .onChange(of: devices) { _, _ in if selectedGroup != nil { groupRevision += 1 } }
        .onChange(of: settingsStore.settings.einkCanvasLayouts) { _, _ in
            if selectedGroup != nil { groupRevision += 1 }
        }
        .onChange(of: selectedSlideID) { _, _ in
            guard selectedGroup != nil else { return }
            groupPreviewPage = 0
            groupRevision += 1
        }
        .onChange(of: groupPreviewPage) { _, _ in if selectedGroup != nil { groupRevision += 1 } }
        .task(id: groupRevision) {
            guard selectedGroup != nil else { return }
            await rebuildGroupPreview()
        }
        .onDisappear { cancelPush() }
    }

    // MARK: - Roster

    @ViewBuilder
    private var roster: some View {
        accessCard
        if !devices.isEmpty {
            HStack(spacing: 8) {
                Button { isCreatingGroup = true } label: {
                    Label(L10n.Settings.Eink.DeviceGroup.create, systemImage: "rectangle.3.group")
                }
                .buttonStyle(.vibeBar)
                .disabled(ungroupedDevices.count < 2)
                .help(L10n.Settings.Eink.Workflow.memberMinimum)
                Spacer(minLength: 0)
            }
            .sheet(isPresented: $isCreatingGroup) {
                EInkCreateGroupSheet(devices: ungroupedDevices, onCreate: createGroup)
                    .vibeBarNoInitialFocus()
            }
        }
        ForEach(EInkDisplayRoster.entries(sync)) { entry in
            EInkDisplayPanel(entry: entry, density: density, service: service)
        }
    }

    private var ungroupedDevices: [EInkDeviceConfig] {
        devices.filter { sync.owningGroup(for: $0.deviceID) == nil }
    }

    // MARK: - Access

    private var accessCard: some View {
        SettingsSectionCard(title: L10n.Settings.Section.einkDisplays, density: density) {
            Text(L10n.Settings.Eink.intro)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            EInkApiKeyField(mirroredPresence: sync.apiKeyPresent, onChange: { present in
                var settings = settingsStore.settings
                settings.einkSync.apiKeyPresent = present
                settingsStore.settings = settings
                // Replacing a rejected key does not move `apiKeyPresent`, so
                // the settings mirror alone would never restart the loops the
                // 401 stopped.
                service.credentialDidChange()
            })

            Divider().padding(.vertical, 2)

            Toggle(L10n.Settings.Eink.sync, isOn: syncEnabledBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!sync.apiKeyPresent)
            Text(L10n.Settings.Eink.syncDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if service.credentialInvalid {
                Text(L10n.Settings.Eink.Error.unauthorized)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: fetchDevices) {
                    Label(L10n.Settings.Eink.fetchDevices, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.vibeBar)
                .disabled(!sync.apiKeyPresent || isFetchingDevices)
                if isFetchingDevices { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
            }

            if let fetchStatus {
                Text(fetchStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !sync.apiKeyPresent {
                Text(L10n.Settings.Eink.needsKey)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if devices.isEmpty {
                Text(L10n.Settings.Eink.noDevices)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Display detail

    /// The display card, whichever kind of display this is.
    ///
    /// The controls take a value and write through `updateConfig`, so a group
    /// reaches exactly the same typed cadence fields, playback picker, alert
    /// stepper, tap link and quiet hours a screen does. Only two things differ,
    /// and both are about hardware: where a screen shows its orientation a
    /// group shows its arrangement, and only a screen has a device loop.
    private func deviceCard(_ config: EInkDeviceConfig) -> some View {
        let group = selectedGroup
        return SettingsSectionCard(title: displayTitle(config, group: group), density: density) {
            if let group {
                groupNameRow(group)
                Divider().padding(.vertical, 2)
                groupStatusStrip(group)
            } else {
                statusStrip(service.state(for: config.deviceID))
            }
            Divider().padding(.vertical, 2)

            if let group {
                arrangementControls(group)
            } else {
                orientationControls(config)
            }

            Divider().padding(.vertical, 2)

            cadenceFields(config)

            Divider().padding(.vertical, 2)

            playbackControls(config, allowsDeviceLoop: group == nil)
            if group == nil {
                loopTasks(config, state: service.state(for: config.deviceID))
            }

            Divider().padding(.vertical, 2)

            alertControls(config)

            Divider().padding(.vertical, 2)

            tapLinkControls(config)

            Divider().padding(.vertical, 2)

            quietHoursControls(config)

            Divider().padding(.vertical, 2)

            pushRow(config)
        }
    }

    private func displayTitle(_ config: EInkDeviceConfig, group: EInkScreenGroup?) -> String {
        if group != nil, config.alias.isEmpty { return L10n.Settings.Eink.DeviceGroup.title }
        return config.alias.isEmpty ? config.deviceID : config.alias
    }

    private func orientationControls(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Settings.Eink.orientation)
                .font(.caption2)
                .foregroundStyle(.secondary)
            EInkOrientationPicker(
                orientation: device.orientation,
                plans: previews,
                profile: device.profile
            ) { orientation in
                setOrientation(orientation, deviceID: device.deviceID)
            }
            // The old note explained a notch. The four schematics now draw the
            // device's blank half where it will actually be, so the shape says
            // the orientation and the caption only has to say that the panel
            // is drawn the way it is read.
            Text(L10n.Settings.Eink.uprightPreview)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line, not a five-row grid: everything here is a single word or a
    /// single time, and stacking them put the reading three hundred points
    /// away from the word that names it.
    @ViewBuilder
    private func statusStrip(_ state: EInkDeviceSyncState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                statusItem(L10n.Settings.Eink.Status.power, state.powerLabel)
                statusItem(L10n.Settings.Eink.Status.battery, state.batteryLabel)
                statusItem(L10n.Settings.Eink.Status.wifi, state.wifiLabel)
                statusItem(L10n.Settings.Eink.Status.nextRefresh, state.nextRefreshAt.map(timeLabel) ?? "")
                statusItem(L10n.Settings.Eink.Status.lastPush, state.lastPushAt.map(timeLabel) ?? "")
                Spacer(minLength: 0)
            }
            if let failure = state.lastFailure {
                Text(message(for: failure))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A group is one display, but its power and Wi-Fi are still one reading
    /// per panel — so it is the same strip, named, once per member.
    private func groupStatusStrip(_ group: EInkScreenGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(EInkDisplayRoster.members(of: group, devices: devices)) { member in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(member.alias.isEmpty ? member.deviceID : member.alias)
                        .font(.caption2.weight(.semibold))
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    statusStrip(service.state(for: member.deviceID))
                }
            }
        }
    }

    private func statusItem(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? L10n.Settings.Eink.Status.pending : value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: - Group name and membership

    private func groupNameRow(_ group: EInkScreenGroup) -> some View {
        HStack(spacing: 8) {
            Text(L10n.Settings.Eink.ScreenGroups.name)
                .font(.caption)
                .frame(width: 132, alignment: .leading)
            DebouncedSettingsTextField(
                prompt: L10n.Settings.Eink.ScreenGroups.name,
                value: Binding(
                    get: { group.name },
                    set: { value in updateConfig { $0.alias = value } }
                )
            )
            .frame(maxWidth: 240)
            .id("group-name-\(group.id)")
            Spacer(minLength: 0)
            Button(role: .destructive) { isConfirmingUngroup = true } label: {
                Label(L10n.Settings.Eink.Workflow.ungroup, systemImage: "rectangle.split.2x1")
            }
            .buttonStyle(.vibeBar)
            .confirmationDialog(
                L10n.Settings.Eink.Workflow.ungroup,
                isPresented: $isConfirmingUngroup,
                titleVisibility: .visible
            ) {
                Button(L10n.Settings.Eink.Workflow.ungroup, role: .destructive) { ungroup(group.id) }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Settings.Eink.DeviceGroup.ungroupConfirm)
            }
        }
    }

    /// Where a screen shows which way it hangs, a group shows where its
    /// screens hang: drag one, snap it to its neighbour, and the same plans
    /// the preview draws are drawn inside it.
    private func arrangementControls(_ group: EInkScreenGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.ScreenGroups.position)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(ungroupedDevices) { device in
                        Button(device.alias.isEmpty ? device.deviceID : device.alias) {
                            addScreen(device.deviceID, to: group.id)
                        }
                    }
                } label: {
                    Label(L10n.Settings.Eink.ScreenGroups.addScreen, systemImage: "plus")
                }
                .fixedSize()
                .disabled(ungroupedDevices.isEmpty)
                Menu {
                    Button(L10n.Settings.Eink.ScreenGroups.vertical) { arrange(group.id, vertical: true) }
                    Button(L10n.Settings.Eink.ScreenGroups.horizontal) { arrange(group.id, vertical: false) }
                } label: {
                    Label(L10n.Settings.Eink.ScreenGroups.position, systemImage: "rectangle.2.swap")
                }
                .fixedSize()
                if let screenID = selectedScreenID, group.screens.contains(where: { $0.deviceID == screenID }) {
                    Button { removeScreen(screenID, from: group.id) } label: {
                        Label(L10n.Settings.Eink.ScreenGroups.removeScreen, systemImage: "minus")
                    }
                    .buttonStyle(.vibeBar)
                    .disabled(group.screens.count <= 2)
                }
            }

            if let member = selectedMember(group) {
                HStack(spacing: 8) {
                    Text(L10n.Settings.Eink.orientation)
                        .font(.caption)
                        .frame(width: 132, alignment: .leading)
                    Picker(
                        L10n.Settings.Eink.orientation,
                        selection: Binding(
                            get: { member.orientation },
                            set: { orientation in
                                setOrientation(orientation, deviceID: member.deviceID)
                            }
                        )
                    ) {
                        ForEach(EInkOrientation.allCases, id: \.rawValue) { orientation in
                            Text(EInkNaming.orientation(orientation)).tag(orientation)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    Spacer(minLength: 0)
                }
            }

            EInkScreenArrangementView(
                group: group,
                devices: devices,
                plans: groupPlans,
                selection: $selectedScreenID,
                onChange: { applyGroup($0) }
            )

            if isArrangementInvalid {
                Text(L10n.Settings.Eink.ScreenGroups.invalid)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(L10n.Settings.Eink.ScreenGroups.precise, isExpanded: $isPreciseExpanded) {
                if let screenID = selectedScreenID ?? group.orderedScreenIDs.first {
                    HStack(spacing: 8) {
                        Text(screenName(screenID))
                            .font(.caption)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        coordinateField(
                            group,
                            screenID: screenID,
                            label: L10n.Settings.Eink.ScreenGroups.xPosition,
                            isHorizontal: true
                        )
                        coordinateField(
                            group,
                            screenID: screenID,
                            label: L10n.Settings.Eink.ScreenGroups.yPosition,
                            isHorizontal: false
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func coordinateField(
        _ group: EInkScreenGroup,
        screenID: String,
        label: String,
        isHorizontal: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            DebouncedSettingsTextField(
                prompt: label,
                value: Binding(
                    get: {
                        let placement = group.screens.first { $0.deviceID == screenID }
                        return AppLocale.number(isHorizontal ? (placement?.x ?? 0) : (placement?.y ?? 0))
                    },
                    set: { raw in
                        let digits = raw.filter { $0.isNumber || $0 == "-" }
                        guard let value = Int(digits) else { return }
                        updateGroup(group.id) { group in
                            guard let index = group.screens.firstIndex(where: { $0.deviceID == screenID }) else { return }
                            let clamped = min(4096, max(-4096, value))
                            if isHorizontal { group.screens[index].x = clamped } else { group.screens[index].y = clamped }
                        }
                    }
                )
            )
            .frame(width: 72)
            .id("coordinate-\(screenID)-\(isHorizontal)")
        }
    }

    private func selectedMember(_ group: EInkScreenGroup) -> EInkDeviceConfig? {
        let id = selectedScreenID ?? group.orderedScreenIDs.first
        return devices.first { $0.deviceID == id }
    }

    private func screenName(_ deviceID: String) -> String {
        guard let device = devices.first(where: { $0.deviceID == deviceID }) else { return deviceID }
        return device.alias.isEmpty ? device.deviceID : device.alias
    }

    // MARK: - Cadence

    private func cadenceFields(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Settings.Eink.cadence)
                .font(.caption2)
                .foregroundStyle(.secondary)
            cadenceRow(
                device,
                field: .dataRefreshMinutes,
                title: L10n.Settings.Eink.dataRefresh,
                unit: L10n.Settings.Eink.Unit.minutes,
                detail: L10n.Settings.Eink.dataRefreshDetail
            )
            cadenceRow(
                device,
                field: .batteryRefreshMinutes,
                title: L10n.Settings.Eink.batteryRefresh,
                unit: L10n.Settings.Eink.Unit.minutes,
                detail: L10n.Settings.Eink.batteryRefreshDetail
            )
            cadenceRow(
                device,
                field: .secondsPerSlide,
                title: L10n.Settings.Eink.secondsPerSlide,
                unit: L10n.Settings.Eink.Unit.seconds,
                detail: L10n.Settings.Eink.secondsPerSlideDetail
            )
        }
    }

    /// A typed field with a stepper beside it.
    ///
    /// Typed, because the owner's review found "every four hours" to be twelve
    /// stepper clicks and "once a day" ninety-six. `EInkCadence` decides what
    /// a typed value means — it is clamped to the field's range on commit, and
    /// the range is printed underneath so a clamp is never a surprise.
    ///
    /// Seconds per slide is shown whatever the playback mode is. Round 1 hid
    /// it behind the app carousel, so switching to "One slide" and back looked
    /// like it had thrown the number away; it is a stored field of its own now
    /// (part A) and the control follows it.
    private func cadenceRow(
        _ device: EInkDeviceConfig,
        field: EInkCadence,
        title: String,
        unit: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .frame(width: 132, alignment: .leading)
                DebouncedSettingsTextField(
                    prompt: title,
                    value: cadenceBinding(device, field: field)
                )
                .frame(width: 72)
                .id("\(device.deviceID)-\(field.rawValue)")
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Stepper(
                    title,
                    value: Binding(
                        get: { field.value(in: device) },
                        set: { value in updateConfig { field.apply(value, to: &$0) } }
                    ),
                    in: field.range,
                    step: field.step
                )
                .labelsHidden()
                Text(
                    L10n.Usage.ChartNavigator.range(
                        start: AppLocale.number(field.range.lowerBound),
                        end: AppLocale.number(field.range.upperBound)
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Playback

    private func playbackControls(_ device: EInkDeviceConfig, allowsDeviceLoop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.Settings.Eink.playback, selection: playbackModeBinding(device)) {
                Text(L10n.Settings.Eink.Playback.single).tag(EInkPlaybackMode.single)
                if allowsDeviceLoop {
                    Text(L10n.Settings.Eink.Playback.deviceLoop).tag(EInkPlaybackMode.deviceLoop)
                }
                Text(L10n.Settings.Eink.Playback.appTimer).tag(EInkPlaybackMode.appTimer)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(playbackDetail(device))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !allowsDeviceLoop {
                // The Mac is what keeps a group's screens on the same page, so
                // the device's own loop is not on offer. Saying so is cheaper
                // than leaving somebody hunting for the option they have on
                // every other panel.
                Text(L10n.Settings.Eink.DeviceGroup.playbackDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func loopTasks(_ device: EInkDeviceConfig, state: EInkDeviceSyncState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let count = state.canvasTaskCount {
                    Text(L10n.Settings.Eink.loopTasks(count: count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.Settings.Eink.loopTasksUnknown)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Button(action: { scanLoop(device.deviceID) }) {
                    Label(L10n.Settings.Eink.rescanLoop, systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.vibeBar)
                .disabled(!sync.apiKeyPresent || isScanningLoop)
                if isScanningLoop { ProgressView().controlSize(.small) }
            }
            if let count = state.canvasTaskCount, count < device.slides.count {
                Text(L10n.Settings.Eink.loopTasksShort(tasks: count, slides: device.slides.count))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.surplusTaskCount > 0 {
                Text(L10n.Settings.Eink.loopTasksSurplus(count: state.surplusTaskCount))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Alerts, tap link, quiet hours

    private func alertControls(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(
                    L10n.Settings.Eink.alerts,
                    isOn: Binding(
                        get: { device.alerts.enabled },
                        set: { value in updateConfig { $0.alerts.enabled = value } }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L10n.Settings.Eink.alertThreshold)
                    .font(.caption)
                    .foregroundStyle(device.alerts.enabled ? .primary : .secondary)
                Stepper(
                    value: Binding(
                        get: { device.alerts.thresholdPercent },
                        set: { value in updateConfig { $0.alerts.thresholdPercent = value } }
                    ),
                    in: EInkAlertConfig.minimumThresholdPercent...EInkAlertConfig.maximumThresholdPercent
                ) {
                    Text(AppLocale.percent(Double(device.alerts.thresholdPercent) / 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .disabled(!device.alerts.enabled)
                Spacer(minLength: 0)
            }
            Text(L10n.Settings.Eink.ScreenGroups.alertDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tapLinkControls(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.tapLink)
                    .font(.caption)
                    .frame(width: 132, alignment: .leading)
                Picker(L10n.Settings.Eink.tapLink, selection: tapLinkChoiceBinding(device)) {
                    Text(L10n.Workbench.Filter.none).tag(TapLinkChoice.none)
                    Text(L10n.Settings.Eink.TapLink.remote).tag(TapLinkChoice.remoteDashboard)
                    Text(L10n.Settings.Eink.TapLink.custom).tag(TapLinkChoice.custom)
                }
                .labelsHidden()
                .frame(width: 200, alignment: .leading)
                Spacer(minLength: 0)
            }
            if case .custom = device.tapLink {
                HStack(spacing: 8) {
                    Spacer().frame(width: 132)
                    DebouncedSettingsTextField(
                        prompt: L10n.Settings.Eink.TapLink.prompt,
                        value: tapLinkTextBinding(device)
                    )
                    .frame(maxWidth: 320)
                    .id("\(device.deviceID)-tapLink")
                    Spacer(minLength: 0)
                }
                if !tapLinkIsUsable(device) {
                    Text(L10n.Settings.Eink.TapLink.invalid)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if device.tapLink == .remoteDashboard, EInkRemoteDashboard.current() == nil {
                Text(L10n.Settings.Eink.TapLink.remoteMissing)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.Settings.Eink.tapLinkDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quietHoursControls(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(
                    L10n.Settings.Eink.quietHours,
                    isOn: Binding(
                        get: { device.quietHours.enabled },
                        set: { value in updateConfig { $0.quietHours.enabled = value } }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(L10n.Usage.Filters.customRangeFrom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DebouncedSettingsTextField(
                    prompt: L10n.Usage.Filters.customRangeFrom,
                    value: quietHoursBinding(device, isStart: true)
                )
                .frame(width: 72)
                .id("\(device.deviceID)-quiet-start")
                .disabled(!device.quietHours.enabled)

                Text(L10n.Settings.Eink.QuietHours.until)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DebouncedSettingsTextField(
                    prompt: L10n.Settings.Eink.QuietHours.until,
                    value: quietHoursBinding(device, isStart: false)
                )
                .frame(width: 72)
                .id("\(device.deviceID)-quiet-end")
                .disabled(!device.quietHours.enabled)
                Text(L10n.Settings.Eink.QuietHours.format)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            Text(L10n.Settings.Eink.quietHoursDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Push

    @ViewBuilder
    private func pushRow(_ device: EInkDeviceConfig) -> some View {
        let target = pushTargetID(device)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { if let target { pushNow(target) } }) {
                    Label(L10n.Settings.Eink.pushNow, systemImage: "paperplane")
                }
                .buttonStyle(.vibeBar)
                .disabled(!sync.apiKeyPresent || target == nil || isBusy)
                if isBusy {
                    ProgressView().controlSize(.small)
                    // Only for the push this pane started. A scheduled refresh
                    // also makes the device busy, and a Cancel button that
                    // stops nothing is worse than no button.
                    if pushingDeviceID != nil, pushingDeviceID == target {
                        // A slow service can hold a multi-slide push for
                        // minutes — three attempts per item, each with a 30 s
                        // timeout. The pane also cancels on the way out.
                        Button(L10n.Common.cancel) { cancelPush() }
                            .buttonStyle(.vibeBar)
                    }
                }
                Spacer(minLength: 4)
            }
            if let pushStatus {
                Text(pushStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A group has no single panel to read back — its picture is the
            // arrangement above, drawn from the same plans.
            if selectedGroup == nil {
                Text(L10n.Settings.Eink.render)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let renderImage = uprightRenderImage {
                    // The device always reports its native 296 x 152 raster, so
                    // a portrait panel comes back on its side. It is turned
                    // upright here for the same reason the preview is: the
                    // thumbnail claims to be what is on the panel, and what is
                    // on the panel is a page somebody can read.
                    let size = device.orientation.physicalFrame(device.profile)
                    EInkDeviceFrame(
                        orientation: device.orientation,
                        paperWidth: CGFloat(size.width),
                        paperHeight: CGFloat(size.height)
                    ) {
                        Image(nsImage: renderImage)
                            .resizable()
                            .interpolation(.none)
                            .antialiased(false)
                            .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                            .background(Color.white)
                    }
                    Text(L10n.Settings.Eink.renderDetail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(L10n.Settings.Eink.renderMissing)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The device a push is addressed to. A group is pushed through its first
    /// screen: the engine recognises a grouped device and runs the whole group
    /// rather than that one panel.
    private func pushTargetID(_ device: EInkDeviceConfig) -> String? {
        if let group = selectedGroup { return group.orderedScreenIDs.first }
        return device.deviceID
    }

    private var isBusy: Bool {
        if let group = selectedGroup {
            return group.screens.contains { service.isBusy($0.deviceID) }
        }
        guard let device = selectedDevice else { return false }
        return service.isBusy(device.deviceID)
    }

    // MARK: - Slides

    private func slidesCard(_ device: EInkDeviceConfig, group: EInkSlidesGroupContext?) -> some View {
        SettingsSectionCard(title: L10n.Settings.Eink.slides, density: density) {
            EInkSlidesEditor(
                device: device,
                selectedSlideID: $selectedSlideID,
                sections: pickerSections,
                plan: group == nil ? previews[device.orientation.rawValue] : nil,
                availableQuotaFieldIDs: availableQuotaFieldIDs,
                snapshot: snapshot,
                group: group
            )
        }
        .confirmationDialog(
            L10n.Settings.Eink.Workflow.editPages,
            isPresented: $isConfirmingStudioPages,
            titleVisibility: .visible,
            presenting: pendingStudioPageID
        ) { pageID in
            Button(L10n.Settings.Eink.Workflow.materializePages) { materializeAndEdit(pageID) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Settings.Eink.Workflow.editPagesDetail)
        }
        .sheet(item: $studioRequest) { request in
            EInkGroupPageStudio(
                region: request.region,
                width: request.width,
                height: request.height,
                snapshot: request.snapshot
            ) { slide, layout in
                saveStudioPage(request: request, slide: slide, layout: layout)
            }
            .vibeBarNoInitialFocus()
        }
    }

    // MARK: - Group proxies

    /// A group, read as the one display it is.
    ///
    /// Every control in the display card takes an `EInkDeviceConfig`; this is
    /// the group wearing that shape, and `updateConfig` puts a mutated one
    /// back where each field belongs. No control has to know which it has.
    private func groupConfig(_ group: EInkScreenGroup) -> EInkDeviceConfig {
        let behavior = group.resolvedBehavior(devices: devices)
        let bounds = group.bounds(for: group.orderedScreenIDs, devices: devices)
            ?? EInkRect(x: 0, y: 0, width: EInkDeviceProfile.quote0.width, height: EInkDeviceProfile.quote0.height)
        var config = EInkDeviceConfig(
            deviceID: group.id,
            alias: group.name,
            profile: EInkDeviceProfile(width: bounds.width, height: bounds.height),
            enabled: group.enabled,
            // A group's pages are authored upright on the canvas its screens
            // make; each screen's own rotation is hardware, and lives on the
            // arrangement canvas.
            orientation: .degrees0,
            playbackMode: group.playbackMode ?? .appTimer,
            secondsPerSlide: group.secondsPerFrame,
            singleSlideID: group.singleSlideID ?? "",
            alerts: behavior.alerts,
            tapLink: behavior.tapLink,
            quietHours: behavior.quietHours,
            dataRefreshMinutes: group.dataRefreshMinutes,
            batteryRefreshMinutes: group.batteryRefreshMinutes,
            slides: pageSlides(group)
        )
        if config.singleSlideID.isEmpty { config.singleSlideID = group.frames.first?.id ?? "" }
        return config
    }

    /// The same proxy, on the canvas the editor is actually drawing: a
    /// combined page has the whole group's pixels, a separate one has the
    /// screen's own — which is what makes presets, capacity and pagination
    /// adapt without a second code path.
    private func slidesConfig(_ group: EInkScreenGroup) -> EInkDeviceConfig {
        var config = groupConfig(group)
        if let frame = selectedFrame(group),
           let region = activeRegion(in: frame, group: group),
           let bounds = group.bounds(for: region.deviceIDs, devices: devices) {
            config.profile = EInkDeviceProfile(width: bounds.width, height: bounds.height)
        }
        return config
    }

    /// The group's pages as the editor's list understands them: one entry per
    /// page, carrying the template the selected screens draw.
    private func pageSlides(_ group: EInkScreenGroup) -> [EInkSlide] {
        group.frames.map { frame in
            var slide = activeRegion(in: frame, group: group)?.slide
                ?? frame.regions.first?.slide
                ?? EInkSlide.defaultQuotaSlide()
            slide.id = frame.id
            slide.title = frame.title
            return slide
        }
    }

    private func selectedFrame(_ group: EInkScreenGroup) -> EInkScreenFrame? {
        if let selectedSlideID, let match = group.frames.first(where: { $0.id == selectedSlideID }) { return match }
        return group.frames.first
    }

    /// The regions of a page, in the order the screens hang.
    private func orderedRegions(_ frame: EInkScreenFrame, group: EInkScreenGroup) -> [EInkScreenRegion] {
        let order = group.orderedScreenIDs
        return frame.regions.sorted { first, second in
            let a = first.deviceIDs.compactMap { order.firstIndex(of: $0) }.min() ?? 0
            let b = second.deviceIDs.compactMap { order.firstIndex(of: $0) }.min() ?? 0
            return a < b
        }
    }

    private func activeRegion(in frame: EInkScreenFrame, group: EInkScreenGroup) -> EInkScreenRegion? {
        if frame.id == selectedFrame(group)?.id, let selectedRegionID,
           let match = frame.regions.first(where: { $0.id == selectedRegionID }) {
            return match
        }
        return orderedRegions(frame, group: group).first
    }

    private func regionName(_ region: EInkScreenRegion, group: EInkScreenGroup) -> String {
        let order = group.orderedScreenIDs
        return region.deviceIDs
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            .map(screenName)
            .joined(separator: " + ")
    }

    /// Everything the slides editor needs to treat a group's pages as a
    /// device's slides. The handlers take the group's id and re-read it, so a
    /// closure that outlives one pass of `body` still writes to the group as
    /// it is now.
    private func groupContext(_ group: EInkScreenGroup) -> EInkSlidesGroupContext {
        let id = group.id
        let frame = selectedFrame(group)
        let regions = frame.map { orderedRegions($0, group: group) } ?? []
        let active = frame.flatMap { activeRegion(in: $0, group: group) }
        let mode = frame?.screenMode(screenIDs: group.orderedScreenIDs) ?? .separate
        return EInkSlidesGroupContext(
            screens: regions.map { .init(id: $0.id, name: regionName($0, group: group)) },
            activeScreenID: active?.id,
            mode: mode,
            allowsCustom: group.screens.count > 2 || mode == .custom,
            canSplitActive: (active?.deviceIDs.count ?? 0) > 1,
            mergeTargets: regions
                .filter { $0.id != active?.id }
                .map { .init(id: $0.id, name: regionName($0, group: group)) },
            setMode: { mode in setScreenMode(mode, groupID: id) },
            selectScreen: { regionID in selectedRegionID = regionID },
            splitActive: { splitActiveRegion(groupID: id) },
            mergeActive: { target in mergeActiveRegion(with: target, groupID: id) },
            updateSlide: { pageID, slide in updatePageSlide(pageID: pageID, slide: slide, groupID: id) },
            addPage: { addPage(groupID: id) },
            removePage: { pageID in removePage(pageID, groupID: id) },
            reorderPages: { order in reorderPages(order, groupID: id) },
            selectPage: { pageID in selectPage(pageID, groupID: id) },
            openStudio: { pageID in openStudio(pageID: pageID, groupID: id) },
            preview: AnyView(groupPreview(group))
        )
    }

    /// Every screen of the group, in its arrangement, drawing the page the
    /// editor is on — the same plans the arrangement canvas above is drawn
    /// from, read-only here.
    private func groupPreview(_ group: EInkScreenGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Settings.Eink.uprightPreview)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if groupPreviewPageCount > 1 {
                // The same arrows the standalone preview uses, for the same
                // thing: the pages one page's selection actually needs.
                HStack(spacing: 8) {
                    Button { groupPreviewPage = max(0, groupPreviewPage - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(groupPreviewPage == 0)
                    Text("\(groupPreviewPage + 1) / \(groupPreviewPageCount)").monospacedDigit()
                    Button { groupPreviewPage = min(groupPreviewPageCount - 1, groupPreviewPage + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(groupPreviewPage >= groupPreviewPageCount - 1)
                }
            }
            EInkScreenArrangementView(
                group: group,
                devices: devices,
                plans: groupPlans,
                selection: .constant(nil),
                onChange: { _ in },
                isEditable: false,
                height: 260
            )
            .frame(maxWidth: 520)
            Text(L10n.Settings.Eink.panelTextNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Group actions

    private func createGroup(_ group: EInkScreenGroup) {
        var settings = settingsStore.settings
        var group = group
        group.behavior = group.resolvedBehavior(devices: settings.einkSync.devices)
        let imported = EInkGroupSlides.importingLayouts(
            group,
            devices: settings.einkSync.devices,
            layouts: settings.einkCanvasLayouts
        )
        settings.einkSync.groups.append(imported.group)
        settings.einkCanvasLayouts.merge(imported.additions) { _, new in new }
        settingsStore.settings = settings
        isCreatingGroup = false
    }

    /// Taking a group apart drops its pages and nothing else: the screens come
    /// back to the roster with the configuration they were grouped with.
    private func ungroup(_ groupID: String) {
        var settings = settingsStore.settings
        settings.einkSync.groups.removeAll { $0.id == groupID }
        settingsStore.settings = settings
    }

    private func addScreen(_ deviceID: String, to groupID: String) {
        guard let device = devices.first(where: { $0.deviceID == deviceID }) else { return }
        updateGroup(groupID) { group in
            group = EInkGroupSlides.adding(device, to: group, devices: devices)
        }
        selectedScreenID = deviceID
    }

    private func removeScreen(_ deviceID: String, from groupID: String) {
        updateGroup(groupID) { group in
            guard group.screens.count > 2 else { return }
            group.screens.removeAll { $0.deviceID == deviceID }
            for frameIndex in group.frames.indices {
                for regionIndex in group.frames[frameIndex].regions.indices {
                    group.frames[frameIndex].regions[regionIndex].deviceIDs.removeAll { $0 == deviceID }
                }
                group.frames[frameIndex].regions.removeAll { $0.deviceIDs.isEmpty }
            }
        }
        if selectedScreenID == deviceID { selectedScreenID = nil }
    }

    private func arrange(_ groupID: String, vertical: Bool) {
        updateGroup(groupID) { group in
            var offset = 0
            for index in group.screens.indices {
                guard let device = devices.first(where: { $0.deviceID == group.screens[index].deviceID }) else { continue }
                let size = device.profile.frameSize(for: device.orientation)
                group.screens[index].x = vertical ? 0 : offset
                group.screens[index].y = vertical ? offset : 0
                offset += vertical ? size.height : size.width
            }
        }
    }

    private func applyGroup(_ updated: EInkScreenGroup) {
        updateGroup(updated.id) { group in group = updated }
    }

    private func setScreenMode(_ mode: EInkScreenMode, groupID: String) {
        updateFrame(groupID) { frame, group in
            frame = frame.settingMode(mode, screenIDs: group.orderedScreenIDs)
        }
        selectedRegionID = nil
    }

    private func splitActiveRegion(groupID: String) {
        guard let regionID = activeRegionID(groupID) else { return }
        updateFrame(groupID) { frame, _ in frame = EInkGroupSlides.splitting(regionID, in: frame) }
        selectedRegionID = nil
    }

    private func mergeActiveRegion(with target: String, groupID: String) {
        guard let regionID = activeRegionID(groupID) else { return }
        updateFrame(groupID) { frame, _ in
            frame = EInkGroupSlides.merging([regionID, target], in: frame)
        }
        selectedRegionID = regionID
    }

    private func activeRegionID(_ groupID: String) -> String? {
        guard let group = sync.groups.first(where: { $0.id == groupID }),
              let frame = selectedFrame(group) else { return nil }
        return activeRegion(in: frame, group: group)?.id
    }

    /// The template the active screens draw, written back into the page.
    ///
    /// The page's own name travels with it, because in the editor the page
    /// list row and the name field are the same control they are for a screen.
    private func updatePageSlide(pageID: String, slide: EInkSlide, groupID: String) {
        updateGroup(groupID) { group in
            guard let frameIndex = group.frames.firstIndex(where: { $0.id == pageID }) else { return }
            let regionID = activeRegion(in: group.frames[frameIndex], group: group)?.id
            guard let regionIndex = group.frames[frameIndex].regions.firstIndex(where: { $0.id == regionID })
            else { return }
            var updated = slide
            // The proxy wears the page's id so the list can select it; the
            // region's own slide id is what the renderer and the layout store
            // key on, and it stays put.
            updated.id = group.frames[frameIndex].regions[regionIndex].slide.id
            group.frames[frameIndex].regions[regionIndex].slide = updated
            group.frames[frameIndex].title = slide.title
        }
    }

    private func addPage(groupID: String) {
        guard let group = sync.groups.first(where: { $0.id == groupID }) else { return }
        let mode = selectedFrame(group)?.screenMode(screenIDs: group.orderedScreenIDs) ?? .combined
        let frame = EInkGroupSlides.newFrame(
            mode: mode == .custom ? .separate : mode,
            screenIDs: group.orderedScreenIDs,
            available: availableQuotaFieldIDs
        )
        updateGroup(groupID) { group in
            group.frames.append(frame)
            if group.playbackMode == .single { group.singleSlideID = frame.id }
        }
        selectedSlideID = frame.id
        selectedRegionID = nil
    }

    private func removePage(_ pageID: String, groupID: String) {
        updateGroup(groupID) { group in
            guard group.frames.count > 1 else { return }
            group.frames.removeAll { $0.id == pageID }
            if group.singleSlideID == pageID { group.singleSlideID = group.frames.first?.id }
        }
        if selectedSlideID == pageID {
            selectedSlideID = sync.groups.first { $0.id == groupID }?.frames.first?.id
            selectedRegionID = nil
        }
    }

    private func reorderPages(_ order: [String], groupID: String) {
        updateGroup(groupID) { group in
            let byID = Dictionary(group.frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            group.frames = order.compactMap { byID[$0] }
        }
    }

    private func selectPage(_ pageID: String, groupID: String) {
        selectedSlideID = pageID
        selectedRegionID = nil
        updateGroup(groupID) { group in
            guard group.playbackMode == .single else { return }
            group.singleSlideID = pageID
        }
    }

    // MARK: - Group Studio

    struct StudioRequest: Identifiable {
        let id = UUID()
        let groupID: String
        let pageID: String
        let region: EInkScreenRegion
        let width: Int
        let height: Int
        let snapshot: EInkDataSnapshot
    }

    /// Freeform editing of a group page needs the page to be one page.
    ///
    /// A selection that runs onto derived pages is turned into real pages
    /// first, and only on an explicit confirmation — the same bargain the
    /// standalone editor strikes.
    private func openStudio(pageID: String, groupID: String) {
        guard let group = sync.groups.first(where: { $0.id == groupID }),
              let frame = group.frames.first(where: { $0.id == pageID }),
              let region = activeRegion(in: frame, group: group),
              let snapshot = service.previewSnapshot else { return }
        var owner = group
        owner.frames = [frame]
        owner.playbackMode = .appTimer
        if EInkPagination.frames(owner, devices: devices, snapshot: snapshot).count > 1 {
            pendingStudioPageID = pageID
            isConfirmingStudioPages = true
            return
        }
        presentStudio(group: group, pageID: pageID, region: region, snapshot: snapshot)
    }

    private func materializeAndEdit(_ pageID: String) {
        guard let group = selectedGroup,
              let frame = group.frames.first(where: { $0.id == pageID }),
              let frameIndex = group.frames.firstIndex(where: { $0.id == pageID }),
              let regionID = activeRegion(in: frame, group: group)?.id,
              let snapshot = service.previewSnapshot else { return }
        var pages = EInkPagination.materializedFrames(frame, group: group, devices: devices, snapshot: snapshot)
        guard !pages.isEmpty else { return }
        let index = min(groupPreviewPage, pages.count - 1)
        for page in pages.indices {
            pages[page].title = frame.title.isEmpty
                ? L10n.Settings.Eink.Workflow.slideNumber(number: page + 1)
                : frame.title + " · " + AppLocale.number(page + 1)
        }
        let regionPosition = frame.regions.firstIndex { $0.id == regionID } ?? 0
        updateGroup(group.id) { group in
            group.frames.replaceSubrange(frameIndex...frameIndex, with: pages)
            if group.playbackMode == .single { group.singleSlideID = pages[index].id }
        }
        selectedSlideID = pages[index].id
        selectedRegionID = pages[index].regions.indices.contains(regionPosition)
            ? pages[index].regions[regionPosition].id
            : nil
        groupPreviewPage = 0
        guard let refreshed = sync.groups.first(where: { $0.id == group.id }),
              let page = refreshed.frames.first(where: { $0.id == pages[index].id }),
              let region = activeRegion(in: page, group: refreshed) else { return }
        presentStudio(group: refreshed, pageID: page.id, region: region, snapshot: snapshot)
    }

    private func presentStudio(
        group: EInkScreenGroup,
        pageID: String,
        region: EInkScreenRegion,
        snapshot: EInkDataSnapshot
    ) {
        guard let bounds = group.bounds(for: region.deviceIDs, devices: devices) else { return }
        studioRequest = StudioRequest(
            groupID: group.id,
            pageID: pageID,
            region: region,
            width: bounds.width,
            height: bounds.height,
            snapshot: snapshot
        )
    }

    private func saveStudioPage(request: StudioRequest, slide: EInkSlide, layout: EInkCanvasLayout) {
        var settings = settingsStore.settings
        guard let groupIndex = settings.einkSync.groups.firstIndex(where: { $0.id == request.groupID }),
              let frameIndex = settings.einkSync.groups[groupIndex].frames.firstIndex(where: { $0.id == request.pageID }),
              let regionIndex = settings.einkSync.groups[groupIndex].frames[frameIndex].regions
                  .firstIndex(where: { $0.id == request.region.id }),
              let layoutID = slide.kind.layoutID
        else { return }
        settings.einkSync.groups[groupIndex].frames[frameIndex].regions[regionIndex].slide = slide
        settings.einkCanvasLayouts[EInkRenderer.layoutKey(layoutID, orientation: .degrees0)] = layout
        settingsStore.settings = settings
    }

    // MARK: - Derivations (never in `body`)

    /// Everything a preview plan depends on, so `onChange` fires exactly when
    /// one of them moves and never on an unrelated settings write.
    private var previewSignature: String {
        guard let device = selectedDevice, let slide = selectedSlide else { return "" }
        return [
            device.deviceID,
            String(device.orientation.rawValue),
            slide.id,
            slide.kind.preset?.rawValue ?? slide.kind.layoutID ?? "",
            slide.quotaFieldIDs.joined(separator: ","),
            slide.usagePeriods.map(\.rawValue).joined(separator: ","),
            // The composition options are part of the picture too: a header
            // turned off or a slot renamed changes every one of the four.
            String(slide.options.hashValue),
            // The layouts themselves, not only their id: the Studio edits them
            // in another window, and a preview that kept redrawing the shape
            // it had when the pane opened would picture the wrong panel.
            String(slide.allLayouts(in: settingsStore.settings.einkCanvasLayouts).hashValue),
            snapshot?.generatedAtISO ?? ""
        ].joined(separator: "|")
    }

    private func rebuildPreviews() {
        guard let device = selectedDevice, let slide = selectedSlide, let snapshot else {
            previews = [:]
            return
        }
        var plans: [Int: EInkPreviewPlan] = [:]
        for orientation in EInkOrientation.allCases {
            plans[orientation.rawValue] = EInkPreviewPlanner.plan(
                slide: slide.fitted(to: orientation),
                orientation: orientation,
                profile: device.profile,
                snapshot: snapshot,
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        }
        previews = plans
    }

    /// The group's screens, each drawing its part of the selected page.
    ///
    /// Resolved once, on the combined canvas, and translated into each
    /// screen's viewport — the same call the engine makes, so what is on
    /// screen here is what the panels will be sent.
    private func rebuildGroupPreview() async {
        guard let group = selectedGroup else {
            groupPlans = [:]
            return
        }
        do {
            try EInkScreenGroupRenderer.validate(group, devices: devices)
            isArrangementInvalid = false
        } catch {
            isArrangementInvalid = true
        }
        await service.refreshPreviewSnapshot(
            includingFieldIDs: settingsStore.settings.einkSync.selectedQuotaFieldIDs(
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        )
        guard !Task.isCancelled else { return }
        snapshot = service.previewSnapshot
        guard let frame = selectedFrame(group), let snapshot else {
            groupPlans = [:]
            return
        }
        var selected = group
        selected.frames = [frame]
        selected.playbackMode = .appTimer
        let pages = EInkPagination.frames(selected, devices: devices, snapshot: snapshot)
        groupPreviewPageCount = max(1, pages.count)
        let index = min(groupPreviewPage, max(0, pages.count - 1))
        if index != groupPreviewPage { groupPreviewPage = index }
        guard pages.indices.contains(index),
              let boxes = try? EInkScreenGroupRenderer.boxes(
                  group: group,
                  frame: pages[index],
                  devices: devices,
                  snapshot: snapshot,
                  layouts: settingsStore.settings.einkCanvasLayouts
              )
        else {
            groupPlans = [:]
            return
        }
        var plans: [String: EInkPreviewPlan] = [:]
        for screen in group.screens {
            guard let device = devices.first(where: { $0.deviceID == screen.deviceID }) else { continue }
            let size = device.profile.frameSize(for: device.orientation)
            plans[screen.deviceID] = EInkPreviewPlan(
                boxes: boxes[screen.deviceID] ?? [],
                authoredWidth: size.width,
                authoredHeight: size.height,
                panelWidth: device.profile.width,
                panelHeight: device.profile.height,
                orientation: device.orientation
            )
        }
        groupPlans = plans
    }

    private func rebuildPickerSections() {
        pickerSections = EInkFieldSection.sections(registry: quotaService.fieldRegistry)
    }

    /// A group's first pass belongs to the `task` that watches its revision —
    /// assembling twice on open would walk the ledger for nothing.
    private func loadSnapshotAndPreviews() async {
        guard selectedDevice != nil else { return }
        await refreshPreview()
        await refreshDeviceStatus()
    }

    /// Reads the device's status, then its render.
    ///
    /// A device the user has only just fetched is disabled and has never been
    /// pushed to, so nothing has ever written its power, Wi-Fi or render URL.
    /// Without this the status line would read "Not yet" forever on exactly
    /// the panel someone is trying to set up.
    private func refreshDeviceStatus() async {
        guard let deviceID = selectedDevice?.deviceID else { return }
        _ = await service.refreshStatus(deviceID: deviceID)
        guard selectedDevice?.deviceID == deviceID else { return }
        await loadRenderImage()
    }

    /// Re-assembles the preview snapshot and redraws the plans.
    ///
    /// It re-assembles rather than reusing what is in hand because a bucket
    /// the user just ticked is not in the snapshot taken when the pane opened,
    /// and a preview that omits the row someone just asked for reads as a bug
    /// in the layout. The engine's own five-second cache keeps a run of
    /// orientation taps from walking the ledger once per tap.
    private func refreshPreview() async {
        await service.refreshPreviewSnapshot(
            includingFieldIDs: settingsStore.settings.einkSync.selectedQuotaFieldIDs(
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        )
        snapshot = service.previewSnapshot
        rebuildPreviews()
    }

    /// Fetches the read-back thumbnail for the device that was selected when
    /// the request started.
    ///
    /// The recheck matters because two clicks in quick succession start two
    /// fetches, and the first one finishing last would put panel A's render in
    /// panel B's card — a picture of the wrong device is worse than none.
    private func loadRenderImage() async {
        guard let deviceID = selectedDevice?.deviceID else { return }
        let data = await service.fetchRenderImage(deviceID: deviceID)
        guard selectedDevice?.deviceID == deviceID else { return }
        // Assigned either way. A device that stopped reporting a render, or a
        // download that failed, must not leave the previous picture up as
        // "what the panel is showing now" — that is the one thing this
        // thumbnail claims.
        renderImage = data.flatMap(NSImage.init(data:))
        rebuildUprightRender()
    }

    /// Turns the read-back raster once per (image, orientation).
    private func rebuildUprightRender() {
        guard let renderImage, let orientation = selectedDevice?.orientation else {
            uprightRenderImage = nil
            return
        }
        uprightRenderImage = renderImage.turnedUpright(for: orientation)
    }

    // MARK: - Actions

    private func fetchDevices() {
        isFetchingDevices = true
        fetchStatus = nil
        Task {
            defer { isFetchingDevices = false }
            do {
                let devices = try await service.fetchDevices()
                var settings = settingsStore.settings
                settings.einkSync.devices = EInkDeviceMerge.merge(
                    discovered: devices,
                    into: settings.einkSync.devices,
                    availableQuotaFieldIDs: availableQuotaFieldIDs
                )
                settingsStore.settings = settings
                fetchStatus = L10n.Settings.Eink.devicesFound(count: devices.count)
            } catch let error as DotDeviceError {
                fetchStatus = message(for: EInkSyncService.failure(for: error))
            } catch {
                fetchStatus = L10n.Settings.Eink.Error.network
            }
        }
    }

    private func scanLoop(_ deviceID: String) {
        isScanningLoop = true
        Task {
            defer { isScanningLoop = false }
            guard let tasks = try? await service.rescanTasks(deviceID: deviceID) else { return }
            let keys = tasks.filter(\.isCanvasAPI).map(\.key)
            updateDevice(deviceID) { $0.taskKeys = keys }
        }
    }

    /// The result line belongs to the display it was asked for. Two pushes in
    /// quick succession would otherwise race, and a line reading "pushed 2"
    /// under the wrong panel is a lie the user has no way to catch.
    private func cancelPush() {
        if let pushingDeviceID { service.cancelRun(deviceID: pushingDeviceID) }
        pushTask?.cancel()
        pushTask = nil
        pushingDeviceID = nil
    }

    private func pushNow(_ deviceID: String) {
        cancelPush()
        pushStatus = nil
        pushingDeviceID = deviceID
        // The roster reaches the engine through a 400 ms debounce, so a slide
        // or orientation edited a moment ago may not be there yet. The service
        // applies it and forces the push as one step — applying separately
        // restarts the loops, and the restarted loop's own first pass would
        // race this one into two identical panel refreshes.
        let pending = settingsStore.settings
        pushTask = Task {
            let outcome = await service.pushNow(
                deviceID: deviceID,
                applying: pending.einkSync,
                layouts: pending.einkCanvasLayouts
            )
            // Cancellation does not unwind a closure, so a cancelled push
            // would otherwise report itself as a successful one and start
            // another thumbnail fetch on its way out.
            guard !Task.isCancelled, pushingDeviceID == deviceID else { return }
            if let failure = outcome.failure {
                pushStatus = message(for: failure)
            } else {
                pushStatus = L10n.Settings.Eink.pushResult(pushed: outcome.pushed, skipped: outcome.skipped)
            }
            if selectedDevice?.deviceID == deviceID { await loadRenderImage() }
            if pushingDeviceID == deviceID { pushingDeviceID = nil }
        }
    }

    /// The buckets this account is actually returning right now.
    ///
    /// Read from the cached quotas rather than from the picker, which starts
    /// with the whole static catalog — so "known to the app" is not "on this
    /// account", and seeding from it fills a Gemini-only device's slide with
    /// five rows that never draw.
    private var availableQuotaFieldIDs: [String] {
        var live: [String] = []
        for tool in ToolType.allCases {
            guard let quota = environment.quota(for: tool) else { continue }
            for bucket in quota.buckets {
                live.append(MenuBarFieldCatalog.fieldId(tool: tool, bucketId: bucket.id))
            }
        }
        return EInkSlide.defaultQuotaFieldIDs(live: live)
    }

    // MARK: - Bindings

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.einkSync.syncEnabled },
            set: { value in
                var settings = settingsStore.settings
                settings.einkSync.syncEnabled = value
                settingsStore.settings = settings
            }
        )
    }

    private func cadenceBinding(_ device: EInkDeviceConfig, field: EInkCadence) -> Binding<String> {
        Binding(
            get: { AppLocale.number(field.value(in: device)) },
            set: { text in
                let current = field.value(in: device)
                let parsed = field.parse(text, current: current)
                guard parsed != current else { return }
                updateConfig { field.apply(parsed, to: &$0) }
            }
        )
    }

    /// The playback segmented control writes only the mode.
    ///
    /// Round 1 wrote a whole `EInkPlayback` value, which is why picking "One
    /// slide" threw the seconds away and picking a carousel put 300 back: the
    /// enum carried the seconds and the mode together. They are separate
    /// stored fields now, and this touches one of them.
    private func playbackModeBinding(_ device: EInkDeviceConfig) -> Binding<EInkPlaybackMode> {
        Binding(
            get: { device.playbackMode },
            set: { [activeSlideID = selectedSlideID ?? device.slides.first?.id] mode in
                updateConfig { current in
                    current.playbackMode = mode
                    guard mode == .single else { return }
                    // The slide the editor and the preview are showing is the
                    // one the user means; falling back to the first would send
                    // a different panel than the one on screen.
                    let chosen = activeSlideID.flatMap { id in
                        current.slides.first { $0.id == id }?.id
                    }
                    current.singleSlideID = chosen ?? current.slides.first?.id ?? ""
                }
            }
        )
    }

    enum TapLinkChoice: Hashable { case none, remoteDashboard, custom }

    private func tapLinkChoiceBinding(_ device: EInkDeviceConfig) -> Binding<TapLinkChoice> {
        Binding(
            get: {
                switch device.tapLink {
                case .none: .none
                case .remoteDashboard: .remoteDashboard
                case .custom: .custom
                }
            },
            set: { [displayID = device.deviceID] choice in
                if case let .custom(raw) = device.tapLink, !raw.isEmpty { tapLinkDrafts[displayID] = raw }
                updateConfig { current in
                    switch choice {
                    case .none: current.tapLink = .none
                    case .remoteDashboard: current.tapLink = .remoteDashboard
                    case .custom:
                        if case .custom = current.tapLink { return }
                        current.tapLink = .custom(tapLinkDrafts[displayID] ?? "")
                    }
                }
            }
        )
    }

    private func tapLinkTextBinding(_ device: EInkDeviceConfig) -> Binding<String> {
        Binding(
            get: {
                if case let .custom(raw) = device.tapLink { return raw }
                return ""
            },
            set: { [displayID = device.deviceID] value in
                tapLinkDrafts[displayID] = value
                updateConfig { current in
                    // The field commits on a 400 ms idle and on the way out of
                    // the view tree, so a keystroke followed quickly by None or
                    // the dashboard would land *after* the picker and undo it.
                    // The draft is kept either way; only the live value is
                    // guarded.
                    guard case .custom = current.tapLink else { return }
                    current.tapLink = .custom(value)
                }
            }
        )
    }

    /// Whether the typed address is one the device will actually be sent.
    /// `EInkTapLink` drops anything that is not http(s) on the way to the
    /// payload, and a field that silently sends nothing is a field that lies.
    private func tapLinkIsUsable(_ device: EInkDeviceConfig) -> Bool {
        guard case let .custom(raw) = device.tapLink else { return true }
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return device.tapLink.url(remoteDashboard: nil) != nil
    }

    private func quietHoursBinding(_ device: EInkDeviceConfig, isStart: Bool) -> Binding<String> {
        Binding(
            get: { isStart ? device.quietHours.start : device.quietHours.end },
            set: { value in
                // `EInkQuietHours.normalized` is the judge of what an HH:mm is;
                // text it refuses leaves the stored window alone rather than
                // writing a time the device would reject.
                guard let normalized = EInkQuietHours.normalized(value) else { return }
                updateConfig {
                    if isStart { $0.quietHours.start = normalized } else { $0.quietHours.end = normalized }
                }
            }
        )
    }

    // MARK: - Mutation

    /// Read-modify-write of the whole settings value, exactly as
    /// `MiniWindowsSettingsSection` does it: one write, one fan-out.
    /// Turning the panel refits every custom layout on it in the same write.
    ///
    /// Doing it here rather than lazily is what keeps the settings preview,
    /// the Studio and the device agreeing: the stored layout is the one the
    /// new orientation will be drawn from, and an element that no longer fits
    /// has already been pulled inside the panel — see
    /// `EInkCanvasLayout.fitted`.
    private func setOrientation(_ orientation: EInkOrientation, deviceID: String) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        settings.einkSync.devices[index].orientation = orientation
        let profile = settings.einkSync.devices[index].profile
        for slide in settings.einkSync.devices[index].slides {
            guard let layoutID = slide.kind.layoutID else { continue }
            let key = EInkRenderer.layoutKey(layoutID, orientation: orientation)
            guard let layout = settings.einkCanvasLayouts[key] else { continue }
            settings.einkCanvasLayouts[key] = layout.fitted(profile: profile, orientation: orientation)
        }
        settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
        settingsStore.settings = settings
    }

    /// One display, mutated through the shape every control here speaks.
    ///
    /// A screen writes straight through. A group is read as a device, mutated,
    /// and taken apart again into the fields it actually keeps — which is what
    /// lets one set of controls serve both without a second, rougher copy.
    private func updateConfig(_ mutate: (inout EInkDeviceConfig) -> Void) {
        switch subject {
        case .roster:
            return
        case let .device(id):
            updateDevice(id, mutate)
        case let .group(id):
            guard let group = sync.groups.first(where: { $0.id == id }) else { return }
            var proxy = groupConfig(group)
            mutate(&proxy)
            updateGroup(id) { group in
                group.name = proxy.alias
                group.enabled = proxy.enabled
                // The device's own loop needs one Canvas API task per slide on
                // one panel; a group's pages span panels, so the Mac drives it.
                group.playbackMode = proxy.playbackMode == .deviceLoop ? .appTimer : proxy.playbackMode
                group.singleSlideID = proxy.singleSlideID.isEmpty ? group.frames.first?.id : proxy.singleSlideID
                group.secondsPerFrame = proxy.secondsPerSlide
                group.dataRefreshMinutes = proxy.dataRefreshMinutes
                group.batteryRefreshMinutes = proxy.batteryRefreshMinutes
                var behavior = group.resolvedBehavior(devices: devices)
                behavior.alerts = proxy.alerts
                behavior.tapLink = proxy.tapLink
                behavior.quietHours = proxy.quietHours
                group.behavior = behavior
            }
        }
    }

    private func updateDevice(_ deviceID: String, _ mutate: (inout EInkDeviceConfig) -> Void) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        mutate(&settings.einkSync.devices[index])
        settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
        settingsStore.settings = settings
    }

    /// One write per group edit, with the layout fork every new region needs.
    ///
    /// `importingLayouts` is idempotent — it only forks a layout a region does
    /// not already own — so running it on every edit is what keeps a page
    /// split or merged here from rewriting the standalone layout a screen
    /// keeps for the day it leaves the group.
    private func updateGroup(_ groupID: String, _ mutate: (inout EInkScreenGroup) -> Void) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.groups.firstIndex(where: { $0.id == groupID }) else { return }
        var group = settings.einkSync.groups[index]
        mutate(&group)
        let imported = EInkGroupSlides.importingLayouts(
            group,
            devices: settings.einkSync.devices,
            layouts: settings.einkCanvasLayouts
        )
        settings.einkSync.groups[index] = imported.group
        settings.einkCanvasLayouts.merge(imported.additions) { _, new in new }
        settingsStore.settings = settings
    }

    private func updateFrame(_ groupID: String, _ edit: (inout EInkScreenFrame, EInkScreenGroup) -> Void) {
        guard let current = sync.groups.first(where: { $0.id == groupID }),
              let pageID = selectedFrame(current)?.id else { return }
        updateGroup(groupID) { group in
            guard let index = group.frames.firstIndex(where: { $0.id == pageID }) else { return }
            edit(&group.frames[index], group)
        }
    }

    // MARK: - Naming

    private func playbackDetail(_ device: EInkDeviceConfig) -> String {
        switch device.playbackMode {
        case .single: L10n.Settings.Eink.Workflow.singleSlideDetail
        case .deviceLoop: L10n.Settings.Eink.Playback.deviceLoopDetail
        case .appTimer: L10n.Settings.Eink.Playback.appTimerDetail
        }
    }

    private func message(for failure: EInkSyncFailure) -> String {
        switch failure {
        case .unauthorized: L10n.Settings.Eink.Error.unauthorized
        case .taskMissing: L10n.Settings.Eink.Error.taskMissing
        case .deviceMissing: L10n.Settings.Eink.Error.deviceMissing
        case .rateLimited: L10n.Settings.Eink.Error.rateLimited
        case .network: L10n.Settings.Eink.Error.network
        case .render: L10n.Settings.Eink.Error.render
        case .noSlides: L10n.Settings.Eink.Error.noSlides
        case .usageUnavailable: L10n.Settings.Eink.Error.usageUnavailable
        case .noTaskKeys:
            L10n.Settings.Eink.loopTasksShort(
                tasks: selectedDevice.map { service.state(for: $0.deviceID).canvasTaskCount ?? 0 } ?? 0,
                slides: selectedDevice?.slides.count ?? 0
            )
        }
    }

    private func timeLabel(_ date: Date) -> String {
        AppLocale.string(date, dateStyle: .none, timeStyle: .short)
    }
}

/// One provider's worth of quota buckets, exactly as the mini-window picker
/// groups them.
struct EInkFieldSection: Identifiable {
    let tool: ToolType
    let title: String
    var options: [MenuBarFieldOption]
    var id: String { title }

    /// The mini window's own provider sections, plus whatever the live
    /// registry has discovered since. Shared with the Studio so both pickers
    /// offer the same buckets under the same headings.
    static func sections(registry: QuotaFieldRegistry) -> [EInkFieldSection] {
        var sections = MiniWindowFieldProviderSection.all.map {
            EInkFieldSection(tool: $0.tool, title: $0.title, options: $0.fields)
        }
        for discovered in registry.fields where MenuBarFieldCatalog.field(id: discovered.id) == nil {
            guard let index = sections.firstIndex(where: { $0.tool == discovered.tool }) else { continue }
            sections[index].options.append(MenuBarFieldCatalog.option(for: discovered))
        }
        return sections.filter { !$0.options.isEmpty }
    }
}

extension NSImage {
    /// The device's own raster, turned so it reads upright.
    ///
    /// The panel always reports 296 x 152 whichever way it is hung, so a
    /// portrait device reports a picture on its side; this undoes exactly the
    /// rotation the encoder applied (`EInkOrientation.uprightImageDegrees`).
    /// Nearest-neighbour and whole right angles only, so a 1-bit panel raster
    /// comes back a 1-bit panel raster.
    func turnedUpright(for orientation: EInkOrientation) -> NSImage {
        let degrees = orientation.uprightImageDegrees
        guard degrees != 0, let source = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let turned = degrees == 180 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
        let image = NSImage(size: turned)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return self }
        context.interpolationQuality = .none
        context.translateBy(x: turned.width / 2, y: turned.height / 2)
        // CoreGraphics turns counter-clockwise and the panel raster has to be
        // turned back by the encoder's clockwise angle, so the sign flips.
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(source, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return image
    }
}
