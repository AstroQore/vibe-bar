import CryptoKit
import Foundation

/// The folders a skill comparison may read from: the shared library, every
/// harness skills folder, every harness built-in folder, and Vibe Bar's own
/// skill backups. Read-only — nothing here is ever a write root.
///
/// The roots are compared *after* resolving symlinks on both sides, so a
/// harness folder that is itself a link into a dotfiles checkout still
/// vouches for the skills inside it, while a skill entry that links to
/// `~/Documents` (or anywhere else) is refused instead of read.
public struct SkillReadScope: Sendable, Hashable {
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    public static func standard(homeDirectory: String = RealHomeDirectory.path) -> SkillReadScope {
        let apps = SkillAppTarget.allCases
        let roots = [SkillAppCatalog.ssotDirectory(homeDirectory: homeDirectory)]
            + apps.map { SkillAppCatalog.skillsDirectory(for: $0, homeDirectory: homeDirectory) }
            + apps.flatMap { SkillAppCatalog.builtInSkillRoots(for: $0, homeDirectory: homeDirectory) }
            + [VibeBarLocalStore.skillBackupsDirectoryURL(homeDirectory: homeDirectory)]
        return SkillReadScope(roots: roots)
    }

    /// `url` with every symlink resolved, when that lands on a real directory
    /// strictly inside one of the roots; `nil` otherwise. A root itself is
    /// never a skill, so it is refused too.
    public func resolvedSkillDirectory(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard SkillFileSystem.kind(of: resolved) == .directory else { return nil }
        let path = resolved.path
        let inside = roots.contains { root in
            path.hasPrefix(root.path + "/")
        }
        return inside ? resolved : nil
    }
}

/// Size and digest of one file — all that is shown for a binary or an
/// oversized file.
public struct SkillFileFacts: Sendable, Hashable {
    public let size: UInt64
    public let sha256: String

    public init(size: UInt64, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }
}

/// One non-hidden entry of a skill tree, keyed by its relative POSIX path.
/// Symlinks inside a tree are recorded as their target string and never
/// followed — the same rule `SkillDirectoryHasher` uses, so "identical" here
/// and "identical" in the copies list cannot disagree.
public struct SkillTreeEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file(SkillFileFacts)
        case symlink(target: String)
    }

    public let path: String
    public let kind: Kind
}

public enum SkillFileChange: String, Sendable, Hashable, CaseIterable {
    case added
    case removed
    case modified
    case unchanged
}

/// One row of a tree comparison. `left` is the base, `right` the version
/// being compared with it.
public struct SkillFileComparison: Sendable, Hashable, Identifiable {
    public let path: String
    public let change: SkillFileChange
    public let left: SkillTreeEntry?
    public let right: SkillTreeEntry?

    public var id: String { path }
}

public struct SkillTreeComparison: Sendable, Hashable {
    /// `SKILL.md` first, then the rest in path order.
    public let files: [SkillFileComparison]
    /// A side held more than `SkillDiffLimits.maxFiles` entries; only the
    /// first ones (in path order) were compared.
    public let truncated: Bool

    public func count(_ change: SkillFileChange) -> Int {
        files.count { $0.change == change }
    }

    public var isIdentical: Bool {
        !truncated && files.allSatisfy { $0.change == .unchanged }
    }

    /// The file a detail view opens on: `SKILL.md` when present, otherwise
    /// the first changed file, otherwise the first file.
    public var defaultSelection: String? {
        if files.contains(where: { $0.path == "SKILL.md" }) { return "SKILL.md" }
        return files.first { $0.change != .unchanged }?.path ?? files.first?.path
    }
}

/// Bounds that keep a comparison cheap enough for a background task the
/// user is waiting on.
public struct SkillDiffLimits: Sendable, Hashable {
    /// Entries read per tree.
    public var maxFiles: Int
    /// Larger files are shown as size and hash only.
    public var maxTextBytes: Int
    /// Either side longer than this is shown as size and hash only: the line
    /// diff is O((N+M)·D) and an unbounded one would pin a core.
    public var maxLines: Int
    /// Unchanged lines kept around each change.
    public var contextLines: Int

    public init(maxFiles: Int = 2_000, maxTextBytes: Int = 512 * 1024, maxLines: Int = 8_000, contextLines: Int = 3) {
        self.maxFiles = maxFiles
        self.maxTextBytes = maxTextBytes
        self.maxLines = maxLines
        self.contextLines = contextLines
    }

    public static let standard = SkillDiffLimits()
}

public enum SkillDiffError: Error, Equatable, Sendable {
    /// The directory resolves outside `SkillReadScope`, is missing, or is
    /// not a directory.
    case outsideScope(String)
    /// A relative path that names a hidden entry, `..`, or an absolute path.
    case invalidRelativePath(String)
}

