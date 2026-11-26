import Foundation
import os.lock

public struct ClaudeCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let rateLimitTier: String?
    public let source: CredentialSource
}

public enum ClaudeCredentialReader {
    private static let keychainService = "Claude Code-credentials"

    public static func loadFromCLI() throws -> ClaudeCredential {
        if let fromKeychain = try? readFromKeychain() {
            return fromKeychain
        }
        if let fromSecurityTool = readFromSecurityTool(source: .cliDetected) {
            return fromSecurityTool
        }
        return try readFromCredentialsJSON()
    }

    public static func loadFromOAuth() throws -> ClaudeCredential {
        if let fromFile = try? readFromCredentialsJSON(source: .oauthCLI) {
            return fromFile
        }
        if let fromKeychain = try? readFromKeychain(source: .oauthCLI) {
            return fromKeychain
        }
        if let fromSecurityTool = readFromSecurityTool(source: .oauthCLI) {
            return fromSecurityTool
        }
        throw QuotaError.noCredential
    }

    public static func decode(jsonString: String, source: CredentialSource) throws -> ClaudeCredential {
        guard let data = jsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("credentials json is not utf8")
        }
        return try decode(data: data, source: source)
    }

    public static func decode(data: Data, source: CredentialSource) throws -> ClaudeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("credentials json is not an object")
        }

        let oauth: [String: Any] =
            (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claude.ai_oauth"] as? [String: Any])
            ?? root

        let accessToken = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? ""

        if accessToken.isEmpty {
            throw QuotaError.needsLogin
        }

        let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
        let rateLimitTier = stringValue(oauth["rateLimitTier"] ?? oauth["rate_limit_tier"])

        return ClaudeCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            rateLimitTier: rateLimitTier,
            source: source
        )
    }

    private static func readFromKeychain(source: CredentialSource = .cliDetected) throws -> ClaudeCredential {
        let raw = try KeychainStore.readString(service: keychainService)
        return try decode(jsonString: raw, source: source)
    }

    /// Claude Code writes its login with `/usr/bin/security`, so the item's
    /// access list names that tool, not Vibe Bar: the non-interactive
    /// Security.framework read above is refused, and an ad-hoc rebuild would
    /// lose any access the user granted by hand. Reading through the same
    /// tool is how Claude Code itself gets the item back and raises no prompt.
    /// A successful read is held in memory for a minute, and never past the
    /// token's own expiry, so account detection and a refresh do not each
    /// start a process. A miss is not remembered: signing in to Claude Code
    /// must be seen by the next refresh.
    private static func readFromSecurityTool(source: CredentialSource) -> ClaudeCredential? {
        if DemoMode.isEnabled { return nil }
        let now = Date()
        func resolved(_ credential: ClaudeCredential) -> ClaudeCredential {
            ClaudeCredential(accessToken: credential.accessToken, expiresAt: credential.expiresAt,
                             rateLimitTier: credential.rateLimitTier, source: source)
        }
        if let cached = securityToolCache.withLock({ $0 }),
           now.timeIntervalSince(cached.readAt) < 60,
           cached.credential.expiresAt.map({ $0 > now }) ?? true {
            return resolved(cached.credential)
        }
        guard let credential = runSecurityTool().flatMap({ try? decode(jsonString: $0, source: source) }) else {
            securityToolCache.withLock { $0 = nil }
            return nil
        }
        securityToolCache.withLock { $0 = (credential, now) }
        return credential
    }

    private static let securityToolCache =
        OSAllocatedUnfairLock<(credential: ClaudeCredential, readAt: Date)?>(initialState: nil)

    private static func runSecurityTool() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        // A healthy read returns in tens of milliseconds. Anything slower is
        // a Keychain dialog this app must not wait on.
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? stdout.fileHandleForReading.readToEnd(),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private static func readFromCredentialsJSON(source: CredentialSource = .cliDetected) throws -> ClaudeCredential {
        let url = RealHomeDirectory.url
            .appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: source)
    }

    private static func parseExpiresAt(_ any: Any?) -> Date? {
        switch any {
        case let n as NSNumber:
            // Could be seconds or milliseconds; assume ms if very large.
            let v = n.doubleValue
            return v > 1_000_000_000_000 ? Date(timeIntervalSince1970: v / 1000.0)
                                         : Date(timeIntervalSince1970: v)
        case let s as String:
            if let d = Double(s) {
                return d > 1_000_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0)
                                             : Date(timeIntervalSince1970: d)
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        default:
            return nil
        }
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let string = any as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
