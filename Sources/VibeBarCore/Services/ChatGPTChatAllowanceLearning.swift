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
    public var isConfirmed: Bool { matchingResets >= 3 && candidateWindowSeconds != nil && candidateTotal != nil }
    public var learnedWindowSeconds: Int? { isConfirmed ? candidateWindowSeconds : nil }

    public init() {}

    public mutating func observe(_ sample: ChatGPTChatAllowanceSample) -> QuotaQuantity {
        guard sample.remaining >= 0 else { return QuotaQuantity(isEstimated: true) }
        if let previous, sample.observedAt <= previous.observedAt {
            return quantity(for: previous)
        }
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
                let window = Int(newReset.timeIntervalSince(oldReset).rounded())
                let sameWindow = candidateWindowSeconds.map { abs($0 - window) <= 60 } ?? false
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
        return quantity(for: sample)
    }

    /// The window to show for a sample: the confirmed one, else the
    /// service's own distance to the reset, rounded to whole days (or hours
    /// for anything shorter than a day) so a read a minute into the window
    /// does not shave the window.
    public func windowSeconds(for sample: ChatGPTChatAllowanceSample) -> Int? {
        if let learned = learnedWindowSeconds { return learned }
        return Self.provisionalWindow(resetAt: sample.resetAt, observedAt: sample.observedAt)
    }

    static func provisionalWindow(resetAt: Date?, observedAt: Date) -> Int? {
        guard let resetAt else { return nil }
        let distance = resetAt.timeIntervalSince(observedAt)
        guard distance > 0 else { return nil }
        if distance >= 20 * 3_600 { return max(1, Int((distance / 86_400).rounded())) * 86_400 }
        return max(1, Int((distance / 3_600).rounded())) * 3_600
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
