import Foundation

/// A single cookie session a user has imported for a misc provider.
///
/// Each slot stands on its own — adapters fan out a quota query per
/// slot and average the results, so users can stack multiple accounts
/// (work + personal + trial) under one provider card. Slots are stored
/// as a JSON array in Keychain alongside the rest of the misc-provider
/// secrets.
public struct MiscCookieSlot: Codable, Equatable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable, Equatable {
        /// Pasted by the user via the Settings cookie field.
        case manual
        /// Snapshotted from a browser's cookie store (SweetCookieKit) or
        /// captured by the in-app `MiscWebLoginController` web view.
        case browserImport
        /// Replaced in place by `HiddenCookieRefresher` after a silent
        /// console keepalive load.
        case autoRefresh
    }

    public let id: UUID
    public var cookieHeader: String
    public var sourceLabel: String
    public var importedAt: Date
    public var origin: Origin

    private enum CodingKeys: String, CodingKey {
        case id
        case cookieHeader
        case sourceLabel
        case importedAt
        case origin
        /// A short-lived older build wrote Web login captures as
        /// `origin = manual` plus this additive marker. Keep the key only at
        /// the decoding boundary so those browser-owned sessions rejoin the
        /// normal browser refresh path; new data never writes it again.
        case captureKind
    }

    public init(
        id: UUID = UUID(),
        cookieHeader: String,
        sourceLabel: String,
        importedAt: Date = Date(),
        origin: Origin
    ) {
        self.id = id
        self.cookieHeader = cookieHeader
        self.sourceLabel = sourceLabel
        self.importedAt = importedAt
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.cookieHeader = try container.decode(String.self, forKey: .cookieHeader)
        self.sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        self.importedAt = try container.decode(Date.self, forKey: .importedAt)

        let decodedOrigin = try container.decode(Origin.self, forKey: .origin)
        let legacyCaptureKind = try container.decodeIfPresent(String.self, forKey: .captureKind)
        if decodedOrigin == .manual, legacyCaptureKind == "webLogin" {
            self.origin = .browserImport
        } else {
            self.origin = decodedOrigin
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cookieHeader, forKey: .cookieHeader)
        try container.encode(sourceLabel, forKey: .sourceLabel)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(origin, forKey: .origin)
    }
}

/// Keychain-backed list-of-cookies storage for misc providers.
///
/// Each provider instance maps to one Keychain entry: service
/// `com.astroqore.VibeBar.misc-secrets`, account
/// `<tool.rawValue>.cookieSlots` for the default instance and
/// `<instanceID>.cookieSlots` for clones. The value is a JSON-encoded
/// `[MiscCookieSlot]`.
///
/// The store is mutable — append, update, delete — but each
/// mutation rewrites the whole list. List sizes are tiny (< 10
/// realistic upper bound), so the simplicity wins over per-slot
/// keychain entries.
///
/// Legacy single-cookie state (`MiscCredentialStore.manualCookieHeader`
/// and the old per-tool `CookieHeaderCache` entry) is migrated lazily
/// into slots on the first read, then the legacy locations are
/// cleared.
public enum MiscCookieSlotStore {
    public static let keychainService = MiscCredentialStore.keychainService

    public static let slotsAccountSuffix = "cookieSlots"

    public static func keychainAccount(for tool: ToolType) -> String {
        keychainAccount(for: tool, instanceID: tool.rawValue)
    }

    public static func keychainAccount(for tool: ToolType, instanceID: String) -> String {
        precondition(tool.isMisc, "MiscCookieSlotStore is misc-only; got \(tool)")
        if instanceID != tool.rawValue {
            return "\(instanceID).\(slotsAccountSuffix)"
        }
        return "\(tool.rawValue).\(slotsAccountSuffix)"
    }

    /// Read the slot list for `tool`, migrating legacy single-cookie
    /// state on first read. Returns an empty array if no cookies are
    /// configured.
    public static func slots(for tool: ToolType) -> [MiscCookieSlot] {
        slots(for: tool, instanceID: tool.rawValue)
    }

    public static func slots(for tool: ToolType, instanceID: String) -> [MiscCookieSlot] {
        guard tool.isMisc else { return [] }
        if let stored = readRaw(for: tool, instanceID: instanceID) {
            return stored
        }
        guard instanceID == tool.rawValue else { return [] }
        let migrated = LegacyCookieMigration.collectSlots(for: tool)
        if !migrated.isEmpty {
            _ = writeRaw(migrated, for: tool, instanceID: instanceID)
            LegacyCookieMigration.clearLegacy(for: tool)
        }
        return migrated
    }

    @discardableResult
    public static func append(_ slot: MiscCookieSlot, for tool: ToolType) -> Bool {
        append(slot, for: tool, instanceID: tool.rawValue)
    }