/// A line-level diff of two text files.
public struct SkillLineDiff: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case context
            case added
            case removed
        }

        public let kind: Kind
        /// 1-based line number on the base side; `nil` for an added line.
        public let oldNumber: Int?
        /// 1-based line number on the compared side; `nil` for a removed line.
        public let newNumber: Int?
        public let text: String
    }

    public struct Hunk: Sendable, Hashable, Identifiable {
        public let id: Int
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let lines: [Line]

        /// `@@ -a,b +c,d @@`, the unified-diff header. Not localized: it is
        /// a format, like a path.
        public var header: String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }
    }

    /// One row of the side-by-side view.
    public struct Row: Sendable, Hashable {
        public let left: Line?
        public let right: Line?
    }

    public let hunks: [Hunk]
    public let addedCount: Int
    public let removedCount: Int

    public var isIdentical: Bool { hunks.isEmpty }

    /// Diff of two line arrays, grouped into hunks with `context` unchanged
    /// lines around each change. The common prefix and suffix are trimmed
    /// before `CollectionDifference` runs, which keeps the typical "one
    /// paragraph edited" case linear.
    public static func compute(old: [String], new: [String], context: Int = 3) -> SkillLineDiff {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = old[prefix ..< old.count - suffix]
        let newMiddle = new[prefix ..< new.count - suffix]
        let difference = Array(newMiddle).difference(from: Array(oldMiddle))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset + prefix)
            case let .insert(offset, _, _): inserted.insert(offset + prefix)
            }
        }

        // Walk both sides once; a removal is emitted before the insertion
        // that replaces it, which is what both views expect.
        var all: [Line] = []
        all.reserveCapacity(max(old.count, new.count) + inserted.count)
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                all.append(Line(kind: .removed, oldNumber: i + 1, newNumber: nil, text: old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                all.append(Line(kind: .added, oldNumber: nil, newNumber: j + 1, text: new[j]))
                j += 1
            } else if i < old.count, j < new.count {
                all.append(Line(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: old[i]))
                i += 1
                j += 1
            } else {
                // Unreachable for a consistent difference; bail rather than spin.
                break
            }
        }

        let changed = all.indices.filter { all[$0].kind != .context }
        var hunks: [Hunk] = []
        var start = 0
        while start < changed.count {
            var end = start
            while end + 1 < changed.count, changed[end + 1] - changed[end] <= context * 2 + 1 {
                end += 1
            }
            let lower = max(0, changed[start] - context)
            let upper = min(all.count - 1, changed[end] + context)
            let lines = Array(all[lower ... upper])
            let oldLines = lines.filter { $0.kind != .added }
            let newLines = lines.filter { $0.kind != .removed }
            // Unified-diff convention: an empty side starts at the line
            // *before* the hunk.
            let oldStart = oldLines.first?.oldNumber ?? lines.compactMap(\.oldNumber).first
                ?? (all[..<lower].last { $0.oldNumber != nil }?.oldNumber ?? 0)
            let newStart = newLines.first?.newNumber ?? lines.compactMap(\.newNumber).first
                ?? (all[..<lower].last { $0.newNumber != nil }?.newNumber ?? 0)
            hunks.append(Hunk(
                id: hunks.count,
                oldStart: oldStart,
                oldCount: oldLines.count,
                newStart: newStart,
                newCount: newLines.count,
                lines: lines
            ))
            start = end + 1
        }
        return SkillLineDiff(hunks: hunks, addedCount: inserted.count, removedCount: removed.count)
    }

    /// Pairs a hunk's lines for a two-column view: context lines sit on both
    /// sides; a run of removals followed by a run of additions is laid out
    /// line against line, the shorter side padded with empty cells.
    public static func sideBySideRows(_ hunk: Hunk) -> [Row] {
        var rows: [Row] = []
        var removedRun: [Line] = []
        var addedRun: [Line] = []
        func flush() {
            for index in 0 ..< max(removedRun.count, addedRun.count) {
                rows.append(Row(
                    left: index < removedRun.count ? removedRun[index] : nil,
                    right: index < addedRun.count ? addedRun[index] : nil
                ))
            }
            removedRun = []
            addedRun = []
        }
        for line in hunk.lines {
            switch line.kind {
            case .context:
                flush()
                rows.append(Row(left: line, right: line))
            case .removed:
                // A removal after additions starts a new replacement block.
                if !addedRun.isEmpty { flush() }
                removedRun.append(line)
            case .added:
                addedRun.append(line)
            }
        }
        flush()
        return rows
    }
}

