import Foundation

/// A slide owns the selection; page capacity only limits one render, never
/// what the user can select. Runtime pages are derived, not persisted copies.
public enum EInkPagination {
    public static func pages(_ slide: EInkSlide, orientation: EInkOrientation,
                             profile: EInkDeviceProfile = .quote0, snapshot: EInkDataSnapshot? = nil,
                             layouts: [String: EInkCanvasLayout] = [:]) -> [EInkSlide] {
        guard let preset = slide.kind.preset else {
            return customPages(slide, orientation: orientation, profile: profile, snapshot: snapshot, layouts: layouts)
        }
        let size = profile.frameSize(for: orientation)
        let capacity = max(1, preset.pageCapacity(for: orientation, width: size.width, height: size.height))
        var pages: [EInkSlide] = []
        switch preset.selectionAxis {
        case .quotaFields:
            let fields = slide.orderedQuotaFieldIDs
            guard !fields.isEmpty else { return [slide] }
            var remaining = fields
            while !remaining.isEmpty {
                var candidate = Array(remaining.prefix(capacity))
                var page = slide
                page.quotaFieldIDs = candidate
                page.options.slotOrder = candidate
                var chosen = candidate
                if let snapshot {
                    let available = Set(snapshot.quota.map(\.fieldID))
                    while !candidate.isEmpty {
                        page.quotaFieldIDs = candidate; page.options.slotOrder = candidate
                        guard let tree = try? EInkRenderer.tree(slide: page, orientation: orientation, profile: profile, snapshot: snapshot) else { break }
                        if candidate.count > 1,
                           (try? DotCanvasEncoder.encode(tree, orientation: orientation, profile: profile)) == nil {
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

    /// Studio edits a bound template. Each overflow page reuses its slots
    /// with new field bindings, so opening Studio cannot discard later pages.
    private static func customPages(_ slide: EInkSlide, orientation: EInkOrientation, profile: EInkDeviceProfile,
                                    snapshot: EInkDataSnapshot?, layouts: [String: EInkCanvasLayout]) -> [EInkSlide] {
        guard slide.options.sourcePreset?.isQuotaPreset == true, let snapshot,
              let tree = try? EInkRenderer.tree(slide: slide, orientation: orientation, profile: profile, snapshot: snapshot, layouts: layouts)
        else { return [slide] }
        let fields = slide.orderedQuotaFieldIDs
        let drawn = drawnFieldIDs(tree)
        let slots = fields.filter(drawn.contains)
        guard !slots.isEmpty, slots.count < fields.count else { return [slide] }
        return stride(from: 0, to: fields.count, by: slots.count).enumerated().map { index, offset in
            var page = slide
            page.quotaFieldIDs = Array(fields.dropFirst(offset).prefix(slots.count))
            page.options.slotOrder = page.quotaFieldIDs
            page.renderSourceFieldIDs = fields
            page.renderFieldMap = Dictionary(uniqueKeysWithValues: zip(slots, page.quotaFieldIDs))
            if index > 0 { page.id += "/page/\(index + 1)" }
            return page
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

    public static func playbackDevice(_ device: EInkDeviceConfig, snapshot: EInkDataSnapshot? = nil, layouts: [String: EInkCanvasLayout] = [:]) -> EInkDeviceConfig {
        var copy = device
        let selected = device.playbackMode == .single ? device.resolvedSingleSlide.map { [$0] } ?? [] : device.slides
        copy.slides = selected.flatMap { pages($0, orientation: device.orientation, profile: device.profile, snapshot: snapshot, layouts: layouts) }
        if copy.slides.count > 1, device.playbackMode == .single ||
            (device.playbackMode == .deviceLoop && device.taskKeys.count < copy.slides.count) {
            copy.playbackMode = .appTimer
        }
        return copy
    }

    /// Regions share page turns. A shorter region holds its last page while
    /// a longer selection continues; no chosen field is silently dropped.
    public static func frames(_ group: EInkScreenGroup, devices: [EInkDeviceConfig] = [], snapshot: EInkDataSnapshot, layouts: [String: EInkCanvasLayout] = [:]) -> [EInkScreenFrame] {
        let selected: [EInkScreenFrame]
        if group.playbackMode == .single {
            selected = (group.frames.first { $0.id == group.singleSlideID } ?? group.frames.first).map { [$0] } ?? []
        } else { selected = group.frames }
        return selected.flatMap { frame in
            let regionPages = frame.regions.map { region in
                let bounds = group.bounds(for: region.deviceIDs, devices: devices)
                let profile = bounds.map { EInkDeviceProfile(width: $0.width, height: $0.height) } ?? .quote0
                return pages(region.slide, orientation: .degrees0, profile: profile, snapshot: snapshot, layouts: layouts)
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
