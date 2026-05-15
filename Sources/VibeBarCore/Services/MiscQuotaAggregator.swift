import Foundation

/// Combines per-slot quota fetches into a single `AccountQuota`.
///
/// Each cookie slot a user has imported for a misc provider is queried
/// independently (see `MiscCookieResolver.resolveAll`). The aggregator
/// then averages the percent-used across all successful slots for each
/// bucket id — "0% + 100% → 50%", "20% + 80% → 50%". Failed slots are
/// excluded from the average; if every slot fails the surfaced error
/// is the first failure (so the card flips to "Needs re-login" /
/// "Network error" exactly as it did under the single-cookie flow).
///
/// The aggregator is pure — it doesn't touch Keychain, networking, or
/// the slot store. Adapters wrap their per-slot fetch in a
/// `do/catch`, hand the resulting `SlotResult`s to `aggregate(...)`,
/// and return whatever comes back.
public enum MiscQuotaAggregator {
    public struct SlotResult: Sendable {
        public let slotID: UUID?
        public let sourceLabel: String
        public let outcome: Result<AccountQuota, QuotaError>

        public init(
            slotID: UUID?,
            sourceLabel: String,
            outcome: Result<AccountQuota, QuotaError>
        ) {
            self.slotID = slotID
            self.sourceLabel = sourceLabel
            self.outcome = outcome
        }
    }

    /// Combine `results` into one quota row.
    ///
    /// - When at least one slot succeeded: average `usedPercent` for
    ///   each observed bucket id. The bucket's display metadata
    ///   (`title`, `shortLabel`, `rawWindowSeconds`, `groupTitle`) and
    ///   plan / email come from the first successful slot that
    ///   contained that bucket / field. `resetAt` is the earliest
    ///   non-nil reset across successful slots (most pessimistic). The
    ///   returned `error` is `nil`.
    /// - When every slot failed: the returned quota has empty buckets
    ///   and carries the first failure as `error`, so the existing
    ///   card-error rendering keeps working.
    public static func aggregate(
        tool: ToolType,
        account: AccountIdentity,
        results: [SlotResult],
        queriedAt: Date
    ) -> AccountQuota {
        let successes: [AccountQuota] = results.compactMap { result in
            if case let .success(quota) = result.outcome { return quota }
            return nil
        }

        guard !successes.isEmpty else {
            let firstError: QuotaError = results.compactMap {
                if case let .failure(err) = $0.outcome { return err }
                return nil
            }.first ?? .noCredential
            return AccountQuota(
                accountId: account.id,
                tool: tool,
                buckets: [],
                plan: nil,
                email: account.email,
                queriedAt: queriedAt,
                error: firstError
            )
        }

        let aggregatedBuckets = mergeBuckets(from: successes)
        let plan = successes.compactMap(\.plan).first
        let email = successes.compactMap(\.email).first ?? account.email
        let providerExtras = successes.compactMap(\.providerExtras).first

        return AccountQuota(
            accountId: account.id,
            tool: tool,
            buckets: aggregatedBuckets,
            plan: plan,
            email: email,
            queriedAt: queriedAt,
            error: nil,
            providerExtras: providerExtras
        )
    }

    /// Fan a per-slot fetch out concurrently, then box each outcome
    /// into a `SlotResult`. Adapters call this with their per-slot
    /// fetcher and pass the result straight into `aggregate(...)`.
    public static func gatherSlotResults(
        _ resolutions: [MiscCookieResolver.Resolution],
        fetch: @Sendable @escaping (MiscCookieResolver.Resolution) async throws -> AccountQuota
    ) async -> [SlotResult] {
        await withTaskGroup(of: SlotResult.self, returning: [SlotResult].self) { group in
            for resolution in resolutions {
                group.addTask {
                    do {
                        let quota = try await fetch(resolution)
                        return SlotResult(
                            slotID: resolution.slotID,
                            sourceLabel: resolution.sourceLabel,
                            outcome: .success(quota)
                        )
                    } catch let err as QuotaError {
                        return SlotResult(
                            slotID: resolution.slotID,
                            sourceLabel: resolution.sourceLabel,
                            outcome: .failure(err)
                        )
                    } catch {
                        return SlotResult(
                            slotID: resolution.slotID,
                            sourceLabel: resolution.sourceLabel,
                            outcome: .failure(.network(error.localizedDescription))
                        )
                    }
                }
            }
            var collected: [SlotResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }

    /// Convenience for single-slot adapters / callers that haven't
    /// migrated to slot-aware fetching yet — wraps a `Result` so the
    /// adapter doesn't need to re-implement the aggregation branch.
    public static func passthrough(
        tool: ToolType,
        account: AccountIdentity,
        result: Result<AccountQuota, QuotaError>,
        queriedAt: Date,
        sourceLabel: String = ""
    ) -> AccountQuota {
        aggregate(
            tool: tool,
            account: account,
            results: [
                SlotResult(slotID: nil, sourceLabel: sourceLabel, outcome: result)
            ],
            queriedAt: queriedAt
        )
    }

    private static func mergeBuckets(from successes: [AccountQuota]) -> [QuotaBucket] {
        var firstAppearance: [String: (order: Int, bucket: QuotaBucket)] = [:]
        var orderCounter = 0
        var percentSums: [String: Double] = [:]
        var percentCounts: [String: Int] = [:]
        var earliestReset: [String: Date] = [:]

        for quota in successes {
            for bucket in quota.buckets {
                if firstAppearance[bucket.id] == nil {
                    firstAppearance[bucket.id] = (orderCounter, bucket)
                    orderCounter += 1
                }
                percentSums[bucket.id, default: 0] += bucket.usedPercent
                percentCounts[bucket.id, default: 0] += 1
                if let reset = bucket.resetAt {
                    if let current = earliestReset[bucket.id] {
                        if reset < current { earliestReset[bucket.id] = reset }
                    } else {
                        earliestReset[bucket.id] = reset
                    }
                }
            }
        }

        return firstAppearance.values
            .sorted { $0.order < $1.order }
            .map { entry in
                let template = entry.bucket
                let count = max(percentCounts[template.id] ?? 1, 1)
                let avg = (percentSums[template.id] ?? template.usedPercent) / Double(count)
                return QuotaBucket(
                    id: template.id,
                    title: template.title,
                    shortLabel: template.shortLabel,
                    usedPercent: avg,
                    resetAt: earliestReset[template.id] ?? template.resetAt,
                    rawWindowSeconds: template.rawWindowSeconds,
                    groupTitle: template.groupTitle
                )
            }
    }
}
