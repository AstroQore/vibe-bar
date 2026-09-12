import Foundation

/// Reads and writes `~/.vibebar/eink_state.json`.
///
/// Deliberately tiny and synchronous: the file is a few hundred bytes, it is
/// written once per refresh pass (not per tick), and the sync service is
/// already on the main actor. An unreadable file is treated as an empty one —
/// the state is entirely derived, so losing it costs one redundant push.
public struct EInkSyncStateStore: Sendable {
    public let url: URL

    public init(url: URL = VibeBarLocalStore.einkStateURL) {
        self.url = url
    }

    /// Explicit-home variant, so a test or a demo tree never touches the real
    /// `~/.vibebar` (see AGENTS.md § 6.4).
    public init(homeDirectory: String) {
        self.init(url: VibeBarLocalStore.einkStateURL(homeDirectory: homeDirectory))
    }

    public func load() -> EInkSyncState {
        guard let data = try? Data(contentsOf: url) else { return EInkSyncState() }
        guard let state = try? Self.decoder.decode(EInkSyncState.self, from: data) else {
            return EInkSyncState()
        }
        return state
    }

    public func save(_ state: EInkSyncState) throws {
        var copy = state
        copy.version = EInkSyncState.currentVersion
        let data = try Self.encoder.encode(copy)
        try VibeBarLocalStore.writeData(data, to: url, base: url.deletingLastPathComponent())
    }

    /// Best-effort write for the sync loop: a state file that cannot be
    /// written must not fail a push that already reached the device.
    public func saveQuietly(_ state: EInkSyncState) {
        do {
            try save(state)
        } catch {
            SafeLog.warn("eink state not persisted: \(SafeLog.sanitize(String(describing: error)))")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Serializes E-ink state writes on a background actor.
///
/// The file is small, but the sync engine writes it after every push, every
/// status read and every loop scan — a hot path on the main actor, which is
/// where CLAUDE.md rule 0 draws the line. The engine hands over the bytes and
/// returns; the write happens here, one at a time and in order.
public actor EInkSyncStateWriter {
    private let store: EInkSyncStateStore

    public init(store: EInkSyncStateStore) {
        self.store = store
    }

    public func write(_ state: EInkSyncState) {
        store.saveQuietly(state)
    }
}
