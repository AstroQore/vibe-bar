import Foundation

/// The single place that turns "when did this account last return data" and
/// "when did it last try" into the freshness line the quota cards draw.
///
/// Both the overview group card and the provider page used to compose this
/// themselves from one `lastUpdated` timestamp that a *failed* refresh also
/// bumped. Two things went wrong with that. The label claimed "Updated just
/// now" while the numbers underneath it were hours old, and — because the
/// stale threshold is at least the refresh interval — a provider failing on
/// every cycle could never reach the stale branch at all, so it read as merely
/// "Refresh failed" forever.
///
/// Success age and attempt age are therefore separate inputs, and the label
/// always states how old the *data* is, never how recently something tried.
public enum QuotaFreshnessLabel {
    /// The warning line plus its tooltip. `nil` from `describe` means the
    /// account is fresh enough that no warning belongs on the card.
    public struct Description: Equatable, Sendable {
        public let label: String
        public let help: String
        /// False for a line that only states the data's age: drawn quietly,
        /// not as a warning.
        public let isWarning: Bool

        public init(label: String, help: String, isWarning: Bool = true) {
            self.label = label
            self.help = help
            self.isWarning = isWarning
        }
    }

    public static var defaultHelp: String { L10n.Quota.Freshness.defaultHelp }

    /// - Parameters:
    ///   - lastSuccessAt: when the displayed data was actually fetched.
    ///   - lastAttemptAt: when a refresh last ran, successful or not.
    ///   - errorMessage: `QuotaError.userFacingMessage` for a failure that is
    ///     still current, or nil when the last attempt succeeded.
    ///   - staleAfter: how old successful data may get before it is stale.
    ///   - clientCacheHelp: set for a provider whose quota mirrors a cache its
    ///     own client writes while it runs (Devin). Its numbers move only when
    ///     that client runs, and running it rewrites the cache, so an old cache
    ///     is not a stale reading: its age is stated quietly, with this as the
    ///     explanation, instead of as a warning.
    public static func describe(
        lastSuccessAt: Date?,
        lastAttemptAt: Date?,
        errorMessage: String?,
        staleAfter: TimeInterval,
        now: Date = Date(),
        clientCacheHelp: String? = nil
    ) -> Description? {
        // Nothing has ever been tried for this account — the card shows its
        // signed-out or empty state, which says more than a freshness warning.
        guard lastSuccessAt != nil || lastAttemptAt != nil else { return nil }

        let successAge = lastSuccessAt.map { max(0, now.timeIntervalSince($0)) }
        let isStale = successAge.map { $0 >= max(0, staleAfter) } ?? true
        let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = (trimmed?.isEmpty == false) ? trimmed : nil
        guard isStale || failure != nil else { return nil }

        let dataPhrase = successAge.map { L10n.Quota.Freshness.dataAge(age: compactAge($0)) }
            ?? L10n.Quota.Freshness.noCachedData
        if let failure {
            let attemptAge = lastAttemptAt.map { max(0, now.timeIntervalSince($0)) }
            // Below the "just now" floor the elapsed time is noise; the data
            // age next to it is the number that matters either way.
            let attemptPhrase = (attemptAge.map { $0 >= 5 } ?? false)
                ? L10n.Quota.Freshness.refreshFailedAgo(age: compactAge(attemptAge ?? 0))
                : L10n.Quota.Freshness.refreshFailed
            return Description(
                label: L10n.Quota.Freshness.line(
                    attempt: attemptPhrase,
                    data: dataPhrase,
                    // The provider's own diagnosis, trimmed to fit. It is
                    // theirs, so it is not translated here.
                    reason: shortened(failure)
                ),
                help: failure
            )
        }
        guard let successAge else {
            return Description(
                label: L10n.Quota.Freshness.staleNeverUpdated, help: defaultHelp
            )
        }
        if let clientCacheHelp {
            let age = L10n.Quota.Freshness.dataAge(age: compactAge(successAge))
            return Description(
                label: age.prefix(1).uppercased() + age.dropFirst(),
                help: clientCacheHelp,
                isWarning: false
            )
        }
        return Description(
            label: L10n.Quota.Freshness.staleUpdatedAgo(age: compactAge(successAge)),
            help: defaultHelp
        )
    }

    /// "45s", "2m", "8h", "3d". Deliberately terser than
    /// `ResetCountdownFormatter.updatedAgo`, because this label carries two
    /// ages and an error message on one line.
    public static func compactAge(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 60 { return L10n.Quota.Freshness.Age.seconds(seconds: seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.Common.Duration.minutes(minutes: minutes) }
        let hours = minutes / 60
        if hours < 24 { return L10n.Common.Duration.hours(hours: hours) }
        return L10n.Common.Duration.days(days: hours / 24)
    }

    /// Provider errors are written for a tooltip, not a one-line badge. Keep
    /// the leading sentence visible and leave the rest to `.help`.
    private static func shortened(_ message: String, limit: Int = 72) -> String {
        guard message.count > limit else { return message }
        let head = String(message.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }
}
