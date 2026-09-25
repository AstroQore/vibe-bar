import Foundation

/// How one page of a group uses the screens under it.
///
/// The three cases are a *reading* of `EInkScreenFrame.regions`, never a
/// second stored field: a page that assigns every screen to one region is
/// combined, a page that gives each screen its own region is separate, and
/// anything between the two is custom. Deriving it keeps the on-disk shape
/// the one the renderer already understands, so a group written by an older
/// build reads back as whatever it actually is.
public enum EInkScreenMode: String, CaseIterable, Sendable {
    /// One template across the whole group: the canvas is every screen put
    /// together, which is what makes a page hold more than one panel fits.
    case combined
    /// One template per screen, each drawn on that screen's own canvas.
    case separate
    /// Some screens merged, some not.
    case custom
}

public extension EInkScreenGroup {
    /// The members in reading order — down the stack, then across the row.
    ///
    /// The stored order is the order screens were added, which says nothing
    /// about where they hang. Every list that names members (the tab strip,
    /// a combined region's screens, the roster subtitle) uses this one so
    /// they agree with the arrangement canvas.
    var orderedScreenIDs: [String] {
        screens.sorted { first, second in
            first.y == second.y ? first.x < second.x : first.y < second.y
        }
        .map(\.deviceID)
    }
}

public extension EInkScreenFrame {
    /// Which of the three shapes this page is in.
    func screenMode(screenIDs: [String]) -> EInkScreenMode {
        let assigned = regions.flatMap(\.deviceIDs)
        guard !regions.isEmpty, assigned.count == screenIDs.count,
              Set(assigned) == Set(screenIDs) else { return .custom }
        if regions.count == 1 { return .combined }
        return regions.allSatisfy { $0.deviceIDs.count == 1 } ? .separate : .custom
    }

    /// The same page, read across the screens the new mode asks for.
    ///
    /// Nothing selected is thrown away: combining unions the regions' buckets
    /// and periods through `EInkGroupSlides.merging`, and separating hands
    /// every screen a copy of the content that covered it. A screen that no
    /// region named — only reachable from a hand-made custom page — is seeded
    /// from the first region rather than left blank.
    func settingMode(_ mode: EInkScreenMode, screenIDs: [String]) -> EInkScreenFrame {
        guard let first = regions.first, !screenIDs.isEmpty else { return self }
        switch mode {
        case .custom:
            return self
        case .combined:
            var copy = EInkGroupSlides.merging(Set(regions.map(\.id)), in: self)
            guard var region = copy.regions.first else { return self }
            region.deviceIDs = screenIDs
            copy.regions = [region]
            return copy
        case .separate:
            var copy = self
            copy.regions = screenIDs.map { id in
                guard let owner = regions.first(where: { $0.deviceIDs.contains(id) }) else {
                    return EInkScreenRegion(deviceIDs: [id], slide: first.slide.forOneScreen)
                }
                // A region that already covers exactly this screen keeps its
                // id, so its custom layout and its place in the editor's tab
                // strip survive a round trip through Combined.
                if owner.deviceIDs == [id] { return owner }
                return EInkScreenRegion(deviceIDs: [id], slide: owner.slide.forOneScreen)
            }
            return copy
        }
    }
}

public extension EInkSlide {
    /// This slide as one screen of its own draws it.
    ///
    /// The group templates spread a selection over several screens and are
    /// offered only there, so a page taken apart hands each screen the ledger
    /// the templates are built from — keeping every bucket, every name and
    /// every option — rather than a template its own layout picker cannot
    /// name.
    var forOneScreen: EInkSlide {
        guard kind.preset?.isGroupLayout == true else { return self }
        var copy = self
        copy.kind = .preset(.quotaLedger)
        return copy
    }
}

/// What Settings › E-ink Displays lists: one row per display, where a display
/// is either a screen on its own or a group of screens acting as one.
///
/// A group takes the place of its first member, so adding a group does not
/// reshuffle the page under the person who just made it, and taking one apart
/// puts its screens back where they were.
public enum EInkDisplayRoster {
    public enum Entry: Equatable, Identifiable, Sendable {
        case device(EInkDeviceConfig)
        case group(EInkScreenGroup)

        public var id: String {
            switch self {
            case let .device(device): "device:" + device.deviceID
            case let .group(group): "group:" + group.id
            }
        }
    }

    public static func entries(_ settings: EInkSyncSettings) -> [Entry] {
        var placed = Set<String>()
        var result: [Entry] = []
        for device in settings.devices {
            guard let group = settings.owningGroup(for: device.deviceID) else {
                result.append(.device(device))
                continue
            }
            guard placed.insert(group.id).inserted else { continue }
            result.append(.group(group))
        }
        // A group whose members have all left the account still owns pages
        // somebody authored; listing it is what makes it possible to take it
        // apart rather than leaving it to haunt `settings.json`.
        for group in settings.groups where !placed.contains(group.id) {
            result.append(.group(group))
        }
        return result
    }

    /// The devices behind a group, in reading order.
    public static func members(of group: EInkScreenGroup, devices: [EInkDeviceConfig]) -> [EInkDeviceConfig] {
        group.orderedScreenIDs.compactMap { id in devices.first { $0.deviceID == id } }
    }

    /// The names a group prints for its members, in reading order.
    public static func memberNames(of group: EInkScreenGroup, devices: [EInkDeviceConfig]) -> [String] {
        group.orderedScreenIDs.map { id in
            guard let device = devices.first(where: { $0.deviceID == id }) else { return id }
            return device.alias.isEmpty ? device.deviceID : device.alias
        }
    }
}
