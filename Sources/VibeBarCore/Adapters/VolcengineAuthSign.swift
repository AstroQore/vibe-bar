import Foundation

/// Reproduces Volcengine's `X-Authentication-Sign` anti-replay header.
///
/// Reverse-engineered from the console JS bundle near the `radomSalt`
/// keyword (yes, that's the real spelling — the server checks the
/// literal field name, so the typo must be preserved).
///
/// Algorithm (from the original minified source):
///
/// 1. Generate `radomSalt`: 16 random alphanumeric characters.
/// 2. `timeStamp`: current Unix time in milliseconds.
/// 3. Build the JSON `content`:
///    `{"radomSalt":"<salt>","timeStamp":<ms>}` (no whitespace).
/// 4. Build the signing form (timestamp string reversed):
///    `radomSalt=<salt>&timeStamp=<reversed-ms>` — both values are
///    alphanumeric so no percent-encoding is needed for this step.
/// 5. `sign = reverse(base64Standard(signingForm))` — standard base64
///    with `=` padding, then reverse the whole string.
/// 6. Final header value:
///    `content=<encURIComponent(content)>&sign=<encURIComponent(sign)>`
///    where `encURIComponent` is the JS `encodeURIComponent` allowed
///    set (`A-Z a-z 0-9 - _ . ~`).
public enum VolcengineAuthSign {
    /// Allowed character set matching JS `encodeURIComponent`. Notably
    /// stricter than `CharacterSet.urlQueryAllowed`, which lets `=` and
    /// `&` through and would corrupt the `content=...&sign=...` boundary.
    public static let percentEncodingAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    /// Produce the header value. `now` and `salt` are injectable so the
    /// algorithm can be unit-tested deterministically.
    public static func headerValue(
        now: Date = Date(),
        salt: String = randomSalt()
    ) -> String {
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        let content = "{\"radomSalt\":\"\(salt)\",\"timeStamp\":\(ts)}"
        let reversedTs = String(String(ts).reversed())
        let signingForm = "radomSalt=\(salt)&timeStamp=\(reversedTs)"
        let signBase64 = Data(signingForm.utf8).base64EncodedString()
        let sign = String(signBase64.reversed())
        let encContent = content.addingPercentEncoding(withAllowedCharacters: percentEncodingAllowed) ?? content
        let encSign = sign.addingPercentEncoding(withAllowedCharacters: percentEncodingAllowed) ?? sign
        return "content=\(encContent)&sign=\(encSign)"
    }

    /// 16-char alphanumeric salt matching the JS implementation's
    /// `Math.random().toString(36)` slice habit. Cryptographic
    /// randomness isn't required (the salt is anti-replay only), but
    /// SystemRandomNumberGenerator is what we have at hand and is fine.
    public static func randomSalt(length: Int = 16) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            let i = Int(rng.next(upperBound: UInt(alphabet.count)))
            out.append(alphabet[i])
        }
        return out
    }
}
