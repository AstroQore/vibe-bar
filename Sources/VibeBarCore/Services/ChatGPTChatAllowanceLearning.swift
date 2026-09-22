import Foundation

/// A sample is a remainder, never an assumed plan allowance.
public struct ChatGPTChatAllowanceSample: Codable, Hashable, Sendable {
    public let id: String
    public let remaining: Int
    public let resetAt: Date?
    public let observedAt: Date

    public init(id: String, remaining: Int, resetAt: Date?, observedAt: Date) {
        self.id = id; self.remaining = remaining; self.resetAt = resetAt; self.observedAt = observedAt
    }
}

/// The deadline a provisional window was measured against, and the longest
/// distance to it seen so far.
///
/// A fixed deadline comes closer with every read, so the distance alone
/// would shrink a monthly allowance to "15 days" halfway through and to a
/// day at the end. The longest distance seen for the same deadline is the
/// nearest the reads came to the window's start.
public struct ChatGPTChatWindowAnchor: Codable, Hashable, Sendable {
    public let resetAt: Date
    public let seconds: Int
    public init(resetAt: Date, seconds: Int) { self.resetAt = resetAt; self.seconds = seconds }
}

/// What one feature's total is known to be.
///
/// The service reports a remainder and a reset, never a total. Two things
/// stand in for it. From the first read, the largest remainder ever seen
/// for this account and plan: the allowance is at least that, and on the
/// day it refills it is exactly that. That is the estimate every read
/// shows, so a monthly allowance has a percentage on day one instead of a
/// season of "learning". Then, once three consistent reset boundaries have
/// been watched, the total and its window are confirmed and the estimate
/// mark comes off. A remainder above either figure raises the estimate and
/// withdraws the confirmation, since the total was evidently larger.
public struct ChatGPTChatAllowanceLearning: Codable, Sendable {
    public private(set) var previous: ChatGPTChatAllowanceSample?
    /// The largest remainder reported so far. Never below a remainder that
    /// was actually observed, so used = total − remaining cannot go negative.
    public private(set) var observedMaximum: Int?
    public private(set) var candidateTotal: Int?
    public private(set) var matchingResets = 0
    public private(set) var candidateWindowSeconds: Int?
    /// Optional, so a file written before anchors existed still decodes;
    /// such a file is anchored on its saved `previous` at the next read.
    public private(set) var windowAnchor: ChatGPTChatWindowAnchor?
    public var isConfirmed: Bool { matchingResets >= 3 && candidateWindowSeconds != nil && candidateTotal != nil }
    public var learnedWindowSeconds: Int? { isConfirmed ? candidateWindowSeconds.map(Self.learnedWindow(seconds:)) : nil }

    public init() {}

    public mutating func observe(_ sample: ChatGPTChatAllowanceSample) -> QuotaQuantity {
        guard sample.remaining >= 0 else { return QuotaQuantity(isEstimated: true) }
        if let previous, sample.observedAt <= previous.observedAt {
            return quantity(for: previous)
        }
        if windowAnchor == nil, let previous { anchor(on: previous) }
        observedMaximum = max(observedMaximum ?? 0, sample.remaining)
        if let previous, let oldReset = previous.resetAt, let newReset = sample.resetAt,
           newReset.timeIntervalSince(oldReset) > 60 {
            // An advancing date alone is not a refill: unused allowances can
            // return "now + window" on every read. Watch an actual boundary,
            // close enough to it that a long offline gap cannot look like a cap.
            let crossed = previous.observedAt < oldReset && sample.observedAt >= oldReset
            let nearBoundary = sample.observedAt.timeIntervalSince(oldReset) <= 600
            let continuous = sample.observedAt.timeIntervalSince(previous.observedAt) <= 1_800
            if crossed && nearBoundary && continuous && newReset > sample.observedAt && sample.remaining > 0 {
                // The new deadline is "now + window" from a read a little
                // after the old one, so the raw gap is the window plus that
                // delay (86 521 s for a day). Snapped, the same window
                // matches itself however late each boundary was read.
                let window = Self.learnedWindow(seconds: Int(newReset.timeIntervalSince(oldReset).rounded()))
                let sameWindow = candidateWindowSeconds.map { Self.learnedWindow(seconds: $0) == window } ?? false
                if candidateTotal == sample.remaining && sameWindow {
                    matchingResets = min(3, matchingResets + 1)
                } else {
                    candidateTotal = sample.remaining
                    matchingResets = 1
                }
                candidateWindowSeconds = window
            } else if crossed {
                // A missed reset cannot confirm that the old total still fits.
                candidateTotal = nil
                candidateWindowSeconds = nil
                matchingResets = 0
            }
        }
        if let total = candidateTotal, sample.remaining > total {
            candidateTotal = nil
            candidateWindowSeconds = nil
            matchingResets = 0
        }
        previous = sample
        anchor(on: sample)
        return quantity(for: sample)
    }

    /// The window to show for a sample: the confirmed one, else the longest
    /// distance seen to this same deadline, as the smallest standard window
    /// that holds it — so a fixed monthly deadline reads as a month on its
    /// last day too, and "now + a day" a minute late is still a day.
    public func windowSeconds(for sample: ChatGPTChatAllowanceSample) -> Int? {
        if let learned = learnedWindowSeconds { return learned }
        guard let resetAt = sample.resetAt else { return nil }
        var distance = resetAt.timeIntervalSince(sample.observedAt)
        if let windowAnchor, Self.sameDeadline(windowAnchor.resetAt, resetAt) {
            distance = max(distance, TimeInterval(windowAnchor.seconds))
        }
        return Self.provisionalWindow(distance: distance)
    }

