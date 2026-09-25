import Foundation

/// A slide owns the selection; page capacity only limits one render, never
/// what the user can select. Runtime pages are derived, not persisted copies.
public enum EInkPagination {
    public static func pages(_ slide: EInkSlide, orientation: EInkOrientation,
                             profile: EInkDeviceProfile = .quote0, snapshot: EInkDataSnapshot? = nil) -> [EInkSlide] {
        guard let preset = slide.kind.preset else { return [slide] }
        let size = profile.frameSize(for: orientation)
        let capacity = max(1, preset.pageCapacity(for: orientation, profile: profile))
        var pages: [EInkSlide] = []
        switch preset.selectionAxis {
        case .quotaFields:
            let fields = slide.orderedQuotaFieldIDs
            guard !fields.isEmpty else { return [slide] }
            // A bucket this snapshot does not carry (its provider logged out,
            // or stopped returning it) draws nothing. It stays in the selection
            // — riding on the page it falls on, so materializing keeps it — but
            // it never takes a slot and never makes a page of its own.
            let available = snapshot.map { Set($0.quota.map(\.fieldID)) }
            var remaining = fields
            while !remaining.isEmpty {
                var candidate: [String]
                if let available {
                    if !remaining.contains(where: available.contains), var last = pages.popLast() {
                        last.quotaFieldIDs += remaining
                        last.options.slotOrder = last.quotaFieldIDs
                        pages.append(last)
                        break
                    }
                    var slots = 0
                    candidate = Array(remaining.prefix { id in
                        guard slots < capacity else { return false }
                        if available.contains(id) { slots += 1 }
                        return true
                    })
                } else {
                    candidate = Array(remaining.prefix(capacity))
                }
                var page = slide
                page.quotaFieldIDs = candidate
                page.options.slotOrder = candidate
                var chosen = candidate
                if let snapshot, let available {
                    while !candidate.isEmpty {
                        page.quotaFieldIDs = candidate; page.options.slotOrder = candidate
                        guard let tree = try? EInkRenderer.tree(slide: page, orientation: orientation, profile: profile, snapshot: snapshot) else { break }
                        if candidate.count > 1, !encodes(tree, orientation: orientation, profile: profile) {
                            candidate.removeLast()
                            continue
                        }
                        let drawn = drawnFieldIDs(tree)
                        let kept = candidate.filter { drawn.contains($0) || !available.contains($0) }
                        chosen = kept.isEmpty ? [candidate[0]] : kept
                        break
                    }
                } else {
                    let labels = candidate.map { EInkSlotLabel.resolved(for: $0, options: slide.options) }
                    let count = size.width * size.height > 296 * 152 ? candidate.count
                        : max(1, preset.rowCount(for: orientation, labels: labels, options: slide.options))
                    chosen = Array(candidate.prefix(count))
                }
                page.quotaFieldIDs = chosen
                page.options.slotOrder = chosen
                pages.append(page)
                let consumed = Set(chosen)
                remaining.removeAll { consumed.contains($0) }
            }
        case .usagePeriods:
            guard !slide.usagePeriods.isEmpty else { return [slide] }
            for offset in stride(from: 0, to: slide.usagePeriods.count, by: capacity) {
                var page = slide
                page.usagePeriods = Array(slide.usagePeriods.dropFirst(offset).prefix(capacity))
                pages.append(page)
            }
        case .harnessRows, .none:
            return [slide]
        }
        for index in pages.indices where index > 0 { pages[index].id = slide.id + "/page/\(index + 1)" }
        return pages
    }

    /// Materialize before freeform editing: each page becomes an ordinary
    /// independently editable slide, and no selected content is discarded.
    public static func materializedPages(_ slide: EInkSlide, orientation: EInkOrientation,
                                         profile: EInkDeviceProfile = .quote0, snapshot: EInkDataSnapshot) -> [EInkSlide] {
        var result = pages(slide, orientation: orientation, profile: profile, snapshot: snapshot)
        for i in result.indices where i > 0 { result[i].id = UUID().uuidString }
        return result
    }

