import AppKit
import SwiftUI
import VibeBarCore

/// Settings › E-ink Displays.
///
/// Three flat cards, in the order the work happens: get in (key, devices), set
/// the device up (which way it hangs, how often it redraws, what it plays,
/// when it is quiet, what a tap opens), then author what it shows (slides).
/// The chrome is the ordinary `SettingsSectionCard` recipe — no glass — and
/// only the previews and the read-back thumbnail are drawn as paper, because
/// those are the device.
///
/// Round 2 rebuilt the middle card around one idea: **everything is drawn the
/// way it is read.** The orientation picker is four upright panels in a device
/// outline whose notch marks the hardware's top edge, the read-back PNG is
/// turned upright before it is shown, and the "every orientation" grid of
/// sideways slides is gone — it was the source of the owner's "the
/// per-orientation display looks odd".
///
/// Fluency notes, since this pane derives more than most:
/// - The preview plans (one per orientation) are rebuilt in `onAppear` /
///   `onChange`, never in `body`, and they are what the picker draws too.
/// - The bucket picker's sections are cached the way
///   `MiniWindowsSettingsSection` caches them.
/// - Every free-text and numeric field goes through
///   `DebouncedSettingsTextField`; nothing here writes `AppSettings` per
///   keystroke.
struct EInkDisplaysSettingsSection: View {
    let density: Theme.Density
    @ObservedObject var service: EInkSyncService

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var quotaService: QuotaService

    @State private var selectedDeviceID: String?
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
    @State private var snapshot: EInkDataSnapshot?
    @State private var previews: [Int: EInkPreviewPlan] = [:]
    @State private var pickerSections: [EInkFieldSection] = []
    /// The last custom tap address typed for a device, per device.
    ///
    /// `EInkTapLink` carries the string inside its `.custom` case, so picking
    /// None or the dashboard drops it. Keeping the draft here is what makes
    /// flipping away and back the harmless act the picker implies.
    @State private var tapLinkDrafts: [String: String] = [:]

    private var sync: EInkSyncSettings { settingsStore.settings.einkSync }

    private var selectedDevice: EInkDeviceConfig? {
        if let selectedDeviceID, let match = sync.device(id: selectedDeviceID) { return match }
        return sync.devices.first
    }

    private var selectedSlide: EInkSlide? {
        guard let device = selectedDevice else { return nil }
        if let selectedSlideID, let match = device.slide(id: selectedSlideID) { return match }
        return device.slides.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.interSectionSpacing) {
            accessCard
            if let device = selectedDevice {
                deviceCard(device)
                slidesCard(device)
            }
        }
        .onAppear {
            rebuildPickerSections()
            Task { await loadSnapshotAndPreviews() }
        }
        .onChange(of: quotaService.fieldRegistry) { _, _ in rebuildPickerSections() }
        .onChange(of: previewSignature) { _, _ in
            Task { await refreshPreview() }
        }
        .onChange(of: selectedDevice?.deviceID) { _, _ in
            renderImage = nil
            pushStatus = nil
            Task { await refreshDeviceStatus() }
        }
        .onDisappear { cancelPush() }
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

