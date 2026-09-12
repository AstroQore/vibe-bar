import Foundation

/// Merges a freshly fetched roster into the stored one.
///
/// Configuration survives: a device already in `settings.json` keeps its
/// slides, orientation, cadence and task keys, and only learns its current
/// alias and panel profile. A device the account no longer lists is kept too —
/// a roster fetch that fails halfway, or a device temporarily off the account,
/// must not silently delete the slides someone spent time arranging.
public enum EInkDeviceMerge {
    /// `availableQuotaFieldIDs` is what the account's cached quotas actually
    /// expose, so a device discovered on (say) a Gemini-only account gets a
    /// slide whose rows will draw rather than the global default order's.
    public static func merge(
        discovered: [DotDevice],
        into existing: [EInkDeviceConfig],
        availableQuotaFieldIDs: [String] = []
    ) -> [EInkDeviceConfig] {
        var byID = Dictionary(existing.map { ($0.deviceID, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []

        for device in discovered where !device.id.isEmpty {
            guard let profile = device.profile else {
                // A model this build has never been measured against. Every
                // layout here is authored for a 296 x 152 1-bit panel, and the
                // encoder's rotation offsets are that panel's; adopting an
                // unknown one as a Quote/0 would send it a payload sized for a
                // screen it does not have. A device already configured is left
                // alone — it was set up under a build that knew its model.
                if let existing = byID[device.id] {
                    byID[device.id] = existing
                    order.append(device.id)
                }
                continue
            }
            var config = byID[device.id] ?? EInkDeviceConfig(
                deviceID: device.id,
                slides: [EInkSlide.defaultQuotaSlide(
                    available: EInkSlide.defaultQuotaFieldIDs(live: availableQuotaFieldIDs)
                )]
            )
            config.alias = device.alias
            config.profile = profile
            byID[device.id] = config
            order.append(device.id)
        }

        let discoveredIDs = Set(order)
        let untouched = existing.map(\.deviceID).filter { !discoveredIDs.contains($0) }
        return (order + untouched).compactMap { byID[$0]?.sanitized }
    }
}
