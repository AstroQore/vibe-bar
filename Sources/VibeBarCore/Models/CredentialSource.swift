import Foundation

public enum CredentialSource: String, Codable, Sendable {
    case cliDetected
    case webCookie
}
