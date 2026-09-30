import Foundation

/// A live, read-only entry in the shared root. Discovery never registers a
/// skill or grants ownership of a linked directory to Vibe Bar.
public struct SharedSkillDiscovery: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case ready, brokenLink, cyclicLink, missingSkillFile, unreadable, tooLarge
    }
    public enum Availability: Hashable, Sendable { case available, disabled, unknown }

    public let directoryName: String
    public let name: String
    public let description: String?
    public let logicalURL: URL
    public let resolvedURL: URL?
    public let isSymlink: Bool
    public let state: State
    public internal(set) var agents: [SkillAppTarget: Availability] = [:]
    public internal(set) var projectedTo: Set<SkillAppTarget> = []
    public var id: String { logicalURL.path }
}

public enum SharedSkillReadError: Error {
    case invalidDirectory, changedSource, unavailable(SharedSkillDiscovery.State)
}

/// Owned by SkillsService's actor. Only the declared shared entries and
/// their SKILL.md metadata are read; linked trees are never recursively
/// hashed, copied, updated, or removed by this scanner.
final class SharedSkillDiscoveryScanner {
    static let maximumPreviewBytes = 256 * 1024
    private let homeDirectory: String
    private var metadata: [String: (stamp: String, value: SkillFrontmatterParser.Frontmatter)] = [:]

    init(homeDirectory: String) { self.homeDirectory = homeDirectory }

    func scan(excludingDirectories: Set<String>) -> [SharedSkillDiscovery] {
        let root = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let excluded = Set(excludingDirectories.map { $0.lowercased() })
        let result = names.sorted().compactMap { name -> SharedSkillDiscovery? in
            guard !name.hasPrefix("."), SkillPathValidator.isValid(name), !excluded.contains(name.lowercased()) else { return nil }
            let kind = SkillFileSystem.kind(of: root.appendingPathComponent(name))
            guard kind == .directory || kind == .symlink else { return nil }
            return entry(name: name)
        }
        let live = Set(result.map(\.id))
        metadata = metadata.filter { live.contains($0.key) }
        return result
    }

    func preview(_ snapshot: SharedSkillDiscovery) throws -> String {
        guard SkillPathValidator.isValid(snapshot.directoryName),
              snapshot.logicalURL.standardizedFileURL == SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)
                .appendingPathComponent(snapshot.directoryName).standardizedFileURL else {
            throw SharedSkillReadError.invalidDirectory
        }
        let current = entry(name: snapshot.directoryName)
        guard current.state == .ready, let resolved = current.resolvedURL else {
            throw SharedSkillReadError.unavailable(current.state)
        }
        guard resolved == snapshot.resolvedURL else { throw SharedSkillReadError.changedSource }
        let data = try boundedRead(resolved.appendingPathComponent("SKILL.md"), limit: Self.maximumPreviewBytes)
        return String(decoding: data, as: UTF8.self)
    }

    private func entry(name: String) -> SharedSkillDiscovery {
        let logical = SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory).appendingPathComponent(name)
        let linked = SkillFileSystem.kind(of: logical) == .symlink
        func item(_ state: SharedSkillDiscovery.State, resolved: URL? = nil,
                  frontmatter: SkillFrontmatterParser.Frontmatter = .empty) -> SharedSkillDiscovery {
            .init(directoryName: name, name: frontmatter.name ?? name, description: frontmatter.description,
                  logicalURL: logical, resolvedURL: resolved, isSymlink: linked, state: state)
        }
        var cursor = logical.standardizedFileURL
        var seen: Set<String> = []
        for _ in 0..<40 {
            guard seen.insert(cursor.path).inserted else { return item(.cyclicLink) }
            switch SkillFileSystem.kind(of: cursor) {
            case .symlink:
                guard let next = SkillFileSystem.lexicalSymlinkTarget(of: cursor) else { return item(.unreadable) }
                cursor = next
            case .directory:
                let resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
                let skillFile = resolved.appendingPathComponent("SKILL.md")
                let canonicalFile = skillFile.resolvingSymlinksInPath().standardizedFileURL
                guard SkillAppCatalog.isPath(canonicalFile, under: resolved) else { return item(.unreadable, resolved: resolved) }
                guard SkillFileSystem.kind(of: canonicalFile) == .regularFile else { return item(.missingSkillFile, resolved: resolved) }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonicalFile.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue else { return item(.unreadable, resolved: resolved) }
                guard size <= Self.maximumPreviewBytes else { return item(.tooLarge, resolved: resolved) }
                let stamp = "\(resolved.path):\(size):\(attributes[.modificationDate] ?? ""): \(attributes[.systemFileNumber] ?? "")"
                let frontmatter: SkillFrontmatterParser.Frontmatter
                if let cached = metadata[logical.path], cached.stamp == stamp { frontmatter = cached.value }
                else {
                    guard let data = try? boundedRead(canonicalFile, limit: 16 * 1024, allowTruncation: true) else {
                        return item(.unreadable, resolved: resolved)
                    }
                    frontmatter = SkillFrontmatterParser.parse(String(decoding: data, as: UTF8.self))
                    metadata[logical.path] = (stamp, frontmatter)
                }
                return item(.ready, resolved: resolved, frontmatter: frontmatter)
            case .missing: return item(linked ? .brokenLink : .unreadable)
            default: return item(.missingSkillFile)
            }
        }
        return item(.unreadable)
    }

    private func boundedRead(_ url: URL, limit: Int, allowTruncation: Bool = false) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        if data.count > limit, !allowTruncation { throw SharedSkillReadError.unavailable(.tooLarge) }
        return data.prefix(limit)
    }
}
