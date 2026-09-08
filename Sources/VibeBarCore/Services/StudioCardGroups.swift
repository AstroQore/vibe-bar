import Foundation

/// Card groups are editing units, separate from a page's layout segments.
public enum StudioCardGroups {
    public static func normalized(_ groups: [[String]]) -> [[String]] {
        var used = Set<String>()
        return groups.compactMap { group in
            var local = Set<String>()
            let members = group.filter { !$0.isEmpty && !used.contains($0) && local.insert($0).inserted }
            guard members.count > 1 else { return nil }
            used.formUnion(members)
            return members
        }
    }

    public static func expanded(_ ids: Set<String>, groups: [[String]]) -> Set<String> {
        ids.union(groups.filter { !$0.allSatisfy { !ids.contains($0) } }.flatMap { $0 })
    }

    public static func grouping(_ ids: Set<String>, in groups: [[String]], order: [String]) -> [[String]] {
        let all = expanded(ids, groups: groups)
        let ordered = order.filter(all.contains) + all.filter { !order.contains($0) }.sorted()
        guard ordered.count > 1 else { return groups }
        return normalized(groups.filter { Set($0).isDisjoint(with: all) } + [ordered])
    }

    public static func moving(_ ids: [PageLayoutModuleID], to slot: StudioArranging.ColumnSlot,
                              columns: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        let wanted = Set(ids)
        var result = columns.map { $0.filter { !wanted.contains($0) } }
        while result.count < 2 { result.append([]) }
        let column = min(max(slot.column, 0), result.count - 1)
        let offset = min(max(slot.index, 0), result[column].count)
        var seen = Set<PageLayoutModuleID>()
        result[column].insert(contentsOf: ids.filter { seen.insert($0).inserted }, at: offset)
        return result
    }

    public static func gathering(_ groups: [[String]], columns: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        var result = columns
        for group in normalized(groups) {
            let available = Set(result.flatMap { $0 }.map(\.rawValue))
            let ids = group.filter(available.contains).map(PageLayoutModuleID.init(rawValue:))
            guard ids.count > 1, let first = ids.first,
                  let column = result.firstIndex(where: { $0.contains(first) }),
                  let offset = result[column].firstIndex(of: first) else { continue }
            let position = result[column].prefix(offset).filter { !ids.contains($0) }.count
            result = moving(ids, to: .init(column: column, index: position), columns: result)
        }
        return result
    }

    public static func joiningSegment(_ ids: [PageLayoutModuleID], anchor: PageLayoutModuleID,
                                      segments: [[PageLayoutModuleID]]) -> [[PageLayoutModuleID]] {
        guard let target = segments.firstIndex(where: { $0.contains(anchor) }) else { return segments }
        let selected = Set(ids)
        var next = segments.map { $0.filter { !selected.contains($0) } }
        next[target].append(contentsOf: ids)
        return next
    }
}
