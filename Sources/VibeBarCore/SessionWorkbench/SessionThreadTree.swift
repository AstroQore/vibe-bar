import Foundation

/// How the Sessions list folds threads that are not a conversation of their
/// own.
///
/// A Codex session that fans out to five subagents writes six rollouts, and
/// a list that shows all six side by side buries the one the person started.
/// The parse knows what each file is (`SessionStats.kind`, `parentID`), so
/// the list nests what belongs to another session under it and keeps the
/// rest behind a filter:
///
/// - **Nested** (`subagent`, `fork`, `agentCreated`, `guardian`): placed
///   under the loaded row whose session id is its `parentID`, depth-first,
///   so a subagent's own subagent sits under it. When the parent is not
///   loaded — older than the page, filtered out, or never indexed — the row
///   stays at the top level and says it is a thread (`isOrphanThread`), so
///   nothing disappears; a `guardian` row without its parent is hidden,
///   because an Auto Review is never a session of its own (`SessionVisibleRows`).
/// - **Filtered** (`exec`, `automation`): headless runs nobody typed into.
///   Hidden unless the kind is in `showing`; counted either way.
/// - Everything else, including a row whose kind is not known yet, is a
///   root.
///
/// A child of a hidden root is hidden with it. Pure and order-preserving:
/// roots keep the input order, and each root's descendants follow it in the
/// input order of their parents.
public struct SessionThreadTree: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var id: String
        public var sessionID: String
        public var kind: SessionStructureKind?
        public var parentID: String?

        public init(id: String, sessionID: String, kind: SessionStructureKind?, parentID: String?) {
            self.id = id
            self.sessionID = sessionID
            self.kind = kind
            self.parentID = parentID
        }
    }

    public struct Node: Sendable, Hashable {
        public var id: String
        /// 0 for a root.
        public var depth: Int
        /// Every descendant, depth-first (roots only; empty for a child).
        public var descendants: [String]
        /// A nested kind whose parent is not in the list.
        public var isOrphanThread: Bool
    }

    public static let nestedKinds: Set<SessionStructureKind> = [.subagent, .fork, .agentCreated, .guardian]
    public static let filteredKinds: Set<SessionStructureKind> = [.exec, .automation]

    /// Roots in input order.
    public private(set) var roots: [Node]
    /// Descendant nodes by id (depth ≥ 1).
    public private(set) var children: [String: Node]
    /// Rows left out, by their own kind — or by their root's kind, for a
    /// child of a hidden root.
    public private(set) var hiddenCounts: [SessionStructureKind: Int]

    public init(entries: [Entry], showing: Set<SessionStructureKind> = []) {
        var bySession: [String: Int] = [:]
        for (position, entry) in entries.enumerated() {
            let key = entry.sessionID.lowercased()
            if bySession[key] == nil { bySession[key] = position }
        }

        // The loaded parent of every nested row, if any.
        var parentOf: [Int: Int] = [:]
        for (position, entry) in entries.enumerated() {
            guard let kind = entry.kind, Self.nestedKinds.contains(kind),
                  let parentID = entry.parentID?.lowercased(),
                  let parent = bySession[parentID], parent != position
            else { continue }
            parentOf[position] = parent
        }

        // Break cycles: a chain that comes back on itself loses the link that
        // closed it, so its last member becomes the root.
        for position in entries.indices {
            var current = position
            var seen: Set<Int> = [position]
            while let parent = parentOf[current] {
                guard seen.insert(parent).inserted else {
                    parentOf.removeValue(forKey: current)
                    break
                }
                current = parent
            }
        }

        var childrenOf: [Int: [Int]] = [:]
        for position in entries.indices {
            guard let parent = parentOf[position] else { continue }
            childrenOf[parent, default: []].append(position)
        }

        var hidden: [SessionStructureKind: Int] = [:]
        var roots: [Node] = []
        var children: [String: Node] = [:]

        func isHiddenRoot(_ position: Int) -> SessionStructureKind? {
            let entry = entries[position]
            guard let kind = entry.kind else { return nil }
            if Self.filteredKinds.contains(kind), !showing.contains(kind) { return kind }
            if kind == .guardian, parentOf[position] == nil { return kind }
            return nil
        }

        for position in entries.indices {
            guard parentOf[position] == nil else { continue }
            let entry = entries[position]
            var descendants: [String] = []
            var stack: [(Int, Int)] = (childrenOf[position] ?? []).reversed().map { ($0, 1) }
            var visited: Set<Int> = [position]
            while let (child, depth) = stack.popLast() {
                guard visited.insert(child).inserted else { continue }
                descendants.append(entries[child].id)
                children[entries[child].id] = Node(id: entries[child].id, depth: depth, descendants: [], isOrphanThread: false)
                for grandchild in (childrenOf[child] ?? []).reversed() {
                    stack.append((grandchild, depth + 1))
                }
            }
            if let hiddenKind = isHiddenRoot(position) {
                hidden[hiddenKind, default: 0] += 1 + descendants.count
                for id in descendants { children.removeValue(forKey: id) }
                continue
            }
            let orphan = entry.kind.map { Self.nestedKinds.contains($0) } ?? false
            roots.append(Node(id: entry.id, depth: 0, descendants: descendants, isOrphanThread: orphan))
        }

        self.roots = roots
        self.children = children
        self.hiddenCounts = hidden
    }

    /// Ids in display order, with only the roots in `expanded` showing their
    /// descendants.
    public func visibleIDs(expanded: Set<String>) -> [String] {
        var out: [String] = []
        out.reserveCapacity(roots.count)
        for root in roots {
            out.append(root.id)
            if expanded.contains(root.id) { out.append(contentsOf: root.descendants) }
        }
        return out
    }

    public func depth(of id: String) -> Int { children[id]?.depth ?? 0 }
}
