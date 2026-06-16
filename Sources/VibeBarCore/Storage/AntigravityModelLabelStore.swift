import Foundation

/// Maps AntiGravity's internal model ids to human labels.
///
/// AntiGravity reports usage under opaque ids — `MODEL_PLACEHOLDER_M132`,
/// `MODEL_PLACEHOLDER_M20`, … — both in the cost trajectories and in the
/// `GetUserStatus` model config. `GetUserStatus`'s `clientModelConfigs`
/// is the one place that also carries the label (`Gemini 3.5 Flash
/// (High)`), so the quota adapter feeds those `id → label` pairs in here
/// each time it refreshes, and the cost scanner reads them back to:
///   1. show real model names instead of placeholders, and
///   2. price placeholder models at their real rate — a bare
///      `MODEL_PLACEHOLDER_*` normalizes to `antigravity-default`
///      (Sonnet rate), but the resolved label normalizes correctly
///      (e.g. "…Flash…" → the much cheaper Gemini Flash rate).
///
/// Stored at `<homeDirectory>/.vibebar/antigravity_model_labels.json`
/// and merged across sessions, since a single `GetUserStatus` only lists
/// the currently-available models.
public struct AntigravityModelLabelStore: Codable, Sendable, Equatable {
    public var labels: [String: String]

    public init(labels: [String: String] = [:]) {
        self.labels = labels
    }

    /// Resolve a raw model id to its label, or return the id unchanged
    /// when no label is known.
    public func resolve(_ modelId: String) -> String {
        labels[modelId] ?? modelId
    }

    // MARK: - Disk I/O

    public static func fileURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("antigravity_model_labels.json")
    }

    public static func load(homeDirectory: String = RealHomeDirectory.path) -> AntigravityModelLabelStore {
        let url = fileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(AntigravityModelLabelStore.self, from: data)
        else {
            return AntigravityModelLabelStore()
        }
        return store
    }

    public func save(homeDirectory: String = RealHomeDirectory.path) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        let parent = url.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// Merge new `id → label` pairs into the persisted store. Empty
    /// keys/values are dropped; the file is only rewritten when a value
    /// actually changes, so a steady-state refresh does no disk I/O.
    @discardableResult
    public static func merge(
        _ newLabels: [String: String],
        homeDirectory: String = RealHomeDirectory.path
    ) -> AntigravityModelLabelStore {
        let cleaned = newLabels.reduce(into: [String: String]()) { acc, pair in
            let id = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty && !label.isEmpty { acc[id] = label }
        }
        var store = load(homeDirectory: homeDirectory)
        guard !cleaned.isEmpty else { return store }
        var changed = false
        for (id, label) in cleaned where store.labels[id] != label {
            store.labels[id] = label
            changed = true
        }
        if changed { store.save(homeDirectory: homeDirectory) }
        return store
    }
}
