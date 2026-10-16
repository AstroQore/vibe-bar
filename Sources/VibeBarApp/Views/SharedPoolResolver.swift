import Foundation
import VibeBarCore

extension SharedPoolSummary {
    /// The X Subscription's pool from the app's live quotas, or `nil` when
    /// the two accounts do not read one pool — or when Cursor's latest
    /// refresh failed: its last snapshot stays cached with the error
    /// recorded beside it, and a pool drawn from that stale figure would
    /// hide both the error and the freshness warning Cursor's own card
    /// shows. Every surface that collapses the SpaceXAI family into one
    /// pool goes through here, so they agree.
    @MainActor
    static func resolve(environment: AppEnvironment) -> SharedPoolSummary? {
        let quotaService = environment.quotaService
        guard let grokAccount = environment.account(for: .grok),
              let cursorAccount = environment.account(for: .cursor),
              quotaService.lastErrorByAccount[cursorAccount.id] == nil
        else { return nil }
        return SharedPoolSummary.make(
            grok: quotaService.cachedQuota(for: grokAccount.id),
            cursor: quotaService.cachedQuota(for: cursorAccount.id)
        )
    }
}
