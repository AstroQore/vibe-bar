import Foundation

/// Bounds the number of variable-height transcript cards SwiftUI lays out in
/// one pass. A `LazyVStack` still has to place enough children to resolve its
/// scroll geometry; feeding it thousands of message rows can pin the main
/// thread in AttributeGraph even though only a handful are visible.
public enum TranscriptPageWindow {
    public static let defaultPageSize = 80

    public static func range(
        itemCount: Int,
        start: Int,
        pageSize: Int = defaultPageSize
    ) -> Range<Int> {
        let count = max(0, itemCount)
        let size = max(1, pageSize)
        let lower = clampedStart(itemCount: count, start: start, pageSize: size)
        return lower..<min(count, lower + size)
    }

    public static func start(
        containingItemAt index: Int,
        itemCount: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        let count = max(0, itemCount)
        guard count > 0 else { return 0 }
        let size = max(1, pageSize)
        let clampedIndex = min(max(0, index), count - 1)
        return (clampedIndex / size) * size
    }

    public static func previousStart(
        itemCount: Int,
        start: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        let size = max(1, pageSize)
        let current = clampedStart(itemCount: max(0, itemCount), start: start, pageSize: size)
        return max(0, current - size)
    }

    public static func nextStart(
        itemCount: Int,
        start: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        let count = max(0, itemCount)
        let size = max(1, pageSize)
        let current = clampedStart(itemCount: count, start: start, pageSize: size)
        guard current + size < count else { return current }
        return current + size
    }

    private static func clampedStart(itemCount: Int, start: Int, pageSize: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let lastPage = ((itemCount - 1) / pageSize) * pageSize
        return min(max(0, start), lastPage)
    }
}
