import Foundation

/// Legacy Vibe Bar-owned misc secrets/cookies once lived under
/// `com.astroqore.VibeBar.misc`. Background refreshes must not touch
/// that service in the regular login keychain: macOS can surface a
/// password prompt for every account/kind probe. Automatic migration
/// therefore only checks the non-interactive data-protection backend.
public enum LegacyKeychainMigrationPolicy {
    public enum Backend: Equatable, Sendable {
        case dataProtection
    }

    public static let backendsForAutomaticMigration: [Backend] = [.dataProtection]
}
