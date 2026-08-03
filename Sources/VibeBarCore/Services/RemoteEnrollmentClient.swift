import Foundation
import CryptoKit
import CoreFoundation

/// Everything a successful `POST /api/v1/enroll/consume` produced: the same
/// non-secret configuration + Relay credential a provisioning file carries,
/// plus the freshly generated Core identity whose public halves the control
/// center just registered. Nothing here is installed yet — the caller decides
/// when to commit it through `RemoteCoreConfigStore.install(_:)`, so a failed
/// enrollment can never leave a half-written binding behind.
public struct RemoteEnrollmentResult: Sendable {
    public let provisioning: RemoteCoreProvisioning
    public let identity: RemoteCoreIdentity
    /// Server-assigned display name for this Mac, echoed back for the UI.
    public let deviceName: String
}

/// Failure taxonomy for the join-with-code flow. Every case carries a short
/// stable `code` for logs and a human-readable `message` for the settings
/// pane. Neither ever contains the pairing code, the bearer token, or key
/// material — see AGENTS.md § 8.
public enum RemoteEnrollmentError: Error, Equatable, Sendable {
    /// The control-center address is not a bare `https://host` origin.
    case invalidControlURL
    /// The pasted code is empty or not shaped like a pairing code.
    case invalidCode
    /// HTTP 404 `{"error": "invalid_code"}` — unknown, consumed, or expired.
    case codeRejected
    /// HTTP 409 `{"error": "core_exists"}` — the workspace already has a Core.
    case coreExists
    /// The grant was minted for a probe, so this Mac must not consume it.
    case wrongRole(String)
    /// HTTP 429 — the device endpoint's per-IP token bucket.
    case rateLimited
    /// Any other non-201 status.
    case server(Int)
    /// Transport failure: DNS, TLS, offline, timeout.
    case network
    /// 201 whose body does not match the documented contract.
    case malformedResponse
    /// The control center echoed a Core key other than the one this Mac just
    /// generated, so nothing encrypted to it could ever be opened here.
    case coreKeyMismatch

    public var code: String {
        switch self {
        case .invalidControlURL: return "invalid_control_url"
        case .invalidCode: return "invalid_pairing_code"
        case .codeRejected: return "invalid_code"
        case .coreExists: return "core_exists"
        case .wrongRole: return "wrong_role"
        case .rateLimited: return "rate_limited"
        case .server: return "control_http_error"
        case .network: return "network_unreachable"
        case .malformedResponse: return "malformed_response"
        case .coreKeyMismatch: return "core_key_mismatch"
        }
    }

    public var message: String {
        switch self {
        case .invalidControlURL:
            return "The control center address must be an https:// origin with no path, such as https://vibebar.aqor.io."
        case .invalidCode:
            return "That doesn't look like a pairing code. Copy the code shown in the control center, for example VB-XXXXX-XXXXX."
        case .codeRejected:
            return "This pairing code is unknown, already used, or expired. Generate a fresh one in the control center — codes last 15 minutes."
        case .coreExists:
            return "This workspace already has a Core Mac. Revoke the existing Core in the control center, then join again."
        case .wrongRole(let role):
            return "This code enrolls a \(role), not a Core Mac. Create a Core code in the control center and try again."
        case .rateLimited:
            return "Too many join attempts from this network. Wait a minute and try again."
        case .server(let status):
            return "The control center returned an unexpected error (HTTP \(status)). Try again in a moment."
        case .network:
            return "Could not reach the control center. Check your network connection and the address, then try again."
        case .malformedResponse:
            return "The control center returned a response Vibe Bar could not use. Confirm the address points at your Vibe Bar control center."
        case .coreKeyMismatch:
            return "The control center registered a different Core key than this Mac generated. Join again with a fresh code."
        }
    }
}

/// Consumes a one-time pairing code from the web control center so this Mac
/// becomes a workspace's Core without a provisioning file.
///
/// The exchange is deliberately one-shot and side-effect free: a fresh signing
/// and a fresh key-agreement P-256 keypair are generated in memory, only their
/// public halves leave the machine, and the private halves are handed back to
/// the caller inside `RemoteEnrollmentResult`. They reach the credential Vault
/// only when the caller installs the result, so an HTTP failure, a malformed
/// body, or a rejected code all leave the existing Core identity untouched.
public struct RemoteEnrollmentClient: Sendable {
    /// AstroQore's hosted control center. Callers may point at another
    /// deployment; the origin is still required to be HTTPS.
    public static let defaultControlURL = URL(string: "https://vibebar.aqor.io")!

    private let controlURL: URL
    private let session: URLSession

    /// - Throws: `RemoteEnrollmentError.invalidControlURL` unless `controlURL`
    ///   is a bare HTTPS origin. Mirrors the `relayURL` rule in
    ///   `RemoteCoreConfig` so both endpoints are validated identically.
    public init(
        controlURL: URL = RemoteEnrollmentClient.defaultControlURL,
        session: URLSession = RemoteEnrollmentClient.makeSession()
    ) throws {
        guard controlURL.scheme?.lowercased() == "https",
              controlURL.host != nil,
              controlURL.user == nil,
              controlURL.password == nil,
              controlURL.path.isEmpty || controlURL.path == "/",
              controlURL.query == nil,
              controlURL.fragment == nil
        else { throw RemoteEnrollmentError.invalidControlURL }
        self.controlURL = controlURL
        self.session = session
    }

