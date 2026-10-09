import Foundation

/// Which sessions the Sessions list has asked the structure sidecar about,
/// and which are still waiting: the bookkeeping behind its background
/// stats lookups (tokens, cost, kind, parent).
///
/// A path is asked about once per size, so a session that grew is asked
/// again. What has not been answered yet — still queued, or in the batch
/// being read — is forgotten by `cancel()`, so the list asks for it again
/// when it next comes up; a batch taken off the queue and then cut short
/// would otherwise count as asked for the rest of the process and its rows
/// would never get their stats.
public struct SessionListingRequests: Sendable {
    /// The size each path was asked about at.
    private var requested: [String: Int64] = [:]
    public private(set) var queue: [SessionSummary] = []
    /// The batch being read: off the queue, not answered yet.
    public private(set) var inFlight: [SessionSummary] = []

    public init() {}

    public var hasQueued: Bool { !queue.isEmpty }

    /// Whether `summary` has been asked about at its current size.
    public func isRequested(_ summary: SessionSummary) -> Bool {
        requested[summary.sourcePath] == summary.sizeBytes
    }

    /// Queue every session the sidecar can describe that has not been asked
    /// about at its current size. Returns whether anything was queued.
    @discardableResult
    public mutating func enqueue(_ summaries: [SessionSummary], atFront: Bool) -> Bool {
        var fresh: [SessionSummary] = []
        for summary in summaries where SessionStructureService.supports(summary.provider) {
            if isRequested(summary) { continue }
            requested[summary.sourcePath] = summary.sizeBytes
            fresh.append(summary)
        }
        guard !fresh.isEmpty else { return false }
        if atFront { queue.insert(contentsOf: fresh, at: 0) } else { queue.append(contentsOf: fresh) }
        return true
    }

    /// The next batch, moved from the queue to in flight.
    public mutating func takeBatch(limit: Int) -> [SessionSummary] {
        let batch = Array(queue.prefix(max(1, limit)))
        queue.removeFirst(batch.count)
        inFlight = batch
        return batch
    }

    /// Hand part of the batch back to the end of the queue: a fresher page
    /// asked for its rows first.
    public mutating func requeue(_ summaries: [SessionSummary]) {
        let paths = Set(summaries.map(\.sourcePath))
        inFlight.removeAll { paths.contains($0.sourcePath) }
        queue.append(contentsOf: summaries)
    }

    /// The batch in flight was answered.
    public mutating func finishBatch() {
        inFlight.removeAll()
    }

    /// Stop: everything not answered — queued or in flight — is asked for
    /// again next time.
    public mutating func cancel() {
        for summary in queue + inFlight { requested.removeValue(forKey: summary.sourcePath) }
        queue.removeAll()
        inFlight.removeAll()
    }
}
