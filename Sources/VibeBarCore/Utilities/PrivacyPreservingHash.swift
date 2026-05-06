import CryptoKit
import Foundation

enum PrivacyPreservingHash {
    static func fileComponent(prefix: String, rawValue: String) -> String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix)-\(digest)"
    }
}