    private mutating func anchor(on sample: ChatGPTChatAllowanceSample) {
        guard let resetAt = sample.resetAt else { return }
        let distance = Int(resetAt.timeIntervalSince(sample.observedAt).rounded())
        guard distance > 0 else { return }
        if let windowAnchor, Self.sameDeadline(windowAnchor.resetAt, resetAt) {
            if distance > windowAnchor.seconds {
                self.windowAnchor = ChatGPTChatWindowAnchor(resetAt: windowAnchor.resetAt, seconds: distance)
            }
        } else {
            // A different deadline — the next cycle's, or a sliding "now +
            // window" — is measured afresh.
            windowAnchor = ChatGPTChatWindowAnchor(resetAt: resetAt, seconds: distance)
        }
    }

    private static func sameDeadline(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) <= 60 }

    static let day = 86_400
    /// The windows the features are known to use: a day for Image
    /// Generation, thirty days for Deep Research, and a week between.
    static let standardWindows = [day, 7 * day, 30 * day]
    /// How far past a standard window a reading may land and still be it:
    /// the service stamps "now + window" a moment after the read, and a
    /// boundary is only accepted within ten minutes of its deadline.
    static let windowTolerance = 15 * 60

    /// A deadline is at most one window away, so the window is the smallest
    /// standard one that holds the distance to it. Longer than every
    /// standard window, it is the distance in whole days.
    static func provisionalWindow(distance: TimeInterval) -> Int? {
        guard distance.isFinite, distance > 0 else { return nil }
        if let standard = standardWindows.first(where: { distance <= TimeInterval($0 + windowTolerance) }) {
            return standard
        }
        return max(1, Int((distance / TimeInterval(day)).rounded())) * day
    }

    static func provisionalWindow(resetAt: Date?, observedAt: Date) -> Int? {
        guard let resetAt else { return nil }
        return provisionalWindow(distance: resetAt.timeIntervalSince(observedAt))
    }

    /// A measured deadline-to-deadline gap, as the standard window it is
    /// within tolerance of, else whole days (whole hours below 20 hours).
    static func learnedWindow(seconds: Int) -> Int {
        if let standard = standardWindows.first(where: { abs(seconds - $0) <= windowTolerance }) { return standard }
        if seconds >= 20 * 3_600 { return max(1, Int((Double(seconds) / Double(day)).rounded())) * day }
        return max(1, Int((Double(seconds) / 3_600).rounded())) * 3_600
    }

    private func quantity(for sample: ChatGPTChatAllowanceSample) -> QuotaQuantity {
        let currentWindow = sample.resetAt.map { $0 > sample.observedAt } ?? false
        let confirmed = isConfirmed && currentWindow
        guard let total = confirmed ? candidateTotal : observedMaximum, total > 0 else {
            return QuotaQuantity(remaining: sample.remaining, isEstimated: true)
        }
        return QuotaQuantity(used: max(0, total - sample.remaining), remaining: sample.remaining,
                             limit: total, isEstimated: !confirmed)
    }
}

/// One current identity per local account. Switching accounts or changing
/// plan starts over, including when switching back later. A read that could
/// not name the plan keeps what is known rather than starting over, and
/// the summary says the plan went unverified.
public actor ChatGPTChatAllowanceStore {
    public static let shared = ChatGPTChatAllowanceStore()
    public struct Projection: Sendable {
        public let quantity: QuotaQuantity
        public let windowSeconds: Int?
        /// Nothing has been spent: the remainder is the whole known total.
        /// The service then reports "now + window" as the reset on every
        /// read, a date that moves with the clock rather than a deadline.
        public var isUntouched: Bool {
            guard let limit = quantity.limit, limit > 0, let remaining = quantity.remaining else { return false }
            return remaining >= limit
        }
    }
    private struct AccountState: Codable {
        var identity: String
        var plan: String?
        var features: [String: ChatGPTChatAllowanceLearning] = [:]
    }
    private let url: URL
    public init(url: URL = VibeBarLocalStore.chatGPTChatLearningURL) { self.url = url }

    public func observe(localAccount: String, identity: String, plan: String?,
                        samples: [ChatGPTChatAllowanceSample]) throws -> [String: Projection] {
        var all = (try? VibeBarLocalStore.readJSON([String: AccountState].self, from: url)) ?? [:]
        let key = ChatGPTChatParser.identity(localAccount)
        var state = all[key] ?? AccountState(identity: identity, plan: plan)
        let planChanged = plan != nil && state.plan != nil && state.plan != plan
        if state.identity != identity || planChanged {
            state = AccountState(identity: identity, plan: plan)
        }
        if plan != nil { state.plan = plan }
        var result: [String: Projection] = [:]
        for sample in samples {
            var feature = state.features[sample.id] ?? ChatGPTChatAllowanceLearning()
            let quantity = feature.observe(sample)
            result[sample.id] = Projection(quantity: quantity, windowSeconds: feature.windowSeconds(for: sample))
            state.features[sample.id] = feature
        }
        all[key] = state
        try VibeBarLocalStore.writeJSON(all, to: url)
        return result
    }
}
