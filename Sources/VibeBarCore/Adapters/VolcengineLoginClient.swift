import Foundation

/// Two-step Volcengine console login:
///
/// 1. `GET /api/passport/security/encCerts` — fetch a per-session RSA
///    JWK and let the server seed the `csrfToken` cookie.
/// 2. `POST /api/passport/login/mixtureLogin` with the password
///    RSA-PKCS1-v1.5-encrypted under that JWK, the JWK `kid` echoed
///    in `EncryptedKeyword`, the literal `Password` in
///    `EncryptedFields`, and the anti-replay `X-Authentication-Sign`
///    header derived from `VolcengineAuthSign`.
///
/// The session's `URLSession` is mutated in place — its `HTTPCookieStorage`
/// receives the JWK seed cookie and the post-login session cookies.
struct VolcengineLoginClient {
    private let session: URLSession
    private let now: () -> Date

    init(session: URLSession, now: @escaping () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    /// Authenticate as a CAM sub-user. Throws `QuotaError.needsLogin`
    /// for credential-recoverable failures (`InvalidPassword`,
    /// `InvalidState`, MFA required) and `QuotaError.network` for
    /// transport / unrecognized server errors.
    func signIn(mainAccountId: String, subUsername: String, password: String) async throws {
        let cert = try await fetchEncCerts()
        let publicKey = try VolcengineRSAPublicKey.makePublicKey(jwkN: cert.modulus, jwkE: cert.exponent)
        let encryptedPassword: String
        do {
            encryptedPassword = try VolcengineRSAPublicKey.encryptPasswordPKCS1(password, publicKey: publicKey)
        } catch let error as VolcengineRSAPublicKey.RSAError {
            throw QuotaError.network("Volcengine RSA encryption failed: \(error)")
        }

        guard let csrfToken = currentCsrfToken(), !csrfToken.isEmpty else {
            // encCerts is supposed to seed `csrfToken`; if it didn't
            // we'd fail on the login regardless. Surface the actionable
            // error here.
            throw QuotaError.network("Volcengine encCerts did not seed a csrfToken cookie.")
        }

        var request = URLRequest(url: Self.mixtureLoginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "Accept-Language")
        request.setValue(csrfToken, forHTTPHeaderField: "x-csrf-token")
        request.setValue(cert.kid, forHTTPHeaderField: "EncryptedKeyword")
        request.setValue("Password", forHTTPHeaderField: "EncryptedFields")
        request.setValue(VolcengineAuthSign.headerValue(now: now()), forHTTPHeaderField: "X-Authentication-Sign")
        request.setValue("https://console.volcengine.com", forHTTPHeaderField: "Origin")
        request.setValue("https://console.volcengine.com/auth/login", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let body: [String: Any] = [
            "Username": subUsername,
            "AccountInfo": mainAccountId,
            "EventName": "AuthUserWithPassword",
            "Password": encryptedPassword
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Volcengine login network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("Volcengine login: invalid response object")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Volcengine login returned HTTP \(http.statusCode).")
        }

        let envelope: VolcengineEnvelope
        do {
            envelope = try JSONDecoder().decode(VolcengineEnvelope.self, from: data)
        } catch {
            throw QuotaError.network("Volcengine login response not parseable: \(error.localizedDescription)")
        }
        if let err = envelope.responseMetadata?.error {
            // `InvalidState` after a stale replay is recoverable on the
            // next refresh — we wiped cookies before the call so it's
            // fair to surface needsLogin and let the user retry.
            let code = err.code?.lowercased() ?? ""
            let message = err.message?.trimmed ?? "code \(err.code ?? "?")"
            if code.contains("invalidpassword") || code.contains("invalidstate") ||
               code.contains("mfa") || code.contains("auth") || code.contains("login") {
                throw QuotaError.needsLogin
            }
            throw QuotaError.network("Volcengine login: \(message)")
        }
    }

    // MARK: - encCerts

    private func fetchEncCerts() async throws -> EncCert {
        var request = URLRequest(url: Self.encCertsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://console.volcengine.com", forHTTPHeaderField: "Origin")
        request.setValue("https://console.volcengine.com/auth/login", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("Volcengine encCerts network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw QuotaError.network("Volcengine encCerts returned a bad response.")
        }
        let envelope: EncCertsEnvelope
        do {
            envelope = try JSONDecoder().decode(EncCertsEnvelope.self, from: data)
        } catch {
            throw QuotaError.network("Volcengine encCerts response not parseable: \(error.localizedDescription)")
        }
        guard let key = envelope.keys.first(where: { $0.kty == "RSA" && $0.use == "enc" }) ?? envelope.keys.first else {
            throw QuotaError.network("Volcengine encCerts: no RSA key found.")
        }
        return EncCert(kid: key.kid, modulus: key.n, exponent: key.e)
    }

    private func currentCsrfToken() -> String? {
        guard let cookies = session.configuration.httpCookieStorage?.cookies else { return nil }
        return cookies.first(where: { $0.name == "csrfToken" })?.value
    }

    // MARK: - URLs

    private static let encCertsURL = URL(string:
        "https://console.volcengine.com/api/passport/security/encCerts"
    )!
    private static let mixtureLoginURL = URL(string:
        "https://console.volcengine.com/api/passport/login/mixtureLogin"
    )!
}

// MARK: - Wire types

private struct EncCert {
    let kid: String
    let modulus: String
    let exponent: String
}

private struct EncCertsEnvelope: Decodable {
    let keys: [Key]

    struct Key: Decodable {
        let kty: String
        let kid: String
        let use: String?
        let alg: String?
        let n: String
        let e: String
    }
}

struct VolcengineEnvelope: Decodable {
    let responseMetadata: VolcengineResponseMetadata?
    let result: VolcengineResultPlaceholder?

    enum CodingKeys: String, CodingKey {
        case responseMetadata = "ResponseMetadata"
        case result = "Result"
    }
}

struct VolcengineResponseMetadata: Decodable {
    let error: VolcengineMetadataError?

    enum CodingKeys: String, CodingKey { case error = "Error" }
}

struct VolcengineMetadataError: Decodable {
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
    }
}

struct VolcengineResultPlaceholder: Decodable {}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
