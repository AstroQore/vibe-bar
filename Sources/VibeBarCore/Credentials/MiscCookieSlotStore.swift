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
}

/// Keychain-backed list-of-cookies storage for misc providers.
///
/// Each tool maps to one Keychain entry: service
/// `com.astroqore.VibeBar.misc-secrets`, account
/// `<tool.rawValue>.cookieSlots`. The value is a JSON-encoded
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
        precondition(tool.isMisc, "MiscCookieSlotStore is misc-only; got \(tool)")
        return "\(tool.rawValue).\(slotsAccountSuffix)"
    }

    /// Read the slot list for `tool`, migrating legacy single-cookie
    /// state on first read. Returns an empty array if no cookies are
    /// configured.
    public static func slots(for tool: ToolType) -> [MiscCookieSlot] {
        guard tool.isMisc else { return [] }
        if let stored = readRaw(for: tool) {
            return stored
        }
        let migrated = LegacyCookieMigration.collectSlots(for: tool)
        if !migrated.isEmpty {
            _ = writeRaw(migrated, for: tool)
            LegacyCookieMigration.clearLegacy(for: tool)
        }
        return migrated
    }

    @discardableResult
    public static func append(_ slot: MiscCookieSlot, for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        var list = slots(for: tool)
        if let existing = list.firstIndex(where: { $0.cookieHeader == slot.cookieHeader }) {
            // Refresh the timestamp/source so the user can see they're
            // pasting the same cookie they had before.
            list[existing].importedAt = slot.importedAt
            list[existing].sourceLabel = slot.sourceLabel
            list[existing].origin = slot.origin
        } else {
            list.append(slot)
        }
        return writeRaw(list, for: tool)
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
        guard tool.isMisc else { return false }
        var list = slots(for: tool)
        guard let idx = list.firstIndex(where: { $0.id == slotID }) else { return false }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        list[idx].cookieHeader = trimmed
        if let sourceLabel { list[idx].sourceLabel = sourceLabel }
        if let importedAt { list[idx].importedAt = importedAt }
        if let origin { list[idx].origin = origin }
        return writeRaw(list, for: tool)
    }

    @discardableResult
    public static func delete(slotID: UUID, for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        var list = slots(for: tool)
        let before = list.count
        list.removeAll { $0.id == slotID }
        guard list.count != before else { return false }
        if list.isEmpty {
            return deleteRaw(for: tool)
        }
        return writeRaw(list, for: tool)
    }

    @discardableResult
    public static func deleteAll(for tool: ToolType) -> Bool {
        guard tool.isMisc else { return false }
        return deleteRaw(for: tool)
    }

    public static func hasAnySlot(for tool: ToolType) -> Bool {
        !slots(for: tool).isEmpty
    }

    // MARK: - Notifications

    /// Posted on every mutation (append / update / delete). The
    /// `userInfo["tool"]` carries the affected `ToolType.rawValue`.
    /// Settings UI subscribes to this so the slot list redraws when
    /// `HiddenCookieRefresher` updates a slot in the background.
    public static let didChangeNotification = Notification.Name(
        "com.astroqore.VibeBar.miscCookieSlotsChanged"
    )

    private static func postChangeNotification(for tool: ToolType) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: ["tool": tool.rawValue]
        )
    }

    // MARK: - Keychain plumbing

    private static func readRaw(for tool: ToolType) -> [MiscCookieSlot]? {
        let account = keychainAccount(for: tool)
        do {
            let data = try KeychainStore.readData(
                service: keychainService,
                account: account,
                useDataProtectionKeychain: true
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
    private static func writeRaw(_ slots: [MiscCookieSlot], for tool: ToolType) -> Bool {
        let account = keychainAccount(for: tool)
        guard !slots.isEmpty else {
            return deleteRaw(for: tool)
        }
        do {
            let data = try Self.encoder().encode(slots)
            try KeychainStore.writeData(
                service: keychainService,
                account: account,
                data: data,
                useDataProtectionKeychain: true
            )
            postChangeNotification(for: tool)
            return true
        } catch {
            SafeLog.error("MiscCookieSlotStore write failed for \(tool.rawValue): \(error)")
            return false
        }
    }

    @discardableResult
    private static func deleteRaw(for tool: ToolType) -> Bool {
        let account = keychainAccount(for: tool)
        do {
            try KeychainStore.deleteItem(
                service: keychainService,
                account: account,
                useDataProtectionKeychain: true
            )
            postChangeNotification(for: tool)
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
