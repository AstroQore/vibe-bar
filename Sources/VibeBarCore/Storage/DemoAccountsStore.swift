import Foundation

/// The provider identities a demo home declares.
///
/// Outside demo mode `AccountStore` discovers identities from the CLIs'
/// credentials on this Mac. A demo home has no credentials by design, so it
/// says which accounts exist in `~/.vibebar/demo_accounts.json` instead; the
/// ids must match the quota caches and history files the home carries, which
/// is `Scripts/demo_home.py`'s job to keep straight.
///
/// Misc-provider instances are not listed here. Their ids are derived from
/// `settings.json` exactly as in production (`misc-<instanceID>`), so the
/// demo home's settings already decide which of those cards exist.
public enum DemoAccountsStore {
    public static let fileName = "demo_accounts.json"

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var tool: ToolType
        public var alias: String?
        public var plan: String?
        public var source: CredentialSource

        public init(id: String, tool: ToolType, alias: String? = nil, plan: String? = nil, source: CredentialSource) {
            self.id = id
            self.tool = tool
            self.alias = alias
            self.plan = plan
            self.source = source
        }
    }

    public struct File: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var accounts: [Entry]

        public init(schemaVersion: Int = 1, accounts: [Entry]) {
            self.schemaVersion = schemaVersion
            self.accounts = accounts
        }
    }

    public static var url: URL {
        VibeBarLocalStore.baseDirectory.appendingPathComponent(fileName)
    }

    /// Missing or unreadable means "no primary accounts", which the popover
    /// renders as its signed-out placeholders — visibly wrong in a screenshot,
    /// which is the right failure mode for a broken demo home.
    public static func load(now: Date = Date()) -> [AccountIdentity] {
        guard let file = try? VibeBarLocalStore.readJSON(File.self, from: url) else { return [] }
        return file.accounts.map { entry in
            AccountIdentity(
                id: entry.id,
                tool: entry.tool,
                alias: entry.alias,
                plan: entry.plan,
                source: entry.source,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}