/// What a detail view shows for one selected file.
public enum SkillFileDiff: Sendable, Hashable {
    case text(SkillLineDiff)
    /// Either side is not UTF-8 text (or holds a NUL byte).
    case binary(left: SkillFileFacts?, right: SkillFileFacts?)
    /// Either side exceeds `SkillDiffLimits.maxTextBytes` or `maxLines`.
    case tooLarge(left: SkillFileFacts?, right: SkillFileFacts?)
    /// Either side is a symlink inside the tree; its target is the content.
    /// The other side keeps its own identity — a regular file shows its
    /// facts rather than reading as absent.
    case symlink(left: SkillDiffSide, right: SkillDiffSide)
    case unreadable
}

/// One side of a diff that could not be compared line by line.
public enum SkillDiffSide: Sendable, Hashable {
    case absent
    case symlink(target: String)
    case file(SkillFileFacts)
}

/// Read-only comparison of two skill directories.
///
/// Every path is checked against a `SkillReadScope` before it is opened, the
/// walk never follows a symlink, and a single file is re-validated (no hidden
/// component, no `..`, no symlinked parent) before its bytes are read. Nothing
/// here writes.
public enum SkillContentDiff {
    /// Lists one tree: every non-hidden regular file and symlink, hashed.
    /// `directory` must already be a resolved, in-scope skill directory.
    public static func listing(
        of directory: URL,
        limits: SkillDiffLimits = .standard
    ) throws -> (entries: [String: SkillTreeEntry], truncated: Bool) {
        var found: [(path: String, url: URL, isSymlink: Bool)] = []
        var truncated = false
        try collect(directory: directory, relativePath: "", into: &found, limit: limits.maxFiles, truncated: &truncated)
        var entries: [String: SkillTreeEntry] = [:]
        for item in found {
            if item.isSymlink {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)) ?? ""
                entries[item.path] = SkillTreeEntry(path: item.path, kind: .symlink(target: target))
            } else if let facts = facts(of: item.url) {
                entries[item.path] = SkillTreeEntry(path: item.path, kind: .file(facts))
            }
        }
        return (entries, truncated)
    }

    /// File-level comparison of two in-scope skill directories. `left` is the
    /// base. Either may be `nil` for "this version has no readable tree", in
    /// which case every file of the other side is added or removed.
    public static func compare(
        left: URL?,
        right: URL?,
        scope: SkillReadScope,
        limits: SkillDiffLimits = .standard
    ) throws -> SkillTreeComparison {
        let leftListing = try left.map { try listing(of: try resolve($0, in: scope), limits: limits) }
        let rightListing = try right.map { try listing(of: try resolve($0, in: scope), limits: limits) }
        let leftEntries = leftListing?.entries ?? [:]
        let rightEntries = rightListing?.entries ?? [:]
        let paths = Set(leftEntries.keys).union(rightEntries.keys)
        let files = paths.map { path -> SkillFileComparison in
            let l = leftEntries[path]
            let r = rightEntries[path]
            let change: SkillFileChange = switch (l, r) {
            case (nil, _): .added
            case (_, nil): .removed
            case let (l?, r?): l.kind == r.kind ? .unchanged : .modified
            }
            return SkillFileComparison(path: path, change: change, left: l, right: r)
        }
        .sorted { lhs, rhs in
            if (lhs.path == "SKILL.md") != (rhs.path == "SKILL.md") { return lhs.path == "SKILL.md" }
            return lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8)
        }
        return SkillTreeComparison(
            files: files,
            truncated: (leftListing?.truncated ?? false) || (rightListing?.truncated ?? false)
        )
    }

    /// The line diff of one relative path between two in-scope trees. A side
    /// that lacks the file reads as empty, so an added file is all additions.
    public static func diffFile(
        path: String,
        left: URL?,
        right: URL?,
        scope: SkillReadScope,
        limits: SkillDiffLimits = .standard
    ) -> SkillFileDiff {
        guard isSafeRelativePath(path) else { return .unreadable }
        let leftSide: Side
        let rightSide: Side
        do {
            leftSide = try side(path: path, root: left.map { try resolve($0, in: scope) })
            rightSide = try side(path: path, root: right.map { try resolve($0, in: scope) })
        } catch {
            return .unreadable
        }
        switch (leftSide, rightSide) {
        case (.unreadable, _), (_, .unreadable), (.absent, .absent):
            return .unreadable
        case (.symlink, _), (_, .symlink):
            return .symlink(left: leftSide.summary, right: rightSide.summary)
        default:
            break
        }
        let leftData = leftSide.data
        let rightData = rightSide.data
        let leftFacts = leftData.map(facts(of:))
        let rightFacts = rightData.map(facts(of:))
        if (leftData?.count ?? 0) > limits.maxTextBytes || (rightData?.count ?? 0) > limits.maxTextBytes {
            return .tooLarge(left: leftFacts, right: rightFacts)
        }
        guard let oldLines = leftData.map(textLines) ?? [], let newLines = rightData.map(textLines) ?? [] else {
            return .binary(left: leftFacts, right: rightFacts)
        }
        if oldLines.count > limits.maxLines || newLines.count > limits.maxLines {
            return .tooLarge(left: leftFacts, right: rightFacts)
        }
        return .text(SkillLineDiff.compute(old: oldLines, new: newLines, context: limits.contextLines))
    }

    /// Lines of a UTF-8 text payload, or `nil` for binary. A trailing newline
    /// does not produce an empty last line; `\r\n` reads as one break.
    static func textLines(_ data: Data) -> [String]? {
        if data.isEmpty { return [] }
        if data.prefix(8_192).contains(0) { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    // MARK: - Internals

    private enum Side {
        case absent
        case file(Data)
        case symlink(String)
        case unreadable

        var data: Data? {
            switch self {
            case .absent: Data()
            case let .file(data): data
            case .symlink, .unreadable: nil
            }
        }

        var summary: SkillDiffSide {
            switch self {
            case .absent, .unreadable: .absent
            case let .symlink(target): .symlink(target: target)
            case let .file(data): .file(SkillContentDiff.facts(of: data))
            }
        }
    }

    private static func resolve(_ url: URL, in scope: SkillReadScope) throws -> URL {
        guard let resolved = scope.resolvedSkillDirectory(url) else {
            throw SkillDiffError.outsideScope(url.path)
        }
        return resolved
    }

    /// Reads `path` under `root` without following any link: every
    /// intermediate component must be a real directory, and the leaf a
    /// regular file or a symlink (whose target string is the content).
    private static func side(path: String, root: URL?) -> Side {
        guard let root else { return .absent }
        let components = path.split(separator: "/").map(String.init)
        var current = root
        for (index, component) in components.enumerated() {
            current = current.appendingPathComponent(component)
            let kind = SkillFileSystem.kind(of: current)
            let isLeaf = index == components.count - 1
            switch (kind, isLeaf) {
            case (.missing, _): return .absent
            case (.directory, false): continue
            case (.regularFile, true):
                guard let data = readRegularFile(current) else { return .unreadable }
                return .file(data)
            case (.symlink, true):
                return .symlink((try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) ?? "")
            default:
                // A symlinked or special intermediate component, or a leaf
                // that is a directory: not something this view reads.
                return .unreadable
            }
        }
        return .unreadable
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && !component.hasPrefix(".")
        }
    }

    /// Opens `url` for reading without following a symlink at the leaf, and
    /// only if what was opened is a regular file. `kind(of:)` is checked
    /// before every read, but a link swapped in between that check and the
    /// open would otherwise be followed — possibly out of scope. Validating
    /// the descriptor itself closes that window.
    private static func openRegularFile(_ url: URL) -> FileHandle? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func readRegularFile(_ url: URL) -> Data? {
        guard let handle = openRegularFile(url) else { return nil }
        defer { try? handle.close() }
        return try? handle.readToEnd() ?? Data()
    }

    private static func facts(of url: URL) -> SkillFileFacts? {
        guard let handle = openRegularFile(url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while true {
            // `read(upToCount:)` answers EOF with `nil` *or* empty data,
            // depending on the platform; only a throw is a failed read.
            let next: Data?
            do { next = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let chunk = next, !chunk.isEmpty else { break }
            size += UInt64(chunk.count)
            hasher.update(data: chunk)
        }
        return SkillFileFacts(size: size, sha256: hex(hasher.finalize()))
    }

    static func facts(of data: Data) -> SkillFileFacts {
        SkillFileFacts(size: UInt64(data.count), sha256: hex(SHA256.hash(data: data)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(
        directory: URL,
        relativePath: String,
        into entries: inout [(path: String, url: URL, isSymlink: Bool)],
        limit: Int,
        truncated: inout Bool
    ) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path).sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for name in names where !name.hasPrefix(".") {
            if entries.count >= limit {
                truncated = true
                return
            }
            let child = directory.appendingPathComponent(name)
            let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            switch SkillFileSystem.kind(of: child) {
            case .directory:
                try collect(directory: child, relativePath: childPath, into: &entries, limit: limit, truncated: &truncated)
                if truncated { return }
            case .symlink:
                entries.append((childPath, child, true))
            case .regularFile:
                entries.append((childPath, child, false))
            case .missing, .other:
                continue
            }
        }
    }
}
