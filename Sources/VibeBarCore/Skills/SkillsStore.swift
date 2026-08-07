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

    /// Repositories the discovery browser reads by default. These are *state*,
    /// not preferences — they live here rather than in `AppSettings` because
    /// the user edits the list from the skills UI and it only ever means
    /// "where to look for skills next".
    public static let defaultDiscoverRepos = [
        "anthropics/skills",
        "ComposioHQ/awesome-claude-skills@master",
        "cexll/myclaude@master",
        "JimLiu/baoyu-skills"
    ]

    struct Storage: Codable, Sendable {
        var schemaVersion: Int
        var skills: [Skill]
        var discoverRepos: [String]

        init(
            schemaVersion: Int = SkillsStore.currentSchemaVersion,
            skills: [Skill],
            discoverRepos: [String] = SkillsStore.defaultDiscoverRepos
        ) {
            self.schemaVersion = schemaVersion
            self.skills = skills
            self.discoverRepos = discoverRepos
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, skills, discoverRepos
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
            // Absent means "never configured" and seeds the defaults; an empty
            // array means the user cleared the list and is left empty.
            self.discoverRepos = try c.decodeIfPresent([String].self, forKey: .discoverRepos)
                ?? SkillsStore.defaultDiscoverRepos
        }
    }

    private let fileURL: URL
    private let baseDirectory: URL
    private var cache: Storage?

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.fileURL = VibeBarLocalStore.skillsStoreURL(homeDirectory: homeDirectory)
        self.baseDirectory = VibeBarLocalStore.baseDirectory(homeDirectory: homeDirectory)
    }

    public func all() -> [Skill] {
        loaded().skills
    }

    // MARK: - Discovery repositories

    /// The configured list, as typed. Invalid entries are filtered by
    /// `discoverRepoRefs()` rather than dropped from the file.
    public func discoverRepos() -> [String] {
        loaded().discoverRepos
    }

    public func discoverRepoRefs() -> [SkillRepoRef] {
        var seen = Set<String>()
        return discoverRepos().compactMap(SkillRepoRef.init).filter {
            seen.insert($0.descriptor.lowercased()).inserted
        }
    }

    /// Replaces the list, keeping only well-formed references in canonical
    /// `owner/repo[@branch]` form and dropping case-insensitive duplicates.
    public func setDiscoverRepos(_ repos: [String]) throws {
        var seen = Set<String>()
        let normalized = repos.compactMap(SkillRepoRef.init)
            .map(\.descriptor)
            .filter { seen.insert($0.lowercased()).inserted }
        var storage = loaded()
        storage.discoverRepos = normalized
        try save(storage)
    }

    /// Returns `false` when `raw` is malformed or already listed.
    @discardableResult
    public func addDiscoverRepo(_ raw: String) throws -> Bool {
        guard let ref = SkillRepoRef(raw) else { return false }
        var storage = loaded()
        let existing = Set(storage.discoverRepos.map { $0.lowercased() })
        guard !existing.contains(ref.descriptor.lowercased()) else { return false }
        storage.discoverRepos.append(ref.descriptor)
        try save(storage)
        return true
    }

    @discardableResult
    public func removeDiscoverRepo(_ raw: String) throws -> Bool {
        let needle = (SkillRepoRef(raw)?.descriptor ?? raw).lowercased()
        var storage = loaded()
        let remaining = storage.discoverRepos.filter { $0.lowercased() != needle }
        guard remaining.count != storage.discoverRepos.count else { return false }
        storage.discoverRepos = remaining
        try save(storage)
        return true
    }

    public func skill(with id: SkillID) -> Skill? {
        all().first { $0.id == id }
    }

    public func skill(directory: String) -> Skill? {
        all().first { $0.directory == directory }
    }

    public func upsert(_ skill: Skill) throws {
        var storage = loaded()
        if let index = storage.skills.firstIndex(where: { $0.id == skill.id }) {
            storage.skills[index] = skill
        } else {
            storage.skills.append(skill)
        }
        try save(storage)
    }

    @discardableResult
    public func remove(id: SkillID) throws -> Bool {
        var storage = loaded()
        guard let index = storage.skills.firstIndex(where: { $0.id == id }) else { return false }
        storage.skills.remove(at: index)
        try save(storage)
        return true
    }

    public func replaceAll(_ skills: [Skill]) throws {
        var storage = loaded()
        storage.skills = skills
        try save(storage)
    }

    /// Drops the in-memory copy so the next read re-reads the file. Only
    /// needed when something outside this actor rewrote it.
    public func invalidate() {
        cache = nil
    }

    private func loaded() -> Storage {
        if let cache { return cache }
        let storage = Self.load(from: fileURL)
        cache = storage
        return storage
    }

    private func save(_ storage: Storage) throws {
        var next = storage
        next.schemaVersion = Self.currentSchemaVersion
        next.skills.sort { $0.directory.utf8.lexicographicallyPrecedes($1.directory.utf8) }
        try VibeBarLocalStore.writeJSON(next, to: fileURL, base: baseDirectory)
        cache = next
    }

    private static func load(from url: URL) -> Storage {
        guard
            let data = try? Data(contentsOf: url),
            let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage(skills: [])
        }
        return storage
    }
}
