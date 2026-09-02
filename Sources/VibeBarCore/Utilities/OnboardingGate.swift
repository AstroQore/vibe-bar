import Foundation

/// Decides whether the first-run setup assistant opens at launch.
///
/// The assistant is for people who have just installed Vibe Bar. The only
/// durable record of having been through it is `AppSettings.hasCompletedOnboarding`,
/// and that key did not exist before the assistant did — so a missing key
/// reads as `false` for an upgrade as much as for a fresh install. The gate
/// therefore asks what the install looks like, not just what the key says —
/// and it asks only Vibe Bar's own evidence: a quota cache under
/// `~/.vibebar/quotas/` means the app has already been doing its job here,
/// and an existing user is never walked through setup they already did.
///
/// A Codex or Claude CLI login on the Mac is deliberately *not* evidence.
/// People who already run those CLIs are exactly who installs Vibe Bar, so
/// counting their credentials as "prior use" would hide the assistant from
/// its primary audience on a clean install.
public enum OnboardingGate {
    public enum Decision: Equatable, Sendable {
        /// A fresh install: open the assistant.
        case show
        /// Setup was finished or skipped on an earlier launch.
        case skip
        /// The key is unset on an install that clearly predates it. Record
        /// completion silently so the question is not asked again.
        case markCompleted
    }

    /// The whole rule, pure. A quota cache is the one sign of an install
    /// that is not fresh.
    public static func decide(
        hasCompletedOnboarding: Bool,
        hasQuotaCaches: Bool
    ) -> Decision {
        if hasCompletedOnboarding { return .skip }
        if hasQuotaCaches { return .markCompleted }
        return .show
    }

    /// `decide` reduced to the one question the launch path asks.
    public static func shouldShow(settings: AppSettings, hasQuotaCaches: Bool) -> Bool {
        decide(
            hasCompletedOnboarding: settings.hasCompletedOnboarding,
            hasQuotaCaches: hasQuotaCaches
        ) == .show
    }

    /// Whether the quota cache directory holds at least one file. Dotfiles
    /// are ignored: a `.DS_Store` left by Finder is not a quota snapshot.
    /// One directory listing, so it is cheap enough for the launch path.
    public static func hasQuotaCaches(
        in directory: URL = VibeBarLocalStore.quotaDirectory,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return entries.contains { !$0.hasPrefix(".") }
    }
}
