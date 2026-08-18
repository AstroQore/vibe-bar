import Foundation

/// The small slice of JSON-RPC 2.0 the MCP server speaks, hand-rolled.
///
/// MCP's stdio transport is newline-delimited JSON-RPC: one complete JSON
/// object per line, UTF-8, no embedded newlines. Vibe Bar speaks the same
/// framing over a Unix domain socket, so the bridge in `MCPStdioBridge` is a
/// byte pump rather than a re-framer.
///
/// There is deliberately no SwiftPM dependency behind this. The surface is
/// four message shapes and a JSON value type; a package would be more code to
/// audit than the code it replaces.

// MARK: - JSON value

/// A JSON value that survives a round trip without a concrete Swift type.
///
/// Tool arguments arrive untyped and tool schemas are literal JSON, so both
/// ends of the dispatch table need a value that is `Codable` without a
/// matching struct. Integers keep their own case: re-encoding `1` as `1.0`
/// makes a token count look like a measurement.
public enum MCPJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])
}

extension MCPJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MCPJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case let .bool(value):   try container.encode(value)
        case let .int(value):    try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value):  try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension MCPJSON: ExpressibleByStringLiteral,
                   ExpressibleByIntegerLiteral,
                   ExpressibleByBooleanLiteral,
                   ExpressibleByArrayLiteral,
                   ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: MCPJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MCPJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension MCPJSON {
    public subscript(key: String) -> MCPJSON? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public var objectValue: [String: MCPJSON]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [MCPJSON]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// Whole numbers only. A client that sends `20.0` for a page size means
    /// twenty, so a `.double` with no fractional part answers here too.
    public var intValue: Int? {
        switch self {
        case let .int(value): return Int(exactly: value)
        case let .double(value):
            guard value.isFinite, value == value.rounded() else { return nil }
            return Int(exactly: value.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .int(value):    return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// A list of strings, tolerating the single-string spelling clients
    /// reach for when a filter happens to have one element.
    public var stringListValue: [String]? {
        switch self {
        case let .string(value): return [value]
        case let .array(values): return values.compactMap(\.stringValue)
        default: return nil
        }
    }
}

// MARK: - Codable bridging

extension MCPJSON {
    /// One encoder for every payload the server emits, so `structuredContent`
    /// and the human-readable `text` block can never disagree about a field
    /// name, a date format, or a rounding.
    public static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Project any `Encodable` payload into a JSON value.
    public static func encoding<T: Encodable>(_ value: T) throws -> MCPJSON {
        let data = try encoder(pretty: false).encode(value)
        return try JSONDecoder().decode(MCPJSON.self, from: data)
    }

    /// Pretty-printed JSON text for the `content` block agents actually read.
    public static func prettyText<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder(pretty: true).encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public func serialized() throws -> Data {
        try MCPJSON.encoder(pretty: false).encode(self)
    }
}

// MARK: - Errors

/// A JSON-RPC error object. Protocol-level failures travel as these; a tool
/// that ran and failed reports through `isError` on its result instead, which
/// is what MCP clients surface back to the model.
public struct MCPRPCError: Error, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: MCPJSON?

    public init(code: Int, message: String, data: MCPJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ message: String = "Invalid JSON.") -> MCPRPCError {
        MCPRPCError(code: -32_700, message: message)
    }

    public static func invalidRequest(_ message: String) -> MCPRPCError {
        MCPRPCError(code: -32_600, message: message)
    }

    public static func methodNotFound(_ method: String) -> MCPRPCError {
        MCPRPCError(code: -32_601, message: "Unknown method '\(method)'.")
    }

    public static func invalidParams(_ message: String) -> MCPRPCError {
        MCPRPCError(code: -32_602, message: message)
    }

    public static func internalError(_ message: String) -> MCPRPCError {
        MCPRPCError(code: -32_603, message: message)
    }

    var json: MCPJSON {
        var fields: [String: MCPJSON] = [
            "code": .int(Int64(code)),
            "message": .string(message)
        ]
        if let data { fields["data"] = data }
        return .object(fields)
    }
}

// MARK: - Messages

/// One decoded request or notification.
///
/// A notification is exactly a request with no `id`; the caller answers a
/// request and stays silent for a notification, which is what
/// `notifications/initialized` needs.
public struct MCPRequest: Sendable, Equatable {
    public let id: MCPJSON?
    public let method: String
    public let params: MCPJSON?

    public var isNotification: Bool { id == nil }

    public init(id: MCPJSON?, method: String, params: MCPJSON?) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decode one framed line.
    ///
    /// Throws `parseError` for bytes that are not JSON at all and
    /// `invalidRequest` for JSON that is not a JSON-RPC request — the two
    /// failures a client fixes in different places.
    public static func decode(line: Data) throws -> MCPRequest {
        let value: MCPJSON
        do {
            value = try JSONDecoder().decode(MCPJSON.self, from: line)
        } catch {
            throw MCPRPCError.parseError()
        }
        guard let fields = value.objectValue else {
            throw MCPRPCError.invalidRequest("A request must be a JSON object.")
        }
        guard let method = fields["method"]?.stringValue, !method.isEmpty else {
            throw MCPRPCError.invalidRequest("A request must carry a string 'method'.")
        }
        // `"jsonrpc": "2.0"` is required by the spec but not load-bearing here:
        // rejecting a client that omits it buys nothing, and a client that
        // sends a *different* version is a real mismatch worth naming.
        if let version = fields["jsonrpc"]?.stringValue, version != "2.0" {
            throw MCPRPCError.invalidRequest("Unsupported JSON-RPC version '\(version)'.")
        }
        let rawID = fields["id"]
        return MCPRequest(
            id: (rawID?.isNull ?? true) ? nil : rawID,
            method: method,
            params: fields["params"]
        )
    }
}

/// A response line, ready to frame.
public struct MCPResponse: Sendable, Equatable {
    public let id: MCPJSON
    public let payload: Result<MCPJSON, MCPRPCError>

    public init(id: MCPJSON, result: MCPJSON) {
        self.id = id
        self.payload = .success(result)
    }

    public init(id: MCPJSON, error: MCPRPCError) {
        self.id = id
        self.payload = .failure(error)
    }

    public var json: MCPJSON {
        var fields: [String: MCPJSON] = ["jsonrpc": .string("2.0"), "id": id]
        switch payload {
        case let .success(result): fields["result"] = result
        case let .failure(error):  fields["error"] = error.json
        }
        return .object(fields)
    }

    /// One line, newline included. Encoding cannot realistically fail — every
    /// value came from `MCPJSON` — but a failure must still produce a line, or
    /// the client waits forever for a reply that was silently dropped.
    public func framed() -> Data {
        var data = (try? json.serialized())
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding the response failed."}}"#.utf8)
        data.append(0x0A)
        return data
    }
}
