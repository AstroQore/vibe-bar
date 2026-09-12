import Foundation

public enum DotDeviceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 401 / 403 — the stored API key is gone or was revoked.
    case unauthorized
    /// 404 on the canvas write: the Canvas API task is not in the device's
    /// loop. The API can only update an existing task, never create one, so
    /// this is the one 404 the user can actually fix — by adding the task on
    /// the phone. It is deliberately *not* what a 404 on any other endpoint
    /// means; telling someone to edit a loop when the device id is simply
    /// wrong sends them to the wrong screen.
    case taskNotInLoop
    /// 404 on a device-scoped read or settings write: no such device on this
    /// account, usually a device removed after Vibe Bar cached its roster.
    case deviceNotFound(deviceID: String)
    case rateLimited
    case http(code: Int)
    case network(String)
    case decoding(String)
    case invalidURL

    public var description: String {
        switch self {
        case .unauthorized: "Dot API rejected the key (401/403)"
        case .taskNotInLoop: "Dot API task not found in the device loop (404)"
        case let .deviceNotFound(deviceID): "Dot API has no device \(deviceID) on this account (404)"
        case .rateLimited: "Dot API rate limit reached (429)"
        case let .http(code): "Dot API returned HTTP \(code)"
        case let .network(detail): "Dot API network failure: \(detail)"
        case let .decoding(detail): "Dot API response could not be parsed: \(detail)"
        case .invalidURL: "Dot API URL could not be built"
        }
    }

    /// True when the key itself is the problem, so the sync engine should stop
    /// rather than retry.
    public var invalidatesCredential: Bool { self == .unauthorized }
}

