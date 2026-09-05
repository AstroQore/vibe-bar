import Foundation

/// The account's own picker identifies Pro versus Thinking and explicitly
/// marks Work models. Display titles never decide which allowance is charged.
public struct ChatGPTChatModelCatalog: Sendable {
    public struct Model: Sendable {
        public let slug: String
        public let title: String
        public let isWork: Bool
        public let isPro: Bool
        public let reasoningType: String?
        public var displayTitle: String {
            let suffix: String? = switch reasoningType {
            case "auto": "Auto"
            case "none": "Instant"
            case "reasoning": "Thinking"
            default: nil
            }
            guard let suffix, !title.localizedCaseInsensitiveContains(suffix) else { return title }
            return title + " · " + suffix
        }
    }
    public let models: [String: Model]
    public static let empty = Self(models: [:])
    public var workModels: Set<String> { Set(models.values.filter(\.isWork).map(\.slug)) }

    public static func parse(_ data: Data) throws -> Self {
        let root = try ChatGPTChatParser.object(data)
        guard let rows = root["models"] as? [[String: Any]] else {
            throw QuotaError.parseFailure("ChatGPT Chat model catalog has no models.")
        }
        var models: [String: Model] = [:]
        for row in rows {
            guard let slug = row["slug"] as? String,
                  slug.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", options: .regularExpression) != nil else { continue }
            let title = (row["title"] as? String).flatMap(VisibleSecretRedactor.redact) ?? slug
            models[slug] = Model(slug: slug, title: String(title.prefix(100)),
                                 isWork: row["is_work_mode_model"] as? Bool == true,
                                 isPro: row["reasoning_type"] as? String == "pro", reasoningType: row["reasoning_type"] as? String)
        }
        return Self(models: models)
    }
}
