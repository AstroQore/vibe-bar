import Foundation

/// Tencent Cloud console CSRF token derivation.
///
/// Every BFF call against `console-hc.cloud.tencent.com` (and the
/// rest of the `*.cloud.tencent.com` console gateway) carries a
/// `csrfCode=<int>` URL parameter. The browser SDK derives that value
/// synchronously from the `skey` cookie with a small djb2-style hash;
/// there is no separate handshake. Re-derive in Swift to avoid having
/// to scrape the JS bundle at runtime.
///
/// Reference (in-page `getCsrfCode` from cloud.tencent.com's login
/// bundle):
///
/// ```js
/// function getCsrfCode(skey) {
///   for (var t = 5381, i = 0, n = skey.length; i < n; ++i) {
///     t += (t << 5) + skey.charCodeAt(i);
///   }
///   return t & 2147483647;
/// }
/// ```
///
/// Subtleties this Swift port mirrors:
///
/// - `(t << 5)` truncates the LHS to **int32** via JavaScript's
///   `ToInt32` *before* shifting, so the shifted value never exceeds
///   `0xFFFFFFFF`.
/// - `t += ...` runs in JS Number space (IEEE-754 double), so `t`
///   itself can grow past int32 across iterations.
/// - The final `& 0x7FFFFFFF` truncates back to int32 and clears the
///   sign bit, returning a non-negative 31-bit integer.
public enum TencentCsrfCode {
    /// Compute the `csrfCode` URL parameter that pairs with the given
    /// `skey` cookie value. Returns a non-negative 31-bit integer that
    /// matches the browser SDK byte-for-byte for any UTF-16 string.
    public static func compute(from skey: String) -> Int {
        // Use Double to mirror JS Number arithmetic for the running
        // accumulator. Each iteration's `(t << 5)` is bounded to int32
        // before being added back into the accumulator.
        var t: Double = 5381
        for unit in skey.utf16 {
            // ToInt32 on `t`, then arithmetic left-shift by 5.
            let truncated = Self.toInt32(t)
            let shifted = Int64(truncated) &<< 5
            // Re-truncate the shifted value to int32 to match JS bitwise
            // semantics, then add back into the Double accumulator
            // alongside the next char code.
            let shiftedInt32 = Self.truncateToInt32(shifted)
            t = t + Double(shiftedInt32) + Double(unit)
        }
        // Final `& 0x7FFFFFFF` — truncate to int32, then clear the sign
        // bit so the result is a non-negative 31-bit integer.
        let finalInt32 = Self.toInt32(t)
        return Int(finalInt32 & 0x7FFFFFFF)
    }

    /// JS `ToInt32` on a Number.
    private static func toInt32(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let modulus = 4_294_967_296.0  // 2^32
        // ToUint32: floor(|value|) reduced modulo 2^32, sign-preserving.
        let truncated = value.rounded(.towardZero)
        let posMod = (truncated.truncatingRemainder(dividingBy: modulus) + modulus)
            .truncatingRemainder(dividingBy: modulus)
        // Treat values >= 2^31 as the corresponding negative int32.
        if posMod >= 2_147_483_648.0 {
            return Int32(truncatingIfNeeded: Int64(posMod - modulus))
        }
        return Int32(truncatingIfNeeded: Int64(posMod))
    }

    /// Truncate an Int64 to int32 with JS bitwise wraparound.
    private static func truncateToInt32(_ value: Int64) -> Int32 {
        Int32(truncatingIfNeeded: value)
    }
}
