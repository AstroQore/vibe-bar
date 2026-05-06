import Foundation

/// Display-only JWT payload parser. Decodes the base64 payload without verifying
/// the signature — claims surfaced from this (email, account id, plan) are
/// shown in the UI but **never used for security decisions**. The upstream
/// service authenticates the access token on every request, so a forged JWT
/// here can mislead the local UI but cannot escalate against a real account.
enum JWTClaims {
    static func parse(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    static func string(
        _ keys: [String],
        in payload: [String: Any]?,
        nested dictionaryKey: String? = nil
    ) -> String? {
        let dictionary: [String: Any]?
        if let dictionaryKey {
            dictionary = payload?[dictionaryKey] as? [String: Any]
        } else {
            dictionary = payload
        }
        for key in keys {
            if let value = dictionary?[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
