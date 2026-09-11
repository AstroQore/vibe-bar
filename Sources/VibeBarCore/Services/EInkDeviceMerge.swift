import Foundation

/// Merges a freshly fetched roster into the stored one.
///
/// Configuration survives: a device already in `settings.json` keeps its
/// slides, orientation, cadence and task keys, and only learns its current
/// alias and panel profile. A device the account no longer lists is kept too —
/// a roster fetch that fails halfway, or a device temporarily off the account,
/// must not silently delete the slides someone spent time arranging.
public enum EInkDeviceMerge {
    public static func merge(
        discovered: [DotDevice],
        into existing: [EInkDeviceConfig]
    ) -> [EInkDeviceConfig] {
        var byID = Dictionary(existing.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []

        for device in discovered where !device.id.isEmpty {
            var config = byID[device.id] ?? EInkDeviceConfig(
                deviceID: device.id,
                slides: [EInkSlide(kind: .preset(.quotaLedger))]
            )
            config.alias = device.alias
            if let profile = device.profile { config.profile = profile }
            byID[device.id] = config
            order.append(device.id)
        }

        let discoveredIDs = Set(order)
        let untouched = existing.map(\.deviceID).filter { !discoveredIDs.contains($0) }
        return (order + untouched).compactMap { byID[$0]?.sanitized }
    }
}