/// The Dot. OpenAPI surface Vibe Bar uses.
///
/// Shaped like the repository's other HTTP clients: a value type over an
/// injected `URLSession`, an ephemeral configuration by default, no redirect
/// following, a 30 s timeout, and every response read through
/// `HTTPResponseLimit.boundedData`. The bearer token is passed in per call and
/// never stored on the struct, so it cannot leak into a log line by way of a
/// synthesized description.
public struct DotDeviceClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://dot.mindreset.tech")!
    /// The service allows 10 requests per second; the sync engine spaces
    /// pushes by this much.
    public static let minimumRequestInterval: TimeInterval = 0.15
    public static let timeout: TimeInterval = 30
    /// A canvas payload is capped at 128 KB of windowData; a render URL list
    /// is tiny. 1 MB is generous for every response we read.
    public static let maxResponseBytes = 1024 * 1024

    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL = DotDeviceClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? Self.makeSession()
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// The API never needs a redirect; following one would replay the bearer
    /// token against a host we did not choose.
    final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - Endpoints

    public func listDevices(apiKey: String) async throws -> [DotDevice] {
        // A 404 on the account-wide roster is not about any one device.
        let data = try await send(
            method: "GET",
            path: "/api/authV2/open/devices",
            apiKey: apiKey,
            notFound: .http(code: 404)
        )
        return try parse { try DotResponseParser.devices(data) }
    }

    public func status(deviceID: String, apiKey: String) async throws -> DotDeviceStatus {
        let data = try await send(
            method: "GET",
            path: "/api/authV2/open/device/\(encoded(deviceID))/status",
            apiKey: apiKey,
            notFound: .deviceNotFound(deviceID: deviceID)
        )
        return try parse { try DotResponseParser.status(data, deviceID: deviceID) }
    }

    public func listTasks(deviceID: String, type: DotTaskType, apiKey: String) async throws -> [DotTask] {
        let data = try await send(
            method: "GET",
            path: "/api/authV2/open/device/\(encoded(deviceID))/\(type.rawValue)/list",
            apiKey: apiKey,
            notFound: .deviceNotFound(deviceID: deviceID)
        )
        return try parse { try DotResponseParser.tasks(data) }
    }

    @discardableResult
    public func sendCanvas(deviceID: String, payload: DotCanvasPayload, apiKey: String) async throws -> String {
        let body: Data
        do {
            body = try payload.jsonData()
        } catch {
            throw DotDeviceError.decoding("payload encoding failed")
        }
        let data = try await send(
            method: "POST",
            path: "/api/authV2/open/device/\(encoded(deviceID))/canvas",
            apiKey: apiKey,
            body: body,
            notFound: .taskNotInLoop
        )
        return DotResponseParser.message(data)
    }

    /// Both intervals must be whole minutes between 1 minute and 12 hours.
    @discardableResult
    public func updateInterval(
        deviceID: String,
        powerMs: Int,
        batteryMs: Int,
        apiKey: String
    ) async throws -> String {
        let body = try? JSONSerialization.data(
            withJSONObject: ["interval": ["powerMs": Self.roundedInterval(powerMs), "batteryMs": Self.roundedInterval(batteryMs)]],
            options: [.sortedKeys]
        )
        guard let body else { throw DotDeviceError.decoding("interval encoding failed") }
        let data = try await send(
            method: "POST",
            path: "/api/authV2/open/device/\(encoded(deviceID))/settings",
            apiKey: apiKey,
            body: body,
            notFound: .deviceNotFound(deviceID: deviceID)
        )
        return DotResponseParser.message(data)
    }

    static func roundedInterval(_ milliseconds: Int) -> Int {
        let minute = 60_000
        let clamped = min(43_200_000, max(minute, milliseconds))
        return max(minute, (clamped / minute) * minute)
    }

    /// Downloads the panel render the status endpoint pointed at, so the
    /// settings pane can show what the device is actually displaying.
    ///
    /// The URL arrives inside an API response, which makes it untrusted input:
    /// only the service's own CDN over HTTPS is fetched, and the response is
    /// bounded to 2 MB. No credential is sent — the render links are
    /// pre-signed, and attaching the bearer token to a host chosen by a
    /// response body is exactly the mistake this avoids.
    public func fetchRenderImage(url: URL) async throws -> Data {
        guard DotRenderImagePolicy.isAllowed(url) else { throw DotDeviceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("image/png,image/*", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPResponseLimit.boundedData(
                from: session,
                for: request,
                maxBytes: DotRenderImagePolicy.maxBytes
            )
        } catch let error as HTTPResponseLimit.BoundedError {
            throw DotDeviceError.network(String(describing: error))
        } catch {
            throw DotDeviceError.network(SafeLog.sanitize(String(describing: error)))
        }
        guard let http = response as? HTTPURLResponse else { throw DotDeviceError.network("no HTTP response") }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw DotDeviceError.unauthorized
        case 429: throw DotDeviceError.rateLimited
        default: throw DotDeviceError.http(code: http.statusCode)
        }
    }

    // MARK: - Transport

    private func encoded(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
    }

    private func parse<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch {
            throw DotDeviceError.decoding(String(describing: error))
        }
    }

    /// What a 404 means depends entirely on which endpoint returned it, so
    /// every call site states its own mapping rather than sharing one guess.
    private func send(
        method: String,
        path: String,
        apiKey: String,
        body: Data? = nil,
        notFound: DotDeviceError
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw DotDeviceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPResponseLimit.boundedData(
                from: session,
                for: request,
                maxBytes: Self.maxResponseBytes
            )
        } catch let error as HTTPResponseLimit.BoundedError {
            throw DotDeviceError.network(String(describing: error))
        } catch {
            throw DotDeviceError.network(SafeLog.sanitize(String(describing: error)))
        }

        guard let http = response as? HTTPURLResponse else { throw DotDeviceError.network("no HTTP response") }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw DotDeviceError.unauthorized
        case 404: throw notFound
        case 429: throw DotDeviceError.rateLimited
        default: throw DotDeviceError.http(code: http.statusCode)
        }
    }
}

/// The slice of the Dot. API the sync engine uses, so a test can stand in for
/// the network without a `URLProtocol` stub for every case.
public protocol DotDeviceClienting: Sendable {
    func listDevices(apiKey: String) async throws -> [DotDevice]
    func status(deviceID: String, apiKey: String) async throws -> DotDeviceStatus
    func listTasks(deviceID: String, type: DotTaskType, apiKey: String) async throws -> [DotTask]
    @discardableResult
    func sendCanvas(deviceID: String, payload: DotCanvasPayload, apiKey: String) async throws -> String
    func fetchRenderImage(url: URL) async throws -> Data
}

extension DotDeviceClient: DotDeviceClienting {}