    /// Parses a user-typed control-center address. Empty input falls back to
    /// the hosted default so the advanced field can be left blank.
    public static func controlURL(from raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultControlURL }
        guard let url = URL(string: trimmed) else {
            throw RemoteEnrollmentError.invalidControlURL
        }
        return url
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: RemoteNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// Best-effort friendly name for this Mac. The control center needs
    /// something a human recognizes in the device list; the host name is what
    /// the probe CLI uses for the same purpose. Resolved once — the settings
    /// pane reads it from a SwiftUI body, which must not repeat a syscall.
    public static func defaultDeviceName() -> String { cachedDeviceName }

    private static let cachedDeviceName: String = {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Mac" }
        return String(name.prefix(96))
    }()

    /// Normalizes a pasted pairing code: whitespace trimmed, uppercased.
    /// Rejects anything outside the `VB-XXXXX-XXXXX` character set early so an
    /// obvious typo never becomes an HTTP round-trip.
    public static func normalizedCode(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (1...64).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "-") })
        else { throw RemoteEnrollmentError.invalidCode }
        return trimmed
    }

    /// Exchanges a one-time code for this workspace's Core provisioning.
    public func enrollCore(
        code rawCode: String,
        deviceName rawName: String = RemoteEnrollmentClient.defaultDeviceName()
    ) async throws -> RemoteEnrollmentResult {
        let code = try RemoteEnrollmentClient.normalizedCode(rawCode)
        // The contract requires 1–96 characters; fall back rather than fail,
        // because a blank name is never worth losing a single-use code over.
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(
            (trimmedName.isEmpty ? RemoteEnrollmentClient.defaultDeviceName() : trimmedName)
                .prefix(96)
        )

        let identity = RemoteCoreIdentity(
            signingPrivateKey: P256.Signing.PrivateKey(),
            recipientPrivateKey: P256.KeyAgreement.PrivateKey()
        )
        let descriptor = identity.publicDescriptor

        var request = URLRequest(
            url: controlURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("enroll")
                .appendingPathComponent("consume")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "code": code,
                "name": name,
                "platform": "macos",
                "signing_public_key": descriptor.signingPublicKey.base64EncodedString(),
                "encryption_public_key": descriptor.recipientPublicKey.base64EncodedString()
            ],
            options: [.sortedKeys]
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPResponseLimit.boundedData(
                from: session,
                for: request,
                maxBytes: 64 * 1024
            )
        } catch {
            SafeLog.net("remote enroll failed: transport")
            throw RemoteEnrollmentError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteEnrollmentError.malformedResponse
        }
        guard http.statusCode == 201 else {
            let error = RemoteEnrollmentClient.mapFailure(
                status: http.statusCode,
                body: data
            )
            SafeLog.net("remote enroll rejected: \(error.code)")
            throw error
        }

        let result = try RemoteEnrollmentClient.makeResult(
            body: data,
            identity: identity,
            deviceName: name
        )
        SafeLog.net("remote enroll accepted: role=core")
        return result
    }

    /// The contract distinguishes only two error bodies; everything else is
    /// mapped by status so an unexpected shape still reaches the user as a
    /// plain HTTP problem instead of a silent failure.
    static func mapFailure(status: Int, body: Data) -> RemoteEnrollmentError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let marker = (object?["error"] as? String) ?? ""
        switch (status, marker) {
        case (404, _), (_, "invalid_code"):
            return .codeRejected
        case (409, _):
            return .coreExists
        case (429, _):
            return .rateLimited
        default:
            return .server(status)
        }
    }

    /// Validates the 201 body against §2 "Device endpoint" of the control API
    /// contract and folds it into the exact `RemoteCoreProvisioning` a
    /// provisioning file would have produced.
    static func makeResult(
        body: Data,
        identity: RemoteCoreIdentity,
        deviceName: String
    ) throws -> RemoteEnrollmentResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let workspaceRaw = object["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw),
              let deviceRaw = object["device_id"] as? String,
              let deviceID = UUID(uuidString: deviceRaw),
              let role = object["role"] as? String,
              let relayRaw = object["relay_url"] as? String,
              let relayURL = URL(string: relayRaw),
              let bearerToken = object["bearer_token"] as? String,
              let core = object["core"] as? [String: Any],
              let corePublicRaw = core["public_key"] as? String,
              let corePublicKey = Data(base64Encoded: corePublicRaw),
              let epoch = exactInteger(core["epoch"]),
              let keyID = core["key_id"] as? String
        else { throw RemoteEnrollmentError.malformedResponse }

        guard role == "core" else { throw RemoteEnrollmentError.wrongRole(role) }
        guard corePublicKey == identity.recipientPrivateKey.publicKey.x963Representation else {
            throw RemoteEnrollmentError.coreKeyMismatch
        }
        guard let epochValue = Int(exactly: epoch) else {
            throw RemoteEnrollmentError.malformedResponse
        }

        // A workspace this Mac just joined has no registered probes yet; their
        // signing keys arrive when each probe enrolls. Every other field is
        // validated by RemoteCoreProvisioning itself, so an out-of-contract
        // relay URL, epoch, key id, or bearer token surfaces here as a
        // malformed response rather than an unusable installed config.
        do {
            let provisioning = try RemoteCoreProvisioning(
                workspaceID: workspaceID,
                coreDeviceID: deviceID,
                relayURL: relayURL,
                relayBearerToken: bearerToken,
                coreEpoch: epochValue,
                ingestKeyID: keyID,
                probeSigningPublicKeys: [:]
            )
            return RemoteEnrollmentResult(
                provisioning: provisioning,
                identity: identity,
                deviceName: deviceName
            )
        } catch {
            throw RemoteEnrollmentError.malformedResponse
        }
    }

    private static func exactInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let type = String(cString: number.objCType)
        guard type != "f", type != "d" else { return nil }
        return number.int64Value
    }
}