    @discardableResult
    public static func append(_ slot: MiscCookieSlot, for tool: ToolType, instanceID: String) -> Bool {
        guard tool.isMisc else { return false }
        var list = slots(for: tool, instanceID: instanceID)
        if let existing = list.firstIndex(where: { $0.cookieHeader == slot.cookieHeader }) {
            // Refresh the timestamp/source so the user can see they're
            // pasting the same cookie they had before.
            list[existing].importedAt = slot.importedAt
            list[existing].sourceLabel = slot.sourceLabel
            list[existing].origin = slot.origin
        } else {
            list.append(slot)
        }
        return writeRaw(list, for: tool, instanceID: instanceID)
    }

    /// Insert a system-browser session, replacing the prior snapshot from the
    /// same browser profile in place. Different profile labels still stack,
    /// while manual and WebView-labelled slots are never overwritten.
    @discardableResult
    public static func upsertBrowserImport(
        _ slot: MiscCookieSlot,
        for tool: ToolType,
        instanceID: String
    ) -> MiscCookieSlot? {
        guard tool.isMisc else { return nil }
        let merged = mergingBrowserImport(slot, into: slots(for: tool, instanceID: instanceID))
        guard writeRaw(merged.slots, for: tool, instanceID: instanceID) else { return nil }
        return merged.stored
    }

    static func mergingBrowserImport(
        _ incoming: MiscCookieSlot,
        into existing: [MiscCookieSlot]
    ) -> (slots: [MiscCookieSlot], stored: MiscCookieSlot) {
        var slots = existing
        if let index = slots.firstIndex(where: {
            $0.origin != .manual && $0.sourceLabel == incoming.sourceLabel
        }) {
            slots[index].cookieHeader = incoming.cookieHeader
            slots[index].sourceLabel = incoming.sourceLabel
            slots[index].importedAt = incoming.importedAt
            slots[index].origin = .browserImport
            return (slots, slots[index])
        }
        // Older HiddenCookieRefresher builds replaced the browser profile
        // label with the generic "Auto-refresh" marker. Reclaim that slot
        // only when it is the sole non-manual candidate; with two or more
        // browser slots there is no safe way to know which profile it came
        // from, so the incoming profile must stay stacked instead.
        let browserSlotIndices = slots.indices.filter { slots[$0].origin != .manual }
        if browserSlotIndices.count == 1,
           let index = browserSlotIndices.first,
           slots[index].origin == .autoRefresh,
           slots[index].sourceLabel == "Auto-refresh"
        {
            slots[index].cookieHeader = incoming.cookieHeader
            slots[index].sourceLabel = incoming.sourceLabel
            slots[index].importedAt = incoming.importedAt
            slots[index].origin = .browserImport
            return (slots, slots[index])
        }
        slots.append(incoming)
        return (slots, incoming)
    }

    @discardableResult
    public static func updateHeader(
        slotID: UUID,
        for tool: ToolType,
        header: String,
        sourceLabel: String? = nil,
        importedAt: Date? = nil,
        origin: MiscCookieSlot.Origin? = nil
    ) -> Bool {
        updateHeader(
            slotID: slotID,
            for: tool,
            instanceID: tool.rawValue,
            header: header,
            sourceLabel: sourceLabel,
            importedAt: importedAt,
            origin: origin
        )
    }

    @discardableResult
    public static func updateHeader(
        slotID: UUID,
        for tool: ToolType,
        instanceID: String,
        header: String,
        sourceLabel: String? = nil,
        importedAt: Date? = nil,
        origin: MiscCookieSlot.Origin? = nil
    ) -> Bool {
        guard tool.isMisc else { return false }
        var list = slots(for: tool, instanceID: instanceID)
        guard let idx = list.firstIndex(where: { $0.id == slotID }) else { return false }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        list[idx].cookieHeader = trimmed
        if let sourceLabel { list[idx].sourceLabel = sourceLabel }
        if let importedAt { list[idx].importedAt = importedAt }
        if let origin { list[idx].origin = origin }
        return writeRaw(list, for: tool, instanceID: instanceID)
    }

    @discardableResult
    public static func delete(slotID: UUID, for tool: ToolType) -> Bool {
        delete(slotID: slotID, for: tool, instanceID: tool.rawValue)
    }

    @discardableResult
    public static func delete(slotID: UUID, for tool: ToolType, instanceID: String) -> Bool {
        guard tool.isMisc else { return false }
        var list = slots(for: tool, instanceID: instanceID)
        let before = list.count
        list.removeAll { $0.id == slotID }
        guard list.count != before else { return false }
        if list.isEmpty {
            return deleteRaw(for: tool, instanceID: instanceID)
        }
        return writeRaw(list, for: tool, instanceID: instanceID)
    }

    @discardableResult
    public static func deleteAll(for tool: ToolType) -> Bool {
        deleteAll(for: tool, instanceID: tool.rawValue)
    }

    @discardableResult
    public static func deleteAll(for tool: ToolType, instanceID: String) -> Bool {
        guard tool.isMisc else { return false }
        return deleteRaw(for: tool, instanceID: instanceID)
    }

