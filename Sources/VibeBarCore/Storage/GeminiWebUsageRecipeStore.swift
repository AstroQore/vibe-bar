import Foundation

/// The minimum replayable description of Gemini Web's private usage request.
/// It intentionally contains no cookies, XSRF token, response body, or account
/// data; those remain ephemeral and are supplied by the current session.
public struct GeminiWebUsageRecipe: Codable, Equatable, Sendable {
    public static let fallback = GeminiWebUsageRecipe(
        rpcID: "jSf9Qc",
        argument: "[]",
        learnedAt: nil
    )

    public let rpcID: String
    public let argument: String
    public let learnedAt: Date?

    public init(rpcID: String, argument: String, learnedAt: Date? = Date()) {
        self.rpcID = rpcID
        self.argument = argument
        self.learnedAt = learnedAt
    }

    public var isValid: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return !rpcID.isEmpty
            && rpcID.count <= 64
            && rpcID.unicodeScalars.allSatisfy(allowed.contains)
            && !argument.isEmpty
            && argument.utf8.count <= 65_536
    }
}

/// Persists the learned request recipe under `~/.vibebar/`. The store is
/// deliberately separate from AppSettings: protocol calibration is runtime
/// cache state, not a user preference, and must not fan out UI updates.
public enum GeminiWebUsageRecipeStore {
    public static var defaultURL: URL {
        VibeBarLocalStore.baseDirectory.appendingPathComponent("gemini_web_usage_recipe.json")
    }

    public static func load(from url: URL = defaultURL) -> GeminiWebUsageRecipe {
        guard let recipe = try? VibeBarLocalStore.readJSON(GeminiWebUsageRecipe.self, from: url),
              recipe.isValid else {
            return .fallback
        }
        return recipe
    }

    public static func save(_ recipe: GeminiWebUsageRecipe, to url: URL = defaultURL) throws {
        guard recipe.isValid else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if url.standardizedFileURL == defaultURL.standardizedFileURL {
            try VibeBarLocalStore.writeJSON(recipe, to: url)
            return
        }
        // Explicit URLs exist for test isolation; do not touch the real
        // ~/.vibebar root when a synthetic destination is supplied.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipe).write(to: url, options: .atomic)
    }
}
