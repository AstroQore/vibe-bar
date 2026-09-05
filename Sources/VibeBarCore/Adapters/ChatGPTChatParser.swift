import Foundation
import CoreFoundation

public enum ChatGPTChatParser {
    public static func identity(_ value: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: "chat", rawValue: value)
    }

    public static func samples(_ data: Data, now: Date) throws -> [ChatGPTChatAllowanceSample] {
        let root = try object(data)
        guard let rows = root["limits_progress"] as? [[String: Any]] else {
            throw QuotaError.parseFailure("ChatGPT Chat response has no limits_progress.")
        }
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let feature = row["feature_name"] as? String,
                  ["image_gen", "deep_research"].contains(feature), seen.insert(feature).inserted,
                  let remaining = integer(row["remaining"]) else { return nil }
            return ChatGPTChatAllowanceSample(id: feature, remaining: remaining,
                                             resetAt: date(row["reset_after"]), observedAt: now)
        }.sorted { $0.id == "image_gen" && $1.id != "image_gen" }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("ChatGPT Chat response exceeds the read bound or is not an object.")
        }
        return value
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(),
           seconds.doubleValue.isFinite, seconds.doubleValue > 0 {
            return Date(timeIntervalSince1970: seconds.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
