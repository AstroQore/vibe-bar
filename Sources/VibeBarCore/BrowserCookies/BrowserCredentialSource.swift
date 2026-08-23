import Foundation

/// Where a browser-backed misc-provider credential is persisted by the
/// browser. Every source still resolves to the same cookie-shaped Keychain
/// slot consumed by the existing adapters.
public enum BrowserCredentialSource: Sendable, Hashable {
    /// Regular HTTP cookies read through `BrowserCookieClient`.
    case cookieJar
    /// One exact first-party localStorage field in Chromium profiles.
    case chromiumLocalStorage(ChromiumLocalStorageCredential)
}

/// Declarative mapping from one Chromium localStorage value to the synthetic
/// cookie header already understood by a provider adapter.
public struct ChromiumLocalStorageCredential: Sendable, Hashable {
    public let origin: String
    public let key: String
    public let syntheticCookieName: String
    public let valueFormat: BrowserCredentialValueFormat

    public init(
        origin: String,
        key: String,
        syntheticCookieName: String,
        valueFormat: BrowserCredentialValueFormat
    ) {
        self.origin = origin
        self.key = key
        self.syntheticCookieName = syntheticCookieName
        self.valueFormat = valueFormat
    }

    public func cookieHeader(from rawValue: String) -> String? {
        guard Self.isValidCookieName(syntheticCookieName),
              let value = valueFormat.normalizedValue(rawValue) else {
            return nil
        }
        return "\(syntheticCookieName)=\(value)"
    }

    private static func isValidCookieName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.utf8.allSatisfy { byte in
            (48...57).contains(byte) ||
                (65...90).contains(byte) ||
                (97...122).contains(byte) ||
                [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
        }
    }
}

public enum BrowserCredentialValueFormat: Sendable, Hashable {
    /// Opaque single-header value with separators and control characters
    /// rejected before it reaches Keychain.
    case opaque(minLength: Int, maxLength: Int)
    /// ASCII base64url JWT-like value with an exact segment count.
    case jwt(segments: Int, minLength: Int, maxLength: Int)

    func normalizedValue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds: (minimum: Int, maximum: Int) = switch self {
        case let .opaque(minimum, maximum), let .jwt(_, minimum, maximum):
            (minimum, maximum)
        }
        guard bounds.minimum >= 0,
              bounds.maximum >= bounds.minimum,
              value.count >= bounds.minimum,
              value.count <= bounds.maximum else {
            return nil
        }

        switch self {
        case .opaque:
            guard value.utf8.allSatisfy({ byte in
                !byte.isASCIIControl && byte != 59
            }) else { return nil }
        case let .jwt(segmentCount, _, _):
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard segmentCount > 0,
                  parts.count == segmentCount,
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(\.isBase64URL) }) else {
                return nil
            }
        }
        return value
    }
}

private extension UInt8 {
    var isASCIIControl: Bool {
        self < 32 || self == 127
    }

    var isBase64URL: Bool {
        (48...57).contains(self) ||
            (65...90).contains(self) ||
            (97...122).contains(self) ||
            self == 45 || self == 95
    }
}
