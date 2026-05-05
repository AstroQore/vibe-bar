import Foundation

/// Pure parser for the Codex / ChatGPT backend `/wham/usage` response.
/// Bucket id mapping:
///   - 18000 sec    → "five_hour"  / "5 Hours" / "5h"
///   - 604800 sec   → "weekly"     / "Weekly"  / "wk"
///   - other        → window expressed in days (>=86400) or hours.
public enum CodexResponseParser {
    public static func parse(data: Data) throws -> [QuotaBucket] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw QuotaError.parseFailure("invalid json")
        }
        guard let root = json as? [String: Any] else {
            throw QuotaError.parseFailure("root is not an object")
        }
        guard let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw QuotaError.parseFailure("missing rate_limit")
        }

        var buckets: [QuotaBucket] = []
        if let primary = rateLimit["primary_window"] as? [String: Any] {
            buckets.append(makeBucket(from: primary, fallbackId: "primary"))
        }
        if let secondary = rateLimit["secondary_window"] as? [String: Any] {
            buckets.append(makeBucket(from: secondary, fallbackId: "secondary"))
        }
        if let additionalLimits = root["additional_rate_limits"] as? [[String: Any]] {
            for entry in additionalLimits {
                guard let nestedRateLimit = entry["rate_limit"] as? [String: Any] else {
                    continue
                }
                let rawName = (entry["limit_name"] as? String) ?? "Additional"
                let idPrefix = slug(rawName)
                let groupTitle = displayLimitName(rawName)
                let shortPrefix = shortLimitName(rawName)

                if let primary = nestedRateLimit["primary_window"] as? [String: Any] {
                    buckets.append(makeBucket(
                        from: primary,
                        fallbackId: "\(idPrefix)_primary",
                        idPrefix: idPrefix,
                        shortPrefix: shortPrefix,
                        groupTitle: groupTitle
                    ))
                }
                if let secondary = nestedRateLimit["secondary_window"] as? [String: Any] {
                    buckets.append(makeBucket(
                        from: secondary,
                        fallbackId: "\(idPrefix)_secondary",
                        idPrefix: idPrefix,
                        shortPrefix: shortPrefix,
                        groupTitle: groupTitle
                    ))
                }
            }
        }

        if buckets.isEmpty {
            throw QuotaError.parseFailure("no windows in rate_limit")
        }
        return buckets
    }

    private static func makeBucket(
        from dict: [String: Any],
        fallbackId: String,
        idPrefix: String? = nil,
        shortPrefix: String? = nil,
        groupTitle: String? = nil
    ) -> QuotaBucket {
        let usedPercent = Self.numberValue(dict["used_percent"]) ?? 0.0
        let windowSeconds = Self.numberValue(dict["limit_window_seconds"]).map { Int($0) }
        let resetEpoch = Self.numberValue(dict["reset_at"])

        let baseId: String
        let baseTitle: String
        let baseShortLabel: String

        switch windowSeconds {
        case .some(18_000):
            baseId = "five_hour"
            baseTitle = "5 Hours"
            baseShortLabel = "5h"
        case .some(604_800):
            baseId = "weekly"
            baseTitle = "Weekly"
            baseShortLabel = "wk"
        case .some(let secs) where secs >= 86_400:
            let days = secs / 86_400
            baseId = "\(days)d_window"
            baseTitle = "\(days) Days"
            baseShortLabel = "\(days)d"
        case .some(let secs):
            let hours = max(1, secs / 3_600)
            baseId = "\(hours)h_window"
            baseTitle = "\(hours) Hours"
            baseShortLabel = "\(hours)h"
        case .none:
            baseId = fallbackId
            baseTitle = fallbackId.capitalized
            baseShortLabel = fallbackId
        }

        let id = idPrefix.map { "\($0)_\(baseId)" } ?? baseId
        let title = baseTitle
        let shortLabel = shortPrefix.map { "\($0) \(baseShortLabel)" } ?? baseShortLabel
        let resetDate: Date? = resetEpoch.map { Date(timeIntervalSince1970: $0) }
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: shortLabel,
            usedPercent: usedPercent,
            resetAt: resetDate,
            rawWindowSeconds: windowSeconds,
            groupTitle: groupTitle
        )
    }

    private static func slug(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
        let scalars = lower.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
    }

    private static func shortLimitName(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("spark") {
            return "Spark"
        }
        return raw
    }

    private static func displayLimitName(_ raw: String) -> String {
        let parts = raw.split(separator: "-").map(String.init)
        if parts.count >= 2, parts[0].localizedCaseInsensitiveCompare("GPT") == .orderedSame {
            return (["GPT-\(parts[1])"] + Array(parts.dropFirst(2))).joined(separator: " ")
        }
        return raw.replacingOccurrences(of: "-", with: " ")
    }

    private static func numberValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double:   return d
        case let i as Int:      return Double(i)
        case let s as String:   return Double(s)
        default:                return nil
        }
    }
}
