import AppKit
import SwiftUI
import VibeBarCore

/// Settings › E-ink Displays.
///
/// Three flat cards, in the order the work happens: get in (key, devices),
/// set the device up (orientation, cadence, playback, loop tasks, push), then
/// author what it shows (slides). The chrome is the ordinary
/// `SettingsSectionCard` recipe — no glass — and only the preview and the
/// read-back thumbnail are drawn as paper, because those two *are* the device.
///
/// Fluency notes, since this pane does more derivation than most:
/// - The preview plans (one for the selected orientation, four for the strip)
///   are rebuilt in `onAppear` / `onChange`, never in `body`.
/// - The bucket picker's sections are cached the same way
///   `MiniWindowsSettingsSection` caches them, because they are derived from
///   the runtime quota registry.
/// - Free text goes through `DebouncedSettingsTextField`; nothing here writes
///   `AppSettings` per keystroke.
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
    @State private var renderImage: NSImage?
    @State private var snapshot: EInkDataSnapshot?
    @State private var previews: [Int: EInkPreviewPlan] = [:]
    @State private var pickerSections: [EInkFieldSection] = []
    @State private var slideDrag: SlideDrag?
    @State private var slideFrames: [String: CGRect] = [:]

    private static let slideSpace = "vibebar.eink.slides"
    private static let dragThreshold: CGFloat = 5

    private struct SlideDrag {
        let slideID: String
        var location: CGPoint
        var engaged: Bool
    }

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
        .onDisappear {
            if let deviceID = selectedDevice?.deviceID { service.cancelRun(deviceID: deviceID) }
            pushTask?.cancel()
            pushTask = nil
        }
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
            statusGrid(state)
            Divider().padding(.vertical, 2)

            Text(L10n.Settings.Eink.orientation)
                .font(.caption2)
                .foregroundStyle(.secondary)
            orientationPicker(device)

            Divider().padding(.vertical, 2)

            refreshSteppers(device)

            Divider().padding(.vertical, 2)

            playbackControls(device)

            Divider().padding(.vertical, 2)

            loopTasks(device, state: state)

            Divider().padding(.vertical, 2)

            pushRow(device)
        }
    }

    /// Kept narrow on purpose. The settings pane is as wide as the Workbench,
    /// and a label-Spacer-value row stretched across it puts a reading three
    /// hundred points away from the word that names it.
    private static let statusColumnWidth: CGFloat = 320

    @ViewBuilder
    private func statusGrid(_ state: EInkDeviceSyncState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            infoRow(L10n.Settings.Eink.Status.power, state.powerLabel)
            infoRow(L10n.Settings.Eink.Status.battery, state.batteryLabel)
            infoRow(L10n.Settings.Eink.Status.wifi, state.wifiLabel)
            infoRow(L10n.Settings.Eink.Status.nextRefresh, state.nextRefreshAt.map(timeLabel) ?? "")
            infoRow(L10n.Settings.Eink.Status.lastPush, state.lastPushAt.map(timeLabel) ?? "")
            if let failure = state.lastFailure {
                Text(message(for: failure))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: Self.statusColumnWidth, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? L10n.Settings.Eink.Status.pending : value)
                .font(.caption2)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
        }
    }

    private func orientationPicker(_ device: EInkDeviceConfig) -> some View {
        HStack(spacing: 8) {
            ForEach(EInkOrientation.allCases, id: \.rawValue) { orientation in
                Button {
                    updateDevice(device.deviceID) { $0.orientation = orientation }
                } label: {
                    EInkOrientationGlyph(orientation: orientation)
                }
                .buttonStyle(.vibeBar(cornerRadius: 8))
                .help(orientationHelp(orientation))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(device.orientation == orientation ? Color.accentColor.opacity(0.20) : Color.clear)
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func refreshSteppers(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(
                value: Binding(
                    get: { device.dataRefreshMinutes },
                    set: { value in updateDevice(device.deviceID) { $0.dataRefreshMinutes = value } }
                ),
                in: EInkDeviceConfig.minimumDataRefreshMinutes...(24 * 60)
            ) {
                HStack(spacing: 6) {
                    Text(L10n.Settings.Eink.dataRefresh).font(.caption)
                    Text(L10n.Common.Duration.Full.minutes(count: device.dataRefreshMinutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.Settings.Eink.dataRefreshDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Stepper(
                value: Binding(
                    get: { device.batteryRefreshMinutes },
                    set: { value in updateDevice(device.deviceID) { $0.batteryRefreshMinutes = value } }
                ),
                in: EInkDeviceConfig.minimumBatteryRefreshMinutes...(24 * 60)
            ) {
                HStack(spacing: 6) {
                    Text(L10n.Settings.Eink.batteryRefresh).font(.caption)
                    Text(L10n.Common.Duration.Full.minutes(count: device.batteryRefreshMinutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.Settings.Eink.batteryRefreshDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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

            if case let .carousel(driver, seconds) = device.playback, driver == .appTimer {
                Stepper(
                    value: Binding(
                        get: { seconds },
                        set: { value in
                            updateDevice(device.deviceID) {
                                $0.playback = .carousel(driver: .appTimer, secondsPerSlide: value)
                            }
                        }
                    ),
                    in: EInkPlayback.minimumSecondsPerSlide...EInkPlayback.maximumSecondsPerSlide,
                    step: 30
                ) {
                    HStack(spacing: 6) {
                        Text(L10n.Settings.Eink.secondsPerSlide).font(.caption)
                        Text(AppLocale.number(seconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
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
                    // A slow service can hold a multi-slide push for minutes
                    // (three attempts per item, each with a 30 s timeout), and
                    // a disabled button with a spinner is not an answer to
                    // that. The pane also cancels on the way out.
                    Button(L10n.Common.cancel) {
                        service.cancelRun(deviceID: device.deviceID)
                        pushTask?.cancel()
                    }
                    .buttonStyle(.vibeBar)
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
                Image(nsImage: renderImage)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
                    .frame(
                        width: CGFloat(device.profile.width) * 2,
                        height: CGFloat(device.profile.height) * 2
                    )
                    .background(Color.white)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
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
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    slideList(device)
                    if let slide = selectedSlide {
                        Divider().padding(.vertical, 2)
                        slideEditor(device, slide: slide)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                previewColumn
            }
        }
    }

    private func slideList(_ device: EInkDeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(device.slides) { slide in
                slideRow(device, slide: slide)
            }
            HStack(spacing: 8) {
                Button(action: { addSlide(device.deviceID) }) {
                    Label(L10n.Settings.Eink.addSlide, systemImage: "plus")
                }
                .buttonStyle(.vibeBar)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .coordinateSpace(.named(Self.slideSpace))
        .overlay(alignment: .topLeading) {
            if let insertion = slideInsertionIndex(device), let offset = slideInsertionOffset(device, at: insertion) {
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(height: 2.5)
                    .offset(y: offset)
                    .allowsHitTesting(false)
            }
        }
    }

    private func slideRow(_ device: EInkDeviceConfig, slide: EInkSlide) -> some View {
        let isSelected = selectedSlide?.id == slide.id
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .gesture(slideDragGesture(device, slideID: slide.id))
                .help(L10n.Common.dragToReorder)

            Button {
                selectedSlideID = slide.id
                // On a single-slide device the row *is* the active-slide
                // control: there is no other one, and picking a row that the
                // panel then ignores is a switch that does nothing.
                if case .single = device.playback {
                    updateDevice(device.deviceID) { $0.playback = .single(slideID: slide.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(slideDisplayName(slide))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(layoutName(for: slide.kind))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.vibeBar(cornerRadius: 6))

            BorderlessIconButton(
                systemImage: "xmark",
                help: device.slides.count > 1 ? L10n.Settings.Eink.removeSlide : L10n.Settings.Eink.lastSlide
            ) {
                removeSlide(device.deviceID, slideID: slide.id)
            }
            .disabled(device.slides.count <= 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .opacity(slideDrag?.engaged == true && slideDrag?.slideID == slide.id ? 0.3 : 1)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(Self.slideSpace))
        } action: { frame in
            slideFrames[slide.id] = frame
        }
    }

    @ViewBuilder
    private func slideEditor(_ device: EInkDeviceConfig, slide: EInkSlide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.Common.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                DebouncedSettingsTextField(
                    prompt: L10n.Settings.Eink.slideName,
                    value: Binding(
                        get: { slide.title },
                        set: { [deviceID = device.deviceID, slideID = slide.id] value in
                            updateSlide(deviceID, slideID: slideID) { $0.title = value }
                        }
                    )
                )
                .frame(width: 160)
            }

            Picker(L10n.Settings.Eink.layout, selection: layoutBinding(device, slide: slide)) {
                Section(L10n.Settings.Eink.Group.quota) {
                    ForEach(EInkPreset.allCases.filter(\.isQuotaPreset), id: \.rawValue) { preset in
                        Text(presetName(preset)).tag(preset.rawValue)
                    }
                }
                Section(L10n.Settings.Eink.Group.usage) {
                    ForEach(EInkPreset.allCases.filter { !$0.isQuotaPreset }, id: \.rawValue) { preset in
                        Text(presetName(preset)).tag(preset.rawValue)
                    }
                }
                Text(L10n.Settings.Eink.customSlide).tag(Self.customTag)
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)

            selectionEditor(device, slide: slide)
        }
    }

    /// Sentinel tag for the Studio option. Selecting it does nothing — the
    /// custom renderer has not shipped — but the option is shown so a slide
    /// already pointing at a layout reads correctly instead of silently
    /// appearing as a preset it is not.
    private static let customTag = "\u{0}custom"

    @ViewBuilder
    private func selectionEditor(_ device: EInkDeviceConfig, slide: EInkSlide) -> some View {
        if slide.kind.preset == nil {
            Text(L10n.Settings.Eink.customSlideDetail)
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let preset = slide.kind.preset {
            let capacity = preset.capacity(for: device.orientation)
            switch preset.selectionAxis {
            case .quotaFields:
                bucketPicker(device, slide: slide, capacity: capacity)
            case .usagePeriods:
                periodPicker(device, slide: slide, capacity: capacity)
            case .harnessRows:
                Text(L10n.Settings.Eink.noSelection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .none:
                Text(L10n.Settings.Eink.fixedContent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bucketPicker(_ device: EInkDeviceConfig, slide: EInkSlide, capacity: Int) -> some View {
        let selected = slide.quotaFieldIDs
        let isFull = selected.count >= capacity
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Settings.Eink.buckets)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.Quota.History.curvesSome(shown: selected.count, total: capacity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if selected.isEmpty {
                Text(L10n.Settings.Eink.noSelection)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isFull {
                Text(L10n.Settings.Eink.capacityFull(count: capacity))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pickerSections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    ForEach(section.options) { option in
                        Toggle(
                            QuotaGroupLabelLocalizer.display(option.displayTitle),
                            isOn: bucketBinding(device, slide: slide, fieldID: option.id, capacity: capacity)
                        )
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(isFull && !selected.contains(option.id))
                    }
                }
            }
        }
    }

    private func periodPicker(_ device: EInkDeviceConfig, slide: EInkSlide, capacity: Int) -> some View {
        let selected = slide.usagePeriods
        let isFull = selected.count >= capacity
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.Usage.Breakdown.periods)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.Quota.History.curvesSome(shown: selected.count, total: capacity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ForEach(EInkUsagePeriod.allCases, id: \.rawValue) { period in
                Toggle(
                    periodName(period),
                    isOn: periodBinding(device, slide: slide, period: period, capacity: capacity)
                )
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(
                    (isFull && !selected.contains(period))
                        || (selected.count == 1 && selected.contains(period))
                )
            }
        }
    }

    // MARK: - Preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.MenuBar.Composer.preview)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let plan = previews[selectedDevice?.orientation.rawValue ?? 0] {
                // 2x is 592 pt wide, which a narrow window cannot hold; fall
                // back to device pixels rather than clipping the panel.
                ViewThatFits(in: .horizontal) {
                    EInkPreviewView(plan: plan, scale: 2)
                    EInkPreviewView(plan: plan, scale: 1)
                }
            } else {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 296 * 2, height: 152 * 2)
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            }

            Text(L10n.Settings.Eink.allOrientations)
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Four 296 pt panels plus their gaps are wider than the detail
            // pane at the default Workbench width, and a clipped preview of a
            // rotation is worse than a wrapped one.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 296), spacing: 8, alignment: .topLeading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(EInkOrientation.allCases, id: \.rawValue) { orientation in
                    if let plan = previews[orientation.rawValue] {
                        EInkPreviewView(plan: plan, scale: 1)
                    }
                }
            }

            Text(L10n.Settings.Eink.panelTextNote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 296 * 2, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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
                slide: slide,
                orientation: orientation,
                profile: device.profile,
                snapshot: snapshot,
                layouts: settingsStore.settings.einkCanvasLayouts
            )
        }
        previews = plans
    }

    private func rebuildPickerSections() {
        let registry = quotaService.fieldRegistry
        var sections = MiniWindowFieldProviderSection.all.map {
            EInkFieldSection(tool: $0.tool, title: $0.title, options: $0.fields)
        }
        for discovered in registry.fields where MenuBarFieldCatalog.field(id: discovered.id) == nil {
            guard let index = sections.firstIndex(where: { $0.tool == discovered.tool }) else { continue }
            sections[index].options.append(MenuBarFieldCatalog.option(for: discovered))
        }
        pickerSections = sections.filter { !$0.options.isEmpty }
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
            includingFieldIDs: settingsStore.settings.einkSync.selectedQuotaFieldIDs
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
                    into: settings.einkSync.devices
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
    private func pushNow(_ deviceID: String) {
        pushTask?.cancel()
        pushStatus = nil
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
            guard selectedDevice?.deviceID == deviceID else { return }
            if let failure = outcome.failure {
                pushStatus = message(for: failure)
            } else {
                pushStatus = L10n.Settings.Eink.pushResult(pushed: outcome.pushed, skipped: outcome.skipped)
            }
            await loadRenderImage()
        }
    }

    private func addSlide(_ deviceID: String) {
        let slide = EInkSlide(kind: .preset(.quotaLedger))
        updateDevice(deviceID) { $0.slides.append(slide) }
        selectedSlideID = slide.id
    }

    private func removeSlide(_ deviceID: String, slideID: String) {
        updateDevice(deviceID) { device in
            guard device.slides.count > 1 else { return }
            device.slides.removeAll { $0.id == slideID }
        }
        if selectedSlideID == slideID { selectedSlideID = selectedDevice?.slides.first?.id }
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

    private func layoutBinding(_ device: EInkDeviceConfig, slide: EInkSlide) -> Binding<String> {
        Binding(
            get: { slide.kind.preset?.rawValue ?? Self.customTag },
            set: { [deviceID = device.deviceID, slideID = slide.id] value in
                guard let preset = EInkPreset(rawValue: value) else { return }
                updateSlide(deviceID, slideID: slideID) { current in
                    current.kind = .preset(preset)
                    let capacity = preset.capacity(for: device.orientation)
                    current.quotaFieldIDs = Array(current.quotaFieldIDs.prefix(capacity))
                }
            }
        )
    }

    private func bucketBinding(
        _ device: EInkDeviceConfig,
        slide: EInkSlide,
        fieldID: String,
        capacity: Int
    ) -> Binding<Bool> {
        Binding(
            get: { slide.quotaFieldIDs.contains(fieldID) },
            set: { [deviceID = device.deviceID, slideID = slide.id] value in
                updateSlide(deviceID, slideID: slideID) { current in
                    if value {
                        guard current.quotaFieldIDs.count < capacity,
                              !current.quotaFieldIDs.contains(fieldID) else { return }
                        current.quotaFieldIDs.append(fieldID)
                    } else {
                        current.quotaFieldIDs.removeAll { $0 == fieldID }
                    }
                }
            }
        )
    }

    private func periodBinding(
        _ device: EInkDeviceConfig,
        slide: EInkSlide,
        period: EInkUsagePeriod,
        capacity: Int
    ) -> Binding<Bool> {
        Binding(
            get: { slide.usagePeriods.contains(period) },
            set: { [deviceID = device.deviceID, slideID = slide.id] value in
                updateSlide(deviceID, slideID: slideID) { current in
                    if value {
                        guard current.usagePeriods.count < capacity,
                              !current.usagePeriods.contains(period) else { return }
                        current.usagePeriods.append(period)
                    } else {
                        // The renderer reads an empty selection as "all four",
                        // so clearing the last box would show every period
                        // while the picker showed none. One always stays on.
                        guard current.usagePeriods.count > 1 else { return }
                        current.usagePeriods.removeAll { $0 == period }
                    }
                }
            }
        )
    }

    private func playbackModeBinding(_ device: EInkDeviceConfig) -> Binding<EInkPlaybackMode> {
        Binding(
            get: {
                switch device.playback {
                case .single: return .single
                case let .carousel(driver, _): return driver == .deviceLoop ? .deviceLoop : .appTimer
                }
            },
            set: { [deviceID = device.deviceID, activeSlideID = selectedSlide?.id] mode in
                updateDevice(deviceID) { current in
                    switch mode {
                    case .single:
                        // The slide the editor and the preview are showing is
                        // the one the user means; falling back to the first
                        // would send a different panel than the one on screen.
                        let chosen = activeSlideID.flatMap { id in
                            current.slides.first { $0.id == id }?.id
                        }
                        current.playback = .single(slideID: chosen ?? current.slides.first?.id ?? "")
                    case .deviceLoop:
                        current.playback = .carousel(driver: .deviceLoop, secondsPerSlide: 300)
                    case .appTimer:
                        current.playback = .carousel(driver: .appTimer, secondsPerSlide: 300)
                    }
                }
            }
        )
    }

    // MARK: - Mutation

    /// Read-modify-write of the whole settings value, exactly as
    /// `MiniWindowsSettingsSection` does it: one write, one fan-out.
    private func updateDevice(_ deviceID: String, _ mutate: (inout EInkDeviceConfig) -> Void) {
        var settings = settingsStore.settings
        guard let index = settings.einkSync.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        mutate(&settings.einkSync.devices[index])
        settings.einkSync.devices[index] = settings.einkSync.devices[index].sanitized
        settingsStore.settings = settings
    }

    private func updateSlide(_ deviceID: String, slideID: String, _ mutate: (inout EInkSlide) -> Void) {
        updateDevice(deviceID) { device in
            guard let index = device.slides.firstIndex(where: { $0.id == slideID }) else { return }
            mutate(&device.slides[index])
        }
    }

    // MARK: - Slide drag

    private func slideDragGesture(_ device: EInkDeviceConfig, slideID: String) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.slideSpace))
            .onChanged { value in
                var state = slideDrag ?? SlideDrag(slideID: slideID, location: value.location, engaged: false)
                guard state.slideID == slideID else { return }
                state.location = value.location
                if !state.engaged,
                   hypot(value.translation.width, value.translation.height) >= Self.dragThreshold {
                    state.engaged = true
                }
                slideDrag = state
            }
            .onEnded { _ in
                defer { slideDrag = nil }
                guard let state = slideDrag, state.slideID == slideID, state.engaged,
                      let target = slideInsertionIndex(device)
                else { return }
                applySlideMove(device.deviceID, slideID: slideID, to: target, order: device.slides.map(\.id))
            }
    }

    private func slideInsertionIndex(_ device: EInkDeviceConfig) -> Int? {
        guard let state = slideDrag, state.engaged else { return nil }
        var index = 0
        for slide in device.slides {
            guard let frame = slideFrames[slide.id] else { continue }
            if state.location.y > frame.midY { index += 1 }
        }
        return min(index, device.slides.count)
    }

    private func slideInsertionOffset(_ device: EInkDeviceConfig, at index: Int) -> CGFloat? {
        let ids = device.slides.map(\.id)
        if index < ids.count, let frame = slideFrames[ids[index]] { return frame.minY - 1.5 }
        if let last = ids.last, let frame = slideFrames[last] { return frame.maxY - 1.5 }
        return nil
    }

    private func applySlideMove(_ deviceID: String, slideID: String, to index: Int, order: [String]) {
        var ordered = order.filter { $0 != slideID }
        // The caret index counts the dragged row, and the row is gone from
        // `ordered`. Dragging the first of three between the other two would
        // otherwise land it at the end.
        var target = index
        if let source = order.firstIndex(of: slideID), source < index { target -= 1 }
        ordered.insert(slideID, at: min(max(0, target), ordered.count))
        updateDevice(deviceID) { device in
            let byID = Dictionary(device.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            device.slides = ordered.compactMap { byID[$0] }
        }
    }

    // MARK: - Naming

    private func slideDisplayName(_ slide: EInkSlide) -> String {
        slide.title.isEmpty ? layoutName(for: slide.kind) : slide.title
    }

    private func layoutName(for kind: EInkSlide.Kind) -> String {
        guard let preset = kind.preset else { return L10n.Settings.Eink.customSlide }
        return presetName(preset)
    }

    private func presetName(_ preset: EInkPreset) -> String {
        switch preset {
        case .quotaLedger: L10n.Settings.MiniWindow.Mode.ledger
        case .quotaRings: L10n.Settings.Eink.Preset.rings
        case .quotaRail: L10n.Settings.MiniWindow.Mode.rail
        case .usageTiles: L10n.Settings.MiniWindow.Mode.tiles
        case .usageSplit: L10n.Settings.Eink.Preset.split
        case .usageTable: L10n.Settings.Eink.Preset.table
        case .usageDual: L10n.Settings.Eink.Preset.dual
        case .usageTrend: L10n.Settings.Eink.Preset.trend
        }
    }

    private func periodName(_ period: EInkUsagePeriod) -> String {
        switch period {
        case .today: L10n.Cost.Timeframe.today
        case .week: L10n.Cost.Timeframe.week
        case .month: L10n.Cost.Timeframe.month
        case .allTime: L10n.Cost.ModelRanking.allTime
        }
    }

    private func orientationHelp(_ orientation: EInkOrientation) -> String {
        switch orientation {
        case .degrees0: L10n.Settings.Eink.Orientation.upright
        case .degrees90: L10n.Settings.Eink.Orientation.right
        case .degrees180: L10n.Settings.Eink.Orientation.inverted
        case .degrees270: L10n.Settings.Eink.Orientation.left
        }
    }

    private func playbackDetail(_ device: EInkDeviceConfig) -> String {
        switch device.playback {
        case .single: L10n.Settings.Eink.Playback.singleDetail
        case let .carousel(driver, _):
            driver == .deviceLoop
                ? L10n.Settings.Eink.Playback.deviceLoopDetail
                : L10n.Settings.Eink.Playback.appTimerDetail
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

/// Segmented value for the three playback choices, which the model spells as
/// an enum with an associated value the picker cannot tag with.
enum EInkPlaybackMode: Hashable {
    case single
    case deviceLoop
    case appTimer
}

/// One provider's worth of quota buckets, exactly as the mini-window picker
/// groups them.
struct EInkFieldSection: Identifiable {
    let tool: ToolType
    let title: String
    var options: [MenuBarFieldOption]
    var id: String { title }
}

/// The panel outline with its top edge marked, so the four orientations read
/// as "which way up is the device" rather than as four numbers.
private struct EInkOrientationGlyph: View {
    let orientation: EInkOrientation

    var body: some View {
        let portrait = orientation.isPortrait
        let width: CGFloat = portrait ? 13 : 22
        let height: CGFloat = portrait ? 22 : 13
        ZStack(alignment: topEdge) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            Rectangle()
                .fill(Color.accentColor)
                .frame(
                    width: orientation.isPortrait ? 2.5 : width - 6,
                    height: orientation.isPortrait ? height - 6 : 2.5
                )
                .padding(2)
        }
        .frame(width: width, height: height)
        .padding(3)
    }

    /// Which side of the outline the "top of the drawing" ends up on.
    private var topEdge: Alignment {
        switch orientation {
        case .degrees0: .top
        case .degrees90: .trailing
        case .degrees180: .bottom
        case .degrees270: .leading
        }
    }
}
