import Foundation

/// Registry of installed skills at `~/.vibebar/skills.json`.
///
/// This file records *what Vibe Bar knows*, never the skill payloads — those
/// live in the SSOT. It is therefore disposable: deleting it loses the enable
/// bits and provenance, and the import scanner can rebuild both from the
/// filesystem.
///
/// Loading is deliberately forgiving. A skill entry that fails to decode is
/// dropped rather than taking the whole registry down with it, and app keys
/// this build does not know (a newer Vibe Bar learned another agent CLI) are
/// dropped per entry in `Skill`'s decoder.
public actor SkillsStore {
    public static let currentSchemaVersion = 1

    struct Storage: Codable, Sendable {
        var schemaVersion: Int
        var skills: [Skill]

        init(schemaVersion: Int = SkillsStore.currentSchemaVersion, skills: [Skill]) {
            self.schemaVersion = schemaVersion
            self.skills = skills
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, skills
        }

        private struct LossySkill: Decodable {
            let skill: Skill?

            init(from decoder: Decoder) throws {
                skill = try? Skill(from: decoder)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            let entries = try c.decodeIfPresent([LossySkill].self, forKey: .skills) ?? []
            self.skills = entries.compactMap(\.skill)
        }
    }

    private let fileURL: URL
    private let baseDirectory: URL
    private var cache: [Skill]?

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.fileURL = VibeBarLocalStore.skillsStoreURL(homeDirectory: homeDirectory)
        self.baseDirectory = VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
    }

    public func all() -> [Skill] {
        if let cache { return cache }
        let loaded = Self.load(from: fileURL)
        cache = loaded
        return loaded
    }

    public func skill(with id: SkillID) -> Skill? {
        all().first { $0.id == id }
    }

    public func skill(directory: String) -> Skill? {
        all().first { $0.directory == directory }
    }

    public func upsert(_ skill: Skill) throws {
        var skills = all()
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
        try save(skills)
    }

    @discardableResult
    public func remove(id: SkillID) throws -> Bool {
        var skills = all()
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return false }
        skills.remove(at: index)
        try save(skills)
        return true
    }

    public func replaceAll(_ skills: [Skill]) throws {
        try save(skills)
    }

    /// Drops the in-memory copy so the next read re-reads the file. Only
    /// needed when something outside this actor rewrote it.
    public func invalidate() {
        cache = nil
    }

    private func save(_ skills: [Skill]) throws {
        let sorted = skills.sorted { $0.directory.utf8.lexicographicallyPrecedes($1.directory.utf8) }
        let storage = Storage(skills: sorted)
        try VibeBarLocalStore.writeJSON(storage, to: fileURL, base: baseDirectory)
        cache = sorted
    }

    private static func load(from url: URL) -> [Skill] {
        guard
            let data = try? Data(contentsOf: url),
            let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { return [] }
        return storage.skills
    }
}
