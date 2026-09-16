import Foundation

/// Group slides use the same content model as standalone slides. A region
/// only assigns that content to physical screens; it is not another player.
public enum EInkGroupSlides {
    public static func create(name: String, devices: [EInkDeviceConfig], vertical: Bool) -> EInkScreenGroup {
        var offset = 0
        let screens = devices.map { device in
            let size = device.profile.frameSize(for: device.orientation)
            defer { offset += vertical ? size.height : size.width }
            return EInkScreenPlacement(deviceID: device.id, x: vertical ? 0 : offset, y: vertical ? offset : 0)
        }
        let count = max(1, devices.map { $0.slides.count }.max() ?? 1)
        let frames = (0..<count).map { index in
            EInkScreenFrame(regions: devices.map { device in
                let slide = device.slides.isEmpty ? EInkSlide.defaultQuotaSlide() : device.slides[min(index, device.slides.count - 1)]
                return EInkScreenRegion(deviceIDs: [device.id], slide: slide)
            })
        }
        let first = devices.first
        var group = EInkScreenGroup(name: name, screens: screens, frames: frames,
            secondsPerFrame: first?.secondsPerSlide ?? 300,
            dataRefreshMinutes: first?.dataRefreshMinutes ?? 15,
            batteryRefreshMinutes: first?.batteryRefreshMinutes ?? 60)
        group.playbackMode = .single
        group.singleSlideID = frames.first?.id
        return group
    }

    public static func adding(_ device: EInkDeviceConfig, to group: EInkScreenGroup,
                              devices: [EInkDeviceConfig]) -> EInkScreenGroup {
        guard !group.screens.contains(where: { $0.id == device.id }) else { return group }
        var copy = group
        let bottom = group.bounds(for: group.screens.map(\.id), devices: devices)?.maxY ?? 0
        copy.screens.append(EInkScreenPlacement(deviceID: device.id, y: bottom))
        let count = max(1, max(copy.frames.count, device.slides.count))
        while copy.frames.count < count {
            let regions = copy.frames.last?.regions.map { EInkScreenRegion(deviceIDs: $0.deviceIDs, slide: $0.slide) } ?? []
            copy.frames.append(EInkScreenFrame(regions: regions))
        }
        for index in copy.frames.indices {
            let slide = device.slides.isEmpty ? EInkSlide.defaultQuotaSlide() : device.slides[min(index, device.slides.count - 1)]
            copy.frames[index].regions.append(EInkScreenRegion(deviceIDs: [device.id], slide: slide))
        }
        return copy
    }

    public static func merging(_ regionIDs: Set<String>, in frame: EInkScreenFrame) -> EInkScreenFrame {
        let regions = frame.regions.filter { regionIDs.contains($0.id) }
        guard let first = regions.first, regions.count > 1 else { return frame }
        var merged = first
        merged.deviceIDs = regions.flatMap(\.deviceIDs)
        var seen = Set<String>()
        merged.slide.quotaFieldIDs = regions.flatMap { $0.slide.orderedQuotaFieldIDs }.filter { seen.insert($0).inserted }
        merged.slide.options.slotOrder = merged.slide.quotaFieldIDs
        merged.slide.usagePeriods = EInkUsagePeriod.allCases.filter { period in regions.contains { $0.slide.usagePeriods.contains(period) } }
        for region in regions.dropFirst() {
            merged.slide.options.customLabels.merge(region.slide.options.customLabels) { old, _ in old }
        }
        var copy = frame
        copy.regions = frame.regions.compactMap { region in
            if region.id == first.id { return merged }
            return regionIDs.contains(region.id) ? nil : region
        }
        return copy
    }

    public static func splitting(_ regionID: String, in frame: EInkScreenFrame) -> EInkScreenFrame {
        var copy = frame
        copy.regions = frame.regions.flatMap { region in
            guard region.id == regionID, region.deviceIDs.count > 1 else { return [region] }
            return region.deviceIDs.map { EInkScreenRegion(deviceIDs: [$0], slide: region.slide) }
        }
        return copy
    }
}
