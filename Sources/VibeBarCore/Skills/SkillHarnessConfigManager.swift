import Darwin
import Foundation

/// Owns the native per-skill switches exposed by agent harnesses.
///
/// Projection and activation are different facts: a Codex skill can be a
/// valid symlink in `~/.codex/skills` while `config.toml` says
/// `enabled = false`. Every mutation here re-reads, narrowly patches, backs
/// up, and atomically replaces that one file; no other Codex setting is
/// interpreted or rewritten.
struct SkillHarnessConfigManager: Sendable {
    enum NativeState: Sendable, Equatable {
        case enabled
        case disabled
        case unknown
    }

    let homeDirectory: String

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    /// Reads Codex once for the whole Skills page refresh, not once per row.
    func codexStates(for skills: [Skill]) -> [String: NativeState] {
        guard !skills.isEmpty else { return [:] }
        let config = resolvedConfigTarget(codexConfigURL)
        guard FileManager.default.fileExists(atPath: config.path) else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .enabled) })
        }
        guard let data = try? Data(contentsOf: config),
              let text = String(data: data, encoding: .utf8)
        else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .unknown) })
        }
        let blocks = Self.codexSkillBlocks(in: text)
        return Dictionary(uniqueKeysWithValues: skills.map { skill in
            let candidates = candidateSkillPaths(directoryName: skill.directory)
            let matching = blocks.filter { block in
                guard (block.path != nil) != (block.name != nil) else { return false }
                if let path = block.path {
                    return candidates.contains(Self.normalizedPath(path, homeDirectory: homeDirectory))
                }
                return block.name == skill.name
            }
            var state: NativeState = .enabled
            for block in matching {
                guard let enabled = block.enabled else {
                    state = .unknown
                    continue
                }
                state = enabled ? .enabled : .disabled
            }
            return (skill.directory, state)
        })
    }

    func claudeStates(for skills: [Skill]) -> [String: NativeState] {
        jsonNameStates(
            skills: skills,
            url: claudeSettingsURL,
            disabledNames: { root in
                let overrides = root["skillOverrides"] as? [String: Any] ?? [:]
                return Set(overrides.compactMap { key, value in
                    (value as? String) == "off" ? key.lowercased() : nil
                })
            }
        )
    }

    func geminiStates(for skills: [Skill]) -> [String: NativeState] {
        jsonNameStates(
            skills: skills,
            url: geminiSettingsURL,
            disabledNames: { root in
                let section = root["skills"] as? [String: Any] ?? [:]
                if (section["enabled"] as? Bool) == false {
                    return Set(skills.map { $0.name.lowercased() })
                }
                return Set((section["disabled"] as? [String] ?? []).map { $0.lowercased() })
            }
        )
    }

    func grokStates(for skills: [Skill]) -> [String: NativeState] {
        guard FileManager.default.fileExists(atPath: grokConfigURL.path) else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .enabled) })
        }
        guard let data = try? Data(contentsOf: grokConfigURL),
              let text = String(data: data, encoding: .utf8),
              let disabled = Self.grokDisabledNames(in: text)
        else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .unknown) })
        }
        return Dictionary(uniqueKeysWithValues: skills.map {
            ($0.directory, disabled.contains($0.name.lowercased()) ? .disabled : .enabled)
        })
    }

    /// Muse Code keeps one activation per discovered `SKILL.md`, keyed by the
    /// path as Muse spells it (`$HOME/.agents/skills/<dir>/SKILL.md`). A skill
    /// with no entry is on. `on` and `user-invocable-only` both leave it
    /// usable; `off` is the only disabled value.
    func museStates(for skills: [Skill]) -> [String: NativeState] {
        guard !skills.isEmpty else { return [:] }
        let target = resolvedConfigTarget(museSettingsURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .enabled) })
        }
        guard let data = try? Data(contentsOf: target),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.museSchemaIsKnown(root),
              let activations = Self.museUserActivations(in: root)
        else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .unknown) })
        }
        return Dictionary(uniqueKeysWithValues: skills.map { skill in
            let keys = museActivationKeys(directoryName: skill.directory)
            let values = activations.filter { keys.contains($0.key) }.map(\.value)
            let state: NativeState
            if values.isEmpty {
                state = .enabled
            } else if values.contains(where: { !Self.museKnownActivations.contains($0) }) {
                state = .unknown
            } else {
                state = values.contains("off") ? .disabled : .enabled
            }
            return (skill.directory, state)
        })
    }

    /// Mistral Vibe filters skills by name with two top-level lists in
    /// `~/.vibe/config.toml`: `enabled_skills`, which once non-empty admits
    /// only what it matches, and `disabled_skills`. Both hold
    /// case-insensitive globs or `re:` regexes.
    func mistralVibeStates(for skills: [Skill]) -> [String: NativeState] {
        guard !skills.isEmpty else { return [:] }
        let target = resolvedConfigTarget(mistralVibeConfigURL)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .enabled) })
        }
        guard let data = try? Data(contentsOf: target),
              let text = String(data: data, encoding: .utf8),
              let enabledList = Self.topLevelTOMLStringArray("enabled_skills", in: text),
              let disabledList = Self.topLevelTOMLStringArray("disabled_skills", in: text)
        else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .unknown) })
        }
        return Dictionary(uniqueKeysWithValues: skills.map { skill in
            let name = skill.name
            let state: NativeState
            if let enabledList = enabledList.list, !enabledList.isEmpty {
                state = Self.vibeNameMatches(name, enabledList) ? .enabled : .disabled
            } else if let disabledList = disabledList.list, Self.vibeNameMatches(name, disabledList) {
                state = .disabled
            } else {
                state = .enabled
            }
            return (skill.directory, state)
        })
    }

    func setNativeEnabled(
        _ enabled: Bool,
        directoryName: String,
        skillName: String,
        app: SkillAppTarget
    ) throws {
        guard app.supportsNativeSkillActivation else {
            throw SkillError.nativeActivationUnsupported(app)
        }
        switch app {
        case .codex:
            try setCodexEnabled(enabled, directoryName: directoryName, skillName: skillName)
        case .claude:
            try setClaudeEnabled(enabled, name: skillName)
        case .gemini:
            try setGeminiEnabled(enabled, name: skillName)
        case .grok:
            try setGrokEnabled(enabled, name: skillName)
        case .muse:
            try setMuseEnabled(enabled, directoryName: directoryName)
        case .mistralVibe:
            try setMistralVibeEnabled(enabled, name: skillName)
        case .hermes, .opencode, .antigravity, .cursor:
            throw SkillError.nativeActivationUnsupported(app)
        }
    }

    /// Fail before an install copies or projects anything when a selected
    /// harness cannot accept a per-skill enable. Gemini's user-level global
    /// switch is the only current case: silently turning it on would enable
    /// every other skill too, so the narrower operation explains the blocker.
    func validateCanEnable(_ app: SkillAppTarget) throws {
        if app == .mistralVibe {
            let target = resolvedConfigTarget(mistralVibeConfigURL)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            guard let data = try? Data(contentsOf: target),
                  let text = String(data: data, encoding: .utf8),
                  let enabledList = Self.topLevelTOMLStringArray("enabled_skills", in: text),
                  Self.topLevelTOMLStringArray("disabled_skills", in: text) != nil
            else { throw SkillError.nativeConfigUnreadable(.mistralVibe) }
            // An allow-list decides for every skill; Vibe Bar does not edit it.
            if enabledList.list?.isEmpty == false {
                throw SkillError.nativeSkillsGloballyDisabled(.mistralVibe)
            }
            return
        }
        if app == .muse {
            try validateMuseSettingsWritable()
            return
        }
        guard app == .gemini else { return }
        let target = resolvedConfigTarget(geminiSettingsURL)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard let data = try? Data(contentsOf: target),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SkillError.nativeConfigUnreadable(.gemini) }
        let section = root["skills"] as? [String: Any] ?? [:]
        if (section["enabled"] as? Bool) == false {
            throw SkillError.nativeSkillsGloballyDisabled(.gemini)
        }
    }

    private func jsonNameStates(
        skills: [Skill],
        url: URL,
        disabledNames: ([String: Any]) -> Set<String>
    ) -> [String: NativeState] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .enabled) })
        }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Dictionary(uniqueKeysWithValues: skills.map { ($0.directory, .unknown) })
        }
        let disabled = disabledNames(root)
        return Dictionary(uniqueKeysWithValues: skills.map {
            ($0.directory, disabled.contains($0.name.lowercased()) ? .disabled : .enabled)
        })
    }

    private func setClaudeEnabled(_ enabled: Bool, name: String) throws {
        if enabled, !FileManager.default.fileExists(atPath: resolvedConfigTarget(claudeSettingsURL).path) {
            return
        }
        try patchJSONSettings(url: claudeSettingsURL, app: .claude) { root in
            var overrides = root["skillOverrides"] as? [String: Any] ?? [:]
            if enabled {
                for key in overrides.keys where key.caseInsensitiveCompare(name) == .orderedSame {
                    overrides[key] = nil
                }
            } else {
                overrides[name] = "off"
            }
            if overrides.isEmpty { root["skillOverrides"] = nil }
            else { root["skillOverrides"] = overrides }
        }
    }

    private func setGeminiEnabled(_ enabled: Bool, name: String) throws {
        if enabled, !FileManager.default.fileExists(atPath: resolvedConfigTarget(geminiSettingsURL).path) {
            return
        }
        try patchJSONSettings(url: geminiSettingsURL, app: .gemini) { root in
            var section = root["skills"] as? [String: Any] ?? [:]
            if enabled, (section["enabled"] as? Bool) == false {
                throw SkillError.nativeSkillsGloballyDisabled(.gemini)
            }
            var disabled = section["disabled"] as? [String] ?? []
            disabled.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            if !enabled { disabled.append(name) }
            if disabled.isEmpty { section["disabled"] = nil }
            else { section["disabled"] = disabled }
            root["skills"] = section
        }
    }

    private func patchJSONSettings(
        url: URL,
        app: SkillAppTarget,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let target = resolvedConfigTarget(url)
        let existed = FileManager.default.fileExists(atPath: target.path)
        let original = existed ? (try? Data(contentsOf: target)) : Data()
        guard let original else { throw SkillError.nativeConfigUnreadable(app) }
        var root: [String: Any]
        if original.isEmpty {
            root = [:]
        } else {
            guard let decoded = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SkillError.nativeConfigUnreadable(app)
            }
            root = decoded
        }
        try mutation(&root)
        guard JSONSerialization.isValidJSONObject(root),
              let rewritten = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { throw SkillError.nativeConfigUnreadable(app) }
        let normalized = rewritten + Data("\n".utf8)
        guard normalized != original else { return }
        try backupConfig(original, sourceExists: existed, app: app, filename: target.lastPathComponent)
        try ensureConfigParent(target, app: app)
        try atomicWrite(normalized, to: target)
    }

    /// Enabling removes the entry, returning the skill to Muse's default
    /// (which also restores a skill's own `user-invocable-only`); disabling
    /// writes `off`. Only `skills.activation.user` is touched, under Muse's
    /// own `.settings.json.lock`, and a settings file with a schema this code
    /// was not written against is refused rather than rewritten.
    ///
    /// No Muse config directory means no Muse to switch off: the directory is
    /// never created from here.
    private func setMuseEnabled(_ enabled: Bool, directoryName: String) throws {
        try SkillPathValidator.validate(directoryName: directoryName)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: museSettingsURL.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }
        let target = try museWriteTarget()
        try withMuseSettingsLock(directory: target.deletingLastPathComponent()) {
            let existed = FileManager.default.fileExists(atPath: target.path)
            if enabled, !existed { return }
            let original = existed ? (try? Data(contentsOf: target)) : Data()
            guard let original else { throw SkillError.nativeConfigUnreadable(.muse) }
            var root: [String: Any]
            if original.isEmpty {
                root = [:]
            } else {
                guard let decoded = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                      Self.museSchemaIsKnown(decoded)
                else { throw SkillError.nativeConfigUnreadable(.muse) }
                root = decoded
            }
            guard root["skills"] == nil || root["skills"] is [String: Any] else {
                throw SkillError.nativeConfigUnreadable(.muse)
            }
            var skills = root["skills"] as? [String: Any] ?? [:]
            guard skills["activation"] == nil || skills["activation"] is [String: Any] else {
                throw SkillError.nativeConfigUnreadable(.muse)
            }
            var activation = skills["activation"] as? [String: Any] ?? [:]
            guard activation["user"] == nil || activation["user"] is [String: Any] else {
                throw SkillError.nativeConfigUnreadable(.muse)
            }
            var user = activation["user"] as? [String: Any] ?? [:]

            let keys = museActivationKeys(directoryName: directoryName)
            for key in user.keys where keys.contains(key) { user[key] = nil }
            if !enabled { user[Self.museCanonicalKey(directoryName: directoryName)] = "off" }

            if user.isEmpty { activation["user"] = nil } else { activation["user"] = user }
            if activation.isEmpty { skills["activation"] = nil } else { skills["activation"] = activation }
            if skills.isEmpty { root["skills"] = nil } else { root["skills"] = skills }
            if root["schema_version"] == nil { root["schema_version"] = 1 }

            guard JSONSerialization.isValidJSONObject(root),
                  let rewritten = try? JSONSerialization.data(
                      withJSONObject: root,
                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                  )
            else { throw SkillError.nativeConfigUnreadable(.muse) }
            let normalized = rewritten + Data("\n".utf8)
            guard normalized != original else { return }
            try backupConfig(original, sourceExists: existed, app: .muse, filename: target.lastPathComponent)
            try atomicWrite(normalized, to: target)
        }
    }

    /// Muse takes an exclusive lock on this sibling file around every
    /// settings write; holding it keeps a concurrent `muse skills disable`
    /// from landing between this read and this write. A lock that stays busy
    /// is reported as an unreadable config rather than waited on forever.
    private func withMuseSettingsLock(directory: URL, _ body: () throws -> Void) throws {
        let lockURL = directory.appendingPathComponent(".settings.json.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw SkillError.nativeConfigUnreadable(.muse) }
        defer { close(descriptor) }
        var acquired = false
        for _ in 0..<40 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            usleep(50_000)
        }
        guard acquired else { throw SkillError.nativeConfigUnreadable(.muse) }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    private static let museKnownActivations: Set<String> = ["on", "off", "user-invocable-only"]

    /// Muse's settings carry `schema_version: 1`; a file without one is read
    /// as that version, anything else is a format this code does not know.
    private static func museSchemaIsKnown(_ root: [String: Any]) -> Bool {
        guard let version = root["schema_version"] else { return true }
        guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return number.doubleValue == 1
    }

    /// `skills.activation.user`, or nil when any container on the way is not
    /// an object — a file the setter would refuse is not read as "all on".
    private static func museUserActivations(in root: [String: Any]) -> [String: String]? {
        guard root["skills"] == nil || root["skills"] is [String: Any] else { return nil }
        let skills = root["skills"] as? [String: Any]
        guard skills?["activation"] == nil || skills?["activation"] is [String: Any] else { return nil }
        let activation = skills?["activation"] as? [String: Any]
        guard activation?["user"] == nil || activation?["user"] is [String: Any] else { return nil }
        let user = activation?["user"] as? [String: Any] ?? [:]
        return user.reduce(into: [:]) { result, entry in
            result[entry.key] = (entry.value as? String) ?? ""
        }
    }

    /// Fail before an install copies anything when an unselected harness that
    /// reads the shared root on its own could not record the new skill as off.
    func validateCanDisable(_ app: SkillAppTarget) throws {
        switch app {
        case .muse:
            try validateMuseSettingsWritable()
        case .mistralVibe:
            let target = resolvedConfigTarget(mistralVibeConfigURL)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            // The setter writes only inside the home directory; so must the
            // file the preflight vouches for.
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
            let parent = target.deletingLastPathComponent().standardizedFileURL
            guard SkillAppCatalog.isPath(parent, under: home), parent.path != home.path else {
                throw SkillError.writeOutsideAllowedRoots(target.path)
            }
            guard let data = try? Data(contentsOf: target),
                  let text = String(data: data, encoding: .utf8),
                  Self.topLevelTOMLStringArray("enabled_skills", in: text) != nil,
                  Self.topLevelTOMLStringArray("disabled_skills", in: text) != nil
            else { throw SkillError.nativeConfigUnreadable(.mistralVibe) }
        default:
            return
        }
    }

    /// The settings file a write may touch. A symlinked `settings.json` is
    /// followed only while it stays inside the home directory: the lock and
    /// the rewrite land beside the resolved target.
    private func museWriteTarget() throws -> URL {
        let target = resolvedConfigTarget(museSettingsURL)
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard SkillAppCatalog.isPath(parent, under: home), parent.path != home.path else {
            throw SkillError.writeOutsideAllowedRoots(target.path)
        }
        return target
    }

    private func validateMuseSettingsWritable() throws {
        let target = resolvedConfigTarget(museSettingsURL)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        _ = try museWriteTarget()
        guard let data = try? Data(contentsOf: target),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.museSchemaIsKnown(root),
              Self.museUserActivations(in: root) != nil
        else { throw SkillError.nativeConfigUnreadable(.muse) }
    }

    private static func museCanonicalKey(directoryName: String) -> String {
        "$HOME/\(SkillAppCatalog.ssotRelativePath)/\(directoryName)/SKILL.md"
    }

    /// Every spelling of the shared-root `SKILL.md` Muse could have keyed:
    /// its own `$HOME/…` form, `~/…`, and the absolute path.
    private func museActivationKeys(directoryName: String) -> Set<String> {
        let relative = "\(SkillAppCatalog.ssotRelativePath)/\(directoryName)/SKILL.md"
        let absolute = canonicalSkillMD(directoryName: directoryName)
        return [
            Self.museCanonicalKey(directoryName: directoryName),
            "~/\(relative)",
            absolute.standardizedFileURL.path,
            absolute.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
    }

    /// Only `disabled_skills` is ever written: the skill's exact name is
    /// removed to enable it and added to disable it, and the rest of the file
    /// is left as it was. A config that uses `enabled_skills` is refused —
    /// that list is an allow-list whose meaning Vibe Bar does not own.
    /// Without a `~/.vibe` directory there is no Vibe to configure.
    private func setMistralVibeEnabled(_ enabled: Bool, name: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: mistralVibeConfigURL.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }
        let target = resolvedConfigTarget(mistralVibeConfigURL)
        try ensureConfigParent(target, app: .mistralVibe)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if enabled, !existed { return }
        let originalData = existed ? (try? Data(contentsOf: target)) : Data()
        guard let originalData, let original = String(data: originalData, encoding: .utf8),
              let enabledList = Self.topLevelTOMLStringArray("enabled_skills", in: original),
              let disabledList = Self.topLevelTOMLStringArray("disabled_skills", in: original)
        else { throw SkillError.nativeConfigUnreadable(.mistralVibe) }
        if let allowList = enabledList.list, !allowList.isEmpty {
            // The allow-list decides for every skill and is never edited here.
            // A skill it does not name is already off, so turning it off is
            // done; anything else cannot be switched individually.
            if !enabled, !Self.vibeNameMatches(name, allowList) { return }
            throw SkillError.nativeSkillsGloballyDisabled(.mistralVibe)
        }

        var names = disabledList.list ?? []
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if enabled, Self.vibeNameMatches(name, names) {
            // A glob or `re:` entry still names the skill. Removing only the
            // exact entry would report success while Vibe keeps it off.
            throw SkillError.nativeSkillDisabledByPattern(.mistralVibe)
        }
        if !enabled { names.append(name) }

        var lines = original.components(separatedBy: "\n")
        let assignment = "disabled_skills = ["
            + names.map { "\"\(Self.escapeTOML($0))\"" }.joined(separator: ", ") + "]"
        if let range = disabledList.lineRange {
            lines.replaceSubrange(range, with: [assignment])
        } else if !enabled {
            let header = Self.firstTOMLTableLine(in: lines)
            if let header {
                lines.insert(contentsOf: [assignment, ""], at: header)
            } else {
                if lines.last == "" { lines.removeLast() }
                lines.append(assignment)
                lines.append("")
            }
        }
        let rewritten = Data(lines.joined(separator: "\n").utf8)
        guard rewritten != originalData else { return }
        try backupConfig(originalData, sourceExists: existed, app: .mistralVibe, filename: target.lastPathComponent)
        try atomicWrite(rewritten, to: target)
    }

    struct TOMLStringArray {
        /// `nil` when the key is absent.
        let list: [String]?
        let lineRange: Range<Int>?
    }

    /// Reads one top-level `key = ["…", …]` assignment (single- or multi-line,
    /// basic strings only). The outer optional is `nil` when the key exists
    /// but is not an array of basic strings — a value this code must not
    /// rewrite.
    static func topLevelTOMLStringArray(_ key: String, in text: String) -> TOMLStringArray? {
        let lines = text.components(separatedBy: "\n")
        let end = firstTOMLTableLine(in: lines) ?? lines.count
        guard let start = (0..<end).first(where: { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { return false }
            let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("=")
        }) else {
            return TOMLStringArray(list: nil, lineRange: nil)
        }
        // Walk characters, not lines: a `]` or `#` inside a string (a
        // `re:doc[sx]` pattern) neither closes the array nor starts a comment.
        var raw = ""
        var last = start
        var depth = 0
        var inString = false
        var escaped = false
        var closed = false
        scan: for index in start..<end {
            var line = Substring(lines[index])
            if index == start {
                guard let equal = line.firstIndex(of: "=") else { return nil }
                line = line[line.index(after: equal)...]
            }
            last = index
            for character in line {
                if inString {
                    raw.append(character)
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                    continue
                }
                switch character {
                case "#": break
                case "\"": inString = true; raw.append(character); continue
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 {
                        raw.append(character)
                        closed = true
                        break scan
                    }
                default: break
                }
                if character == "#" { break }
                raw.append(character)
            }
            raw.append(" ")
        }
        guard closed else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("["), value.hasSuffix("]"),
              let data = value.replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)
                .data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return TOMLStringArray(list: list, lineRange: start..<(last + 1))
    }

    static func firstTOMLTableLine(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let second = trimmed.dropFirst().first else { return false }
            return second.isLetter || second == "[" || second == "\"" || second == "'"
        }
    }

    /// Vibe's `name_matches`: case-insensitive `fnmatch` globs, or a
    /// case-insensitive full-match regex after `re:`.
    static func vibeNameMatches(_ name: String, _ patterns: [String]) -> Bool {
        patterns.contains { raw in
            let pattern = raw.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return false }
            if pattern.hasPrefix("re:") {
                guard let regex = try? NSRegularExpression(
                    pattern: "^(?:" + String(pattern.dropFirst(3)) + ")$",
                    options: [.caseInsensitive]
                ) else { return false }
                return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            return fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
        }
    }

    private func setGrokEnabled(_ enabled: Bool, name: String) throws {
        let target = resolvedConfigTarget(grokConfigURL)
        let existed = FileManager.default.fileExists(atPath: target.path)
        if enabled, !existed { return }
        let originalData = existed ? (try? Data(contentsOf: target)) : Data()
        guard let originalData,
              let original = String(data: originalData, encoding: .utf8)
        else { throw SkillError.nativeConfigUnreadable(.grok) }
        var lines = original.components(separatedBy: "\n")
        let table = Self.grokSkillsTable(in: lines)
        var disabled = table.flatMap { Self.grokDisabledNames(in: lines, table: $0) } ?? []
        guard table == nil || Self.grokDisabledNames(in: lines, table: table!) != nil else {
            throw SkillError.nativeConfigUnreadable(.grok)
        }
        disabled.remove(name.lowercased())
        if !enabled { disabled.insert(name.lowercased()) }
        let assignment = "disabled = [" + disabled.sorted().map { "\"\(Self.escapeTOML($0))\"" }.joined(separator: ", ") + "]"
        if let table {
            if let line = table.disabledLine {
                lines[line] = assignment
            } else {
                lines.insert(assignment, at: table.endLine)
            }
        } else {
            if lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("[skills]")
            lines.append(assignment)
            lines.append("")
        }
        let rewritten = Data(lines.joined(separator: "\n").utf8)
        guard rewritten != originalData else { return }
        try backupConfig(originalData, sourceExists: existed, app: .grok, filename: target.lastPathComponent)
        try ensureConfigParent(target, app: .grok)
        try atomicWrite(rewritten, to: target)
    }

    private func setCodexEnabled(
        _ enabled: Bool,
        directoryName: String,
        skillName: String
    ) throws {
        try SkillPathValidator.validate(directoryName: directoryName)
        let config = resolvedConfigTarget(codexConfigURL)
        let existed = FileManager.default.fileExists(atPath: config.path)
        let originalData: Data
        let original: String
        if existed {
            guard let data = try? Data(contentsOf: config),
                  let text = String(data: data, encoding: .utf8)
            else { throw SkillError.nativeConfigUnreadable(.codex) }
            originalData = data
            original = text
        } else {
            // Absence means Codex's default is enabled. Do not create a
            // shared config merely to restate that default.
            guard !enabled else { return }
            originalData = Data()
            original = ""
        }

        var lines = original.components(separatedBy: "\n")
        let candidates = candidateSkillPaths(directoryName: directoryName)
        let matching = Self.codexSkillBlocks(in: original).filter { block in
            guard (block.path != nil) != (block.name != nil) else { return false }
            if let path = block.path {
                return candidates.contains(Self.normalizedPath(path, homeDirectory: homeDirectory))
            }
            return block.name == skillName
        }

        if matching.isEmpty {
            guard !enabled else { return }
            if lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("[[skills.config]]")
            let path = Self.escapeTOML(canonicalSkillMD(directoryName: directoryName).path)
            lines.append("path = \"\(path)\"")
            lines.append("enabled = false")
            lines.append("")
        } else {
            // Codex resolves same-layer rules in file order, so changing the
            // last matching declaration is the narrowest correct patch.
            if let block = matching.last {
                if let enabledLine = block.enabledLine {
                    let indent = String(lines[enabledLine].prefix { $0 == " " || $0 == "\t" })
                    lines[enabledLine] = "\(indent)enabled = \(enabled ? "true" : "false")"
                } else {
                    lines.insert("enabled = \(enabled ? "true" : "false")", at: block.endLine)
                }
            }
        }

        let rewritten = lines.joined(separator: "\n")
        guard rewritten != original else { return }
        try backupConfig(originalData, sourceExists: existed, app: .codex, filename: config.lastPathComponent)
        try ensureConfigParent(config, app: .codex)
        try atomicWrite(Data(rewritten.utf8), to: config)
    }

    private struct CodexSkillBlock {
        let endLine: Int
        let path: String?
        let name: String?
        let enabled: Bool?
        let enabledLine: Int?
    }

    private static func codexSkillBlocks(in text: String) -> [CodexSkillBlock] {
        let lines = text.components(separatedBy: "\n")
        let starts = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "[[skills.config]]"
        }
        return starts.map { start in
            let end = ((start + 1)..<lines.count).first(where: {
                lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            }) ?? lines.count
            var path: String?
            var name: String?
            var enabled: Bool?
            var enabledLine: Int?
            for index in (start + 1)..<end {
                let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if path == nil { path = quotedValue(in: trimmed, key: "path") }
                if name == nil { name = quotedValue(in: trimmed, key: "name") }
                if let value = booleanValue(in: trimmed, key: "enabled") {
                    enabled = value
                    enabledLine = index
                }
            }
            return CodexSkillBlock(
                endLine: end,
                path: path,
                name: name,
                enabled: enabled,
                enabledLine: enabledLine
            )
        }
    }

    private static func quotedValue(in line: String, key: String) -> String? {
        guard let equal = line.firstIndex(of: "=") else { return nil }
        let lhs = line[..<equal].trimmingCharacters(in: .whitespaces)
        guard lhs == key else { return nil }
        let rhs = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        guard rhs.count >= 2, let quote = rhs.first, quote == "\"" || quote == "'" else { return nil }
        if quote == "'" {
            guard let end = rhs.dropFirst().firstIndex(of: quote) else { return nil }
            return String(rhs[rhs.index(after: rhs.startIndex)..<end])
        }
        var value = ""
        var escaped = false
        for character in rhs.dropFirst() {
            if escaped {
                switch character {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    private static func booleanValue(in line: String, key: String) -> Bool? {
        guard let equal = line.firstIndex(of: "=") else { return nil }
        let lhs = line[..<equal].trimmingCharacters(in: .whitespaces)
        guard lhs == key else { return nil }
        let value = line[line.index(after: equal)...]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }

    private struct GrokSkillsTable {
        let endLine: Int
        let disabledLine: Int?
    }

    private static func grokSkillsTable(in lines: [String]) -> GrokSkillsTable? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[skills]"
        }) else { return nil }
        let end = ((start + 1)..<lines.count).first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("[")
        }) ?? lines.count
        let disabled = ((start + 1)..<end).first(where: {
            let line = lines[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.hasPrefix("disabled") && line.contains("=")
        })
        return GrokSkillsTable(endLine: end, disabledLine: disabled)
    }

    private static func grokDisabledNames(in text: String) -> Set<String>? {
        let lines = text.components(separatedBy: "\n")
        guard let table = grokSkillsTable(in: lines) else { return [] }
        return grokDisabledNames(in: lines, table: table)
    }

    private static func grokDisabledNames(
        in lines: [String],
        table: GrokSkillsTable
    ) -> Set<String>? {
        guard let lineIndex = table.disabledLine else { return [] }
        let line = lines[lineIndex]
        guard let equal = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.index(after: equal)...]
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = raw.data(using: .utf8),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return Set(names.map { $0.lowercased() })
    }

    private static func escapeTOML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func candidateSkillPaths(directoryName: String) -> Set<String> {
        let projected = SkillAppCatalog.skillsDirectory(for: .codex, homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        return [canonicalSkillMD(directoryName: directoryName), projected]
            .reduce(into: Set<String>()) { result, url in
                result.insert(url.standardizedFileURL.path)
                result.insert(url.resolvingSymlinksInPath().standardizedFileURL.path)
            }
    }

    private static func normalizedPath(_ raw: String, homeDirectory: String) -> String {
        let expanded: String
        if raw == "~" {
            expanded = homeDirectory
        } else if raw.hasPrefix("~/") {
            expanded = homeDirectory + String(raw.dropFirst())
        } else {
            expanded = raw
        }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private func canonicalSkillMD(directoryName: String) -> URL {
        SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    private var codexDirectoryURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private var codexConfigURL: URL {
        codexDirectoryURL.appendingPathComponent("config.toml")
    }

    private var claudeSettingsURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private var geminiSettingsURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private var museSettingsURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private var mistralVibeConfigURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".vibe", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    private var grokConfigURL: URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    private func resolvedConfigTarget(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : url.standardizedFileURL
    }

    private func ensureConfigParent(_ target: URL, app: SkillAppTarget) throws {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let parent = target.deletingLastPathComponent().standardizedFileURL
        guard SkillAppCatalog.isPath(parent, under: home), parent.path != home.path else {
            throw SkillError.writeOutsideAllowedRoots(target.path)
        }
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        _ = app // makes the validated target explicit at the call site
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = attributes?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions ?? 0o600],
            ofItemAtPath: target.path
        )
    }

    private func backupConfig(
        _ data: Data,
        sourceExists: Bool,
        app: SkillAppTarget,
        filename: String
    ) throws {
        guard sourceExists else { return }
        let root = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(VibeBarLocalStore.directoryName, isDirectory: true)
            .appendingPathComponent("skill_backups", isDirectory: true)
            .appendingPathComponent("harness-config", isDirectory: true)
            .appendingPathComponent(app.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = root.appendingPathComponent("\(stamp)-\(UUID().uuidString)-\(filename)")
        try data.write(to: destination)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}