    public static func hasAnySlot(for tool: ToolType) -> Bool {
        !slots(for: tool).isEmpty
    }

    public static func hasAnySlot(for tool: ToolType, instanceID: String) -> Bool {
        !slots(for: tool, instanceID: instanceID).isEmpty
    }

    // MARK: - Notifications

    /// Posted on every mutation (append / update / delete). The
    /// `userInfo["tool"]` carries the affected `ToolType.rawValue`.
    /// Settings UI subscribes to this so the slot list redraws when
    /// `HiddenCookieRefresher` updates a slot in the background.
    public static let didChangeNotification = Notification.Name(
        "com.astroqore.VibeBar.miscCookieSlotsChanged"
    )

    private static func postChangeNotification(for tool: ToolType, instanceID: String) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: ["tool": tool.rawValue, "instanceID": instanceID]
        )
    }

    // MARK: - Keychain plumbing

    private static func readRaw(for tool: ToolType, instanceID: String) -> [MiscCookieSlot]? {
        let account = keychainAccount(for: tool, instanceID: instanceID)
        do {
            let data = try VibeBarCredentialVault.readData(
                service: keychainService,
                account: account
            )
            return try Self.decoder().decode([MiscCookieSlot].self, from: data)
        } catch KeychainStore.KeychainError.itemNotFound {
            return nil
        } catch KeychainStore.KeychainError.interactionNotAllowed {
            SafeLog.info("MiscCookieSlotStore temporarily unavailable for \(tool.rawValue)")
            return nil
        } catch {
            SafeLog.warn("MiscCookieSlotStore read failed for \(tool.rawValue): \(error)")
            return nil
        }
    }

    @discardableResult
    private static func writeRaw(_ slots: [MiscCookieSlot], for tool: ToolType, instanceID: String) -> Bool {
        let account = keychainAccount(for: tool, instanceID: instanceID)
        guard !slots.isEmpty else {
            return deleteRaw(for: tool, instanceID: instanceID)
        }
        do {
            let data = try Self.encoder().encode(slots)
            try VibeBarCredentialVault.writeData(
                service: keychainService,
                account: account,
                data: data
            )
            postChangeNotification(for: tool, instanceID: instanceID)
            return true
        } catch {
            SafeLog.error("MiscCookieSlotStore write failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    @discardableResult
    private static func deleteRaw(for tool: ToolType, instanceID: String) -> Bool {
        let account = keychainAccount(for: tool, instanceID: instanceID)
        do {
            try VibeBarCredentialVault.delete(
                service: keychainService,
                account: account
            )
            postChangeNotification(for: tool, instanceID: instanceID)
            return true
        } catch KeychainStore.KeychainError.itemNotFound {
            return false
        } catch {
            SafeLog.warn("MiscCookieSlotStore delete failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Migrates legacy single-cookie storage into the new slot list on
/// first read.
///
/// Two legacy sources exist:
///
/// 1. `MiscCredentialStore.Kind.manualCookieHeader` — the cookie the
///    user pasted in Settings.
/// 2. `CookieHeaderCache` — the cached resolved header from the last
///    successful import (browser auto-import, web login, or
///    `HiddenCookieRefresher`).
///
/// They are not mutually exclusive — a user who pasted once and then
/// also signed in via the web view will have both. The two carry
/// distinct semantics so we surface both as separate slots and let
/// the user pick which to keep.
enum LegacyCookieMigration {
    /// Collect slots from legacy storage without mutating it. Returns
    /// an empty list when nothing legacy is present. Call
    /// `clearLegacy` after the new list is durably stored.
    static func collectSlots(for tool: ToolType) -> [MiscCookieSlot] {
        guard tool.isMisc else { return [] }
        var collected: [MiscCookieSlot] = []
        var seenHeaders: Set<String> = []

        if let manual = MiscCredentialStore.readString(tool: tool, kind: .manualCookieHeader),
           !manual.isEmpty {
            collected.append(
                MiscCookieSlot(
                    cookieHeader: manual,
                    sourceLabel: "Manual paste",
                    importedAt: Date(),
                    origin: .manual
                )
            )
            seenHeaders.insert(manual)
        }

        if let cached = CookieHeaderCache.load(for: tool), !cached.cookieHeader.isEmpty {
            let header = cached.cookieHeader
            if !seenHeaders.contains(header) {
                let isAutoRefresh = cached.sourceLabel.lowercased().contains("refresh")
                collected.append(
                    MiscCookieSlot(
                        cookieHeader: header,
                        sourceLabel: cached.sourceLabel,
                        importedAt: cached.storedAt,
                        origin: isAutoRefresh ? .autoRefresh : .browserImport
                    )
                )
                seenHeaders.insert(header)
            }
        }

        return collected
    }

    static func clearLegacy(for tool: ToolType) {
        guard tool.isMisc else { return }
        MiscCredentialStore.delete(tool: tool, kind: .manualCookieHeader)
        CookieHeaderCache.clear(for: tool)
    }
}
