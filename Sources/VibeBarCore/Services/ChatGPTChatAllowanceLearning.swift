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

public struct ChatGPTChatAllowanceLearning: Codable, Sendable {
    public private(set) var previous: ChatGPTChatAllowanceSample?
    public private(set) var candidateTotal: Int?
    public private(set) var matchingResets = 0
    public private(set) var candidateWindowSeconds: Int?
    public var learnedWindowSeconds: Int? { matchingResets >= 3 ? candidateWindowSeconds : nil }

    public init() {}

    public mutating func observe(_ sample: ChatGPTChatAllowanceSample) -> QuotaQuantity {
        guard sample.remaining >= 0 else { return QuotaQuantity(isEstimated: true) }
        if let previous, sample.observedAt <= previous.observedAt {
            return quantity(for: previous)
        }
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

    private func quantity(for sample: ChatGPTChatAllowanceSample) -> QuotaQuantity {
        let currentWindow = sample.resetAt.map { $0 > sample.observedAt } ?? false
        let total = matchingResets >= 3 && candidateWindowSeconds != nil && currentWindow ? candidateTotal : nil
        return QuotaQuantity(used: total.map { max(0, $0 - sample.remaining) },
                             remaining: sample.remaining, limit: total, isEstimated: true)
    }
}

/// One current identity per local account. Switching accounts or changing any
/// subscription identity starts over, including when switching back later.
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
        if state.identity != identity || state.plan != plan || plan == nil {
            state = AccountState(identity: identity, plan: plan)
        }
        var result: [String: Projection] = [:]
        for sample in samples {
            var feature = state.features[sample.id] ?? ChatGPTChatAllowanceLearning()
            let quantity = feature.observe(sample)
            result[sample.id] = Projection(quantity: quantity, windowSeconds: feature.learnedWindowSeconds)
            state.features[sample.id] = feature
        }
        all[key] = state
        try VibeBarLocalStore.writeJSON(all, to: url)
        return result
    }
}
