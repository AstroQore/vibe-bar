import Foundation

/// When the Sessions list asks for the next index page by itself.
///
/// The list pages on the last visible row coming into view. A page whose
/// rows the thread filters all hide (exec runs, automations) leaves that
/// last row where it was, so it never comes into view again and paging
/// stops — with a first page that is all hidden, there is no row at all.
/// After every rebuild the list reports how many rows it was given and how
/// many it shows; when a page arrived and showed nothing new while the index
/// has more, the next page is asked for, a bounded number of times in a row.
public struct SessionListAutoPaging: Sendable {
    /// Pages fetched in a row without a new visible row before giving up —
    /// the list's whole budget at its page size; the "load more" row at the
    /// bottom stays for the rest.
    public static let maximumConsecutivePages = 8

    private var lastSourceCount = 0
    private var lastVisibleCount = 0
    private var lastFirstID: String?
    private var consecutive = 0

    public init() {}

    /// Called after each rebuild of the list. Returns whether to ask for the
    /// next page now.
    public mutating func shouldLoadMore(sourceCount: Int, visibleCount: Int, firstID: String?, hasMore: Bool) -> Bool {
        // A shorter list, or one that starts elsewhere, is a new query: read
        // it as arriving from nothing.
        if sourceCount < lastSourceCount || firstID != lastFirstID {
            lastSourceCount = 0
            lastVisibleCount = 0
            consecutive = 0
        }
        defer {
            lastSourceCount = sourceCount
            lastVisibleCount = visibleCount
            lastFirstID = firstID
        }
        guard hasMore else {
            consecutive = 0
            return false
        }
        if visibleCount > lastVisibleCount {
            consecutive = 0
            return false
        }
        guard sourceCount > lastSourceCount, consecutive < Self.maximumConsecutivePages else { return false }
        consecutive += 1
        return true
    }
}