    public static func materializedFrames(_ frame: EInkScreenFrame, group: EInkScreenGroup,
                                          devices: [EInkDeviceConfig], snapshot: EInkDataSnapshot) -> [EInkScreenFrame] {
        var owner = group; owner.frames = [frame]; owner.playbackMode = .appTimer
        var result = frames(owner, devices: devices, snapshot: snapshot)
        for i in result.indices where i > 0 {
            result[i].id = UUID().uuidString
            result[i].regions = result[i].regions.map { EInkScreenRegion(deviceIDs: $0.deviceIDs, slide: $0.slide) }
        }
        return result
    }

    /// Whether a page fits the device's Canvas limits. A canvas made of
    /// several screens is sent as one payload per screen, so each screen is
    /// measured against the limits on its own — the whole canvas's element
    /// count is not a number any panel ever receives.
    private static func encodes(_ tree: EInkNode, orientation: EInkOrientation, profile: EInkDeviceProfile) -> Bool {
        guard profile.panes.count > 1, orientation == .degrees0 else {
            return (try? DotCanvasEncoder.encode(tree, orientation: orientation, profile: profile)) != nil
        }
        let boxes = EInkBoxLayout.resolve(tree, in: EInkRect(x: 0, y: 0, width: profile.width, height: profile.height))
        return EInkScreenGroupRenderer.split(boxes, panes: profile.panes).allSatisfy {
            (try? DotCanvasEncoder.encode(boxes: $0, orientation: .degrees0)) != nil
        }
    }

    private static func drawnFieldIDs(_ node: EInkNode) -> Set<String> {
        var result = Set(node.binding?.fieldID.map { [$0] } ?? [])
        if let module = node.moduleID, module.hasPrefix(EInkPresets.slotModulePrefix) {
            result.insert(String(module.dropFirst(EInkPresets.slotModulePrefix.count)))
        }
        for child in node.children { result.formUnion(drawnFieldIDs(child)) }
        return result
    }

    public static func playbackDevice(_ device: EInkDeviceConfig, snapshot: EInkDataSnapshot? = nil) -> EInkDeviceConfig {
        var copy = device
        let selected = device.playbackMode == .single ? device.resolvedSingleSlide.map { [$0] } ?? [] : device.slides
        copy.slides = selected.flatMap { pages($0, orientation: device.orientation, profile: device.profile, snapshot: snapshot) }
        if copy.slides.count > 1, device.playbackMode == .single ||
            (device.playbackMode == .deviceLoop && device.taskKeys.count < copy.slides.count) {
            copy.playbackMode = .appTimer
        }
        return copy
    }

    /// Regions share page turns. A shorter region holds its last page while
    /// a longer selection continues; no chosen field is silently dropped.
    public static func frames(_ group: EInkScreenGroup, devices: [EInkDeviceConfig] = [], snapshot: EInkDataSnapshot) -> [EInkScreenFrame] {
        let selected: [EInkScreenFrame]
        if group.playbackMode == .single {
            selected = (group.frames.first { $0.id == group.singleSlideID } ?? group.frames.first).map { [$0] } ?? []
        } else { selected = group.frames }
        return selected.flatMap { frame in
            let regionPages = frame.regions.map { region in
                let profile = group.canvasProfile(for: region.deviceIDs, devices: devices) ?? .quote0
                return pages(region.slide, orientation: .degrees0, profile: profile, snapshot: snapshot)
            }
            let count = regionPages.map(\.count).max() ?? 1
            return (0..<count).map { index in
                var page = frame
                if index > 0 { page.id += "/page/\(index + 1)" }
                for region in frame.regions.indices {
                    page.regions[region].slide = regionPages[region][min(index, regionPages[region].count - 1)]
                }
                return page
            }
        }
    }
}
