import Foundation

/// Decodes the subscription half of `POST https://api.meta.ai/muse-code/key`.
///
/// The endpoint answers a Muse Code OAuth token with the account's API key
/// *and* its subscription state:
///
/// ```json
/// {
///   "api_key": "…", "user_email": "…", "is_subs_active": true,
///   "subs_tier_id": "…", "subs_tier_name": "Muse Code High Usage",
///   "subs_usage": {
///     "window": { "used_percent": 12, "window_duration_mins": 300, "resets_at": 1789607748 },
///     "weekly": { "used_percent": 3, "resets_at": 1789948800 },
///     "tier": "…"
///   }
/// }
/// ```
///
/// `api_key` is never decoded: the parser reads only the fields it names, so
/// the key cannot reach a model, a cache, or a log. `resets_at` is epoch
/// seconds.
///
/// A window only exists once something has been spent in it. After a window
/// lapses with no new use the server drops it — and with both idle it sends
/// `"subs_usage": null` for a perfectly active subscription. An idle window
/// is therefore reported as what it is, 0% with no reset scheduled, so the
/// card and every field picked from it keep their place.
public enum MuseResponseParser {
    public struct Snapshot: Sendable, Equatable {
        public let buckets: [QuotaBucket]
        public let tierName: String?
        public let email: String?
        public let isSubscriptionActive: Bool?
    }

    static let weekSeconds = 604_800
    /// The rolling window's length when the server has none to report — the
    /// only length it has ever sent.
    static let defaultWindowMinutes = 300

    public static func parse(data: Data) throws -> Snapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaError.parseFailure("Muse Code usage response is not a JSON object")
        }
        let active = root["is_subs_active"] as? Bool
        if active == false {
            throw QuotaError.parseFailure("No active Muse Code subscription on this account")
        }
        // `null` is the idle account; a missing or non-object value is a
        // response this parser does not understand, not an idle one.
        guard let rawUsage = root["subs_usage"], rawUsage is NSNull || rawUsage is [String: Any] else {
            throw QuotaError.parseFailure("Muse Code usage response has no subs_usage object")
        }
        let usage = rawUsage as? [String: Any]
        var buckets: [QuotaBucket] = []
        if let window = usage?["window"] as? [String: Any], let used = number(window["used_percent"]) {
            let minutes = number(window["window_duration_mins"]).map { Int($0) }
            let seconds = minutes.map { $0 * 60 }
            let id: String
            let title: String
            switch seconds {
            case 18_000?:
                id = "five_hour"
                title = "5 Hours"
            case let seconds? where seconds > 0 && seconds % 86_400 == 0:
                id = "\(seconds / 86_400)d_window"
                title = "\(seconds / 86_400) Days"
            case let seconds? where seconds > 0:
                id = "\(seconds / 3_600)h_window"
                title = "\(seconds / 3_600) Hours"
            default:
                id = "window"
                title = "Window"
            }
            buckets.append(QuotaBucket(
                id: id,
                title: title,
                shortLabel: title,
                usedPercent: used,
                resetAt: date(window["resets_at"]),
                rawWindowSeconds: seconds
            ))
        } else {
            buckets.append(QuotaBucket(
                id: "five_hour",
                title: "5 Hours",
                shortLabel: "5 Hours",
                usedPercent: 0,
                rawWindowSeconds: defaultWindowMinutes * 60
            ))
        }
        let weekly = usage?["weekly"] as? [String: Any]
        buckets.append(QuotaBucket(
            id: "weekly",
            title: "Weekly",
            shortLabel: "Weekly",
            usedPercent: weekly.flatMap { number($0["used_percent"]) } ?? 0,
            resetAt: weekly.flatMap { date($0["resets_at"]) },
            rawWindowSeconds: weekSeconds
        ))
        return Snapshot(
            buckets: buckets,
            tierName: string(root["subs_tier_name"]),
            email: string(root["user_email"]),
            isSubscriptionActive: active
        )
    }

    private static func number(_ value: Any?) -> Double? {
        // `value is Bool` is true for any NSNumber holding 0 or 1, which is
        // exactly what a fresh window reports; only a real JSON boolean is
        // refused.
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Epoch seconds; a millisecond value is tolerated in case the field
    /// ever widens.
    private static func date(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
    }
}
