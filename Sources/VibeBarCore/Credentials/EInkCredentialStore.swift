import Foundation

/// The Dot. API key, in the Keychain and nowhere else.
///
/// `settings.json` records only `EInkSyncSettings.apiKeyPresent`. The demo
/// read a shared `~/.config/dot/credentials.env` that every agent on the Mac
/// uses; the app deliberately does not, because that file is outside
/// `~/.vibebar/` and belongs to tooling Vibe Bar does not own.
public enum EInkCredentialStore {
    public static let service = "com.astroqore.VibeBar.eink"
    public static let apiKeyAccount = "dot-api-key"

    public static func readAPIKey() throws -> String {
        try VibeBarCredentialVault.readString(service: service, account: apiKeyAccount)
    }

    public static func writeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try VibeBarCredentialVault.writeString(service: service, account: apiKeyAccount, value: trimmed)
    }

    public static func deleteAPIKey() throws {
        try VibeBarCredentialVault.delete(service: service, account: apiKeyAccount)
    }

    /// Non-throwing presence check for the settings mirror.
    public static func hasAPIKey() -> Bool {
        guard let key = try? readAPIKey() else { return false }
        return !key.isEmpty
    }
}
