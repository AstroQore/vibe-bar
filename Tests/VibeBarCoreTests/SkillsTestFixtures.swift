import Foundation
@testable import VibeBarCore

/// Disposable home directory for the skills tests: `<tmp>/VibeBarSkills-<uuid>`
/// standing in for the user's real home, torn down when the test's reference
/// goes away. Every path in these tests is synthetic — nothing reads or writes
/// the machine's actual `~/.agents`, `~/.claude`, or `~/.vibebar`.
final class SkillTestHome {
    let url: URL

    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarSkills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var ssot: URL { SkillAppCatalog.ssotDirectory(homeDirectory: path) }

    func appDirectory(_ app: SkillAppTarget) -> URL {
        SkillAppCatalog.skillsDirectory(for: app, homeDirectory: path)
    }

    @discardableResult
    func makeDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ contents: String, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Builds a minimal skill directory: SKILL.md with frontmatter, plus any
    /// extra files given as `relative path: contents`.
    @discardableResult
    func makeSkillDirectory(
        at url: URL,
        name: String? = nil,
        description: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> URL {
        try makeDirectory(url)
        var frontmatter = "---\n"
        frontmatter += "name: \(name ?? url.lastPathComponent)\n"
        if let description { frontmatter += "description: \"\(description)\"\n" }
        frontmatter += "---\n\n# \(url.lastPathComponent)\n"
        try write(frontmatter, to: url.appendingPathComponent("SKILL.md"))
        for (relativePath, contents) in extraFiles {
            try write(contents, to: url.appendingPathComponent(relativePath))
        }
        return url
    }

    @discardableResult
    func makeSSOTSkill(
        _ directoryName: String,
        name: String? = nil,
        description: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> URL {
        try makeSkillDirectory(
            at: ssot.appendingPathComponent(directoryName, isDirectory: true),
            name: name,
            description: description,
            extraFiles: extraFiles
        )
    }

    /// Creates a symlink with an exact target string, so tests can build the
    /// absolute, relative, and dangling links a real machine has.
    func makeSymlink(_ entryName: String, in app: SkillAppTarget, rawTarget: String) throws {
        let directory = appDirectory(app)
        try makeDirectory(directory)
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent(entryName).path,
            withDestinationPath: rawTarget
        )
    }

    func makeAbsoluteSymlink(_ entryName: String, in app: SkillAppTarget, toSSOT ssotName: String) throws {
        try makeSymlink(
            entryName,
            in: app,
            rawTarget: ssot.appendingPathComponent(ssotName, isDirectory: true).path
        )
    }

    func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool {
        SkillFileSystem.kind(of: url) != .missing
    }

    /// lstat snapshot of every path under the home directory: type, inode,
    /// size, and mtime. Import must leave this byte-for-byte identical.
    func lstatSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        let fm = FileManager.default
        var stack = [url]
        while let current = stack.popLast() {
            guard let attributes = try? fm.attributesOfItem(atPath: current.path) else { continue }
            let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "?"
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? "?"
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let relative = String(current.path.dropFirst(url.path.count))
            snapshot[relative] = "\(type)|\(inode)|\(size)|\(mtime)"
            guard type == FileAttributeType.typeDirectory.rawValue else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: current.path)) ?? [] {
                stack.append(current.appendingPathComponent(name))
            }
        }
        return snapshot
    }
}