            if sync.devices.isEmpty {
                Text(L10n.Settings.Eink.noDevices)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                deviceChips
            }
        }
    }

    private var deviceChips: some View {
        HStack(spacing: 6) {
            ForEach(sync.devices) { device in
                deviceChip(device)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func deviceChip(_ device: EInkDeviceConfig) -> some View {
        let isSelected = selectedDevice?.deviceID == device.deviceID
        return HStack(spacing: 6) {
            Button {
                selectedDeviceID = device.deviceID
                selectedSlideID = device.slides.first?.id
            } label: {
                Text(device.alias.isEmpty ? device.deviceID : device.alias)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .buttonStyle(.vibeBar(cornerRadius: 12))

            Toggle("", isOn: deviceEnabledBinding(device.deviceID))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(L10n.Settings.Eink.deviceSyncHelp)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(isSelected ? 0.34 : 0), lineWidth: 0.7)
        )
    }

    // MARK: - Device detail

    private func deviceCard(_ device: EInkDeviceConfig) -> some View {
        let state = service.state(for: device.deviceID)
        return SettingsSectionCard(
            title: device.alias.isEmpty ? device.deviceID : device.alias,
            density: density
        ) {
            statusStrip(state)
            Divider().padding(.vertical, 2)

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
            Text(L10n.Settings.Eink.orientationNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            cadenceFields(device)

            Divider().padding(.vertical, 2)

            playbackControls(device)
            loopTasks(device, state: state)

            Divider().padding(.vertical, 2)

            alertControls(device)

            Divider().padding(.vertical, 2)

            tapLinkControls(device)

            Divider().padding(.vertical, 2)

            quietHoursControls(device)

            Divider().padding(.vertical, 2)

            pushRow(device)
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
                        set: { [deviceID = device.deviceID] value in
                            updateDevice(deviceID) { field.apply(value, to: &$0) }
                        }
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

    private func playbackControls(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.Settings.Eink.playback, selection: playbackModeBinding(device)) {
                Text(L10n.Settings.Eink.Playback.single).tag(EInkPlaybackMode.single)
                Text(L10n.Settings.Eink.Playback.deviceLoop).tag(EInkPlaybackMode.deviceLoop)
                Text(L10n.Settings.Eink.Playback.appTimer).tag(EInkPlaybackMode.appTimer)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(playbackDetail(device))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        set: { [deviceID = device.deviceID] value in
                            updateDevice(deviceID) { $0.alerts.enabled = value }
                        }
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
                        set: { [deviceID = device.deviceID] value in
                            updateDevice(deviceID) { $0.alerts.thresholdPercent = value }
                        }
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
            Text(L10n.Settings.Eink.alertsDetail)
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
                        set: { [deviceID = device.deviceID] value in
                            updateDevice(deviceID) { $0.quietHours.enabled = value }
                        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { pushNow(device.deviceID) }) {
                    Label(L10n.Settings.Eink.pushNow, systemImage: "paperplane")
                }
                .buttonStyle(.vibeBar)
                .disabled(!sync.apiKeyPresent || service.isBusy(device.deviceID))
                if service.isBusy(device.deviceID) {
                    ProgressView().controlSize(.small)
                    // Only for the push this pane started. A scheduled refresh
                    // also makes the device busy, and a Cancel button that
                    // stops nothing is worse than no button.
                    if pushingDeviceID == device.deviceID {
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

            Text(L10n.Settings.Eink.render)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let renderImage {
                // The device always reports its native 296 x 152 raster, so a
                // portrait panel comes back on its side. It is turned upright
                // here for the same reason the preview is: the thumbnail
                // claims to be what is on the panel, and what is on the panel
                // is a page somebody can read.
                let size = device.orientation.physicalFrame(device.profile)
                EInkDeviceFrame(
                    orientation: device.orientation,
                    paperWidth: CGFloat(size.width),
                    paperHeight: CGFloat(size.height)
                ) {
                    Image(nsImage: renderImage.turnedUpright(for: device.orientation))
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

    // MARK: - Slides

    private func slidesCard(_ device: EInkDeviceConfig) -> some View {
        SettingsSectionCard(title: L10n.Settings.Eink.slides, density: density) {
            EInkSlidesEditor(
                device: device,
                selectedSlideID: $selectedSlideID,
                sections: pickerSections,
                plan: previews[device.orientation.rawValue],
                availableQuotaFieldIDs: availableQuotaFieldIDs
            )
        }
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

    private func rebuildPickerSections() {
        pickerSections = EInkFieldSection.sections(registry: quotaService.fieldRegistry)
    }

    private func loadSnapshotAndPreviews() async {
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
                if selectedDeviceID == nil { selectedDeviceID = devices.first?.id }
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

    /// The result line belongs to the device it was asked for. Two pushes in
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
            guard !Task.isCancelled, selectedDevice?.deviceID == deviceID else { return }
            if let failure = outcome.failure {
                pushStatus = message(for: failure)
            } else {
                pushStatus = L10n.Settings.Eink.pushResult(pushed: outcome.pushed, skipped: outcome.skipped)
            }
            await loadRenderImage()
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

    private func deviceEnabledBinding(_ deviceID: String) -> Binding<Bool> {
        Binding(
            get: { sync.device(id: deviceID)?.enabled ?? false },
            set: { value in updateDevice(deviceID) { $0.enabled = value } }
        )
    }

    private func cadenceBinding(_ device: EInkDeviceConfig, field: EInkCadence) -> Binding<String> {
        Binding(
            get: { AppLocale.number(field.value(in: device)) },
            set: { [deviceID = device.deviceID] text in
                let current = field.value(in: device)
                let parsed = field.parse(text, current: current)
                guard parsed != current else { return }
                updateDevice(deviceID) { field.apply(parsed, to: &$0) }
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
            set: { [deviceID = device.deviceID, activeSlideID = selectedSlide?.id] mode in
                updateDevice(deviceID) { current in
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
            set: { [deviceID = device.deviceID] choice in
                if case let .custom(raw) = device.tapLink, !raw.isEmpty { tapLinkDrafts[deviceID] = raw }
                updateDevice(deviceID) { current in
                    switch choice {
                    case .none: current.tapLink = .none
                    case .remoteDashboard: current.tapLink = .remoteDashboard
                    case .custom:
                        if case .custom = current.tapLink { return }
                        current.tapLink = .custom(tapLinkDrafts[deviceID] ?? "")
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
            set: { [deviceID = device.deviceID] value in
                tapLinkDrafts[deviceID] = value
                updateDevice(deviceID) { $0.tapLink = .custom(value) }
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
            set: { [deviceID = device.deviceID] value in
                // `EInkQuietHours.normalized` is the judge of what an HH:mm is;
                // text it refuses leaves the stored window alone rather than
                // writing a time the device would reject.
                guard let normalized = EInkQuietHours.normalized(value) else { return }
                updateDevice(deviceID) {
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

    private func updateDevice(_ deviceID: String, _ mutate: (inout EInkDeviceConfig) -> Void) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        mutate(&settings.einkSync.devices[index])
        settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
        settingsStore.settings = settings
    }

    // MARK: - Naming

    private func playbackDetail(_ device: EInkDeviceConfig) -> String {
        switch device.playbackMode {
        case .single: L10n.Settings.Eink.Playback.singleDetail
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
