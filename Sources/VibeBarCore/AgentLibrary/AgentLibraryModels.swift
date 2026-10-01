import Foundation

public enum AgentLibraryTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, gemini, grok
    public var id: String { rawValue }
    public var mcpRelativePath: String {
        switch self {
        case .codex: ".codex/config.toml"
        case .claude: ".claude.json"
        case .cursor: ".cursor/mcp.json"
        case .gemini: ".gemini/settings.json"
        case .grok: ".grok/config.toml"
        }
    }
    public var instructionRelativePath: String? {
        switch self {
        case .codex: ".codex/AGENTS.md"
        case .claude: ".claude/CLAUDE.md"
        case .gemini: ".gemini/GEMINI.md"
        case .cursor, .grok: nil
        }
    }
    var isTOML: Bool { self == .codex || self == .grok }
    var headerKey: String { self == .codex ? "http_headers" : "headers" }
}

public enum AgentLibraryFileStatus: String, Codable, Sendable {
    case ready, missing, invalid, unsafe, unsupported
}

public enum AgentMCPTransport: String, Codable, Sendable { case stdio, http, sse, unknown }

/// Explicit editing data only. Ordinary inventory never projects these values.
public indirect enum AgentLibraryValue: Codable, Equatable, Sendable {
    case string(String), integer(Int64), unsignedInteger(UInt64), number(Double), bool(Bool), array([AgentLibraryValue])
    case object([String: AgentLibraryValue]), null
    /// A TOML expression retained verbatim; changing or moving it is refused.
    case opaqueTOML(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([AgentLibraryValue].self) { self = .array(value) }
        else {
            let value = try c.decode([String: AgentLibraryValue].self)
            if value.count == 1, case let .string(raw)? = value["$preservedTOML"] { self = .opaqueTOML(raw) }
            else { self = .object(value) }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .integer(let value): try c.encode(value)
        case .unsignedInteger(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .null: try c.encodeNil()
        case .opaqueTOML(let value): try c.encode(["$preservedTOML": value])
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var object: [String: AgentLibraryValue]? { if case .object(let value) = self { value } else { nil } }
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let result = values.compactMap(\.string)
        return result.count == values.count ? result : nil
    }
    var stringMap: [String: String]? {
        guard let values = object else { return nil }
        let result = values.compactMapValues(\.string)
        return result.count == values.count ? result : nil
    }
}

public struct AgentMCPDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var transport: AgentMCPTransport
    public var command: String?
    public var args: [String]
    public var environment: [String: String]
    public var url: String?
    public var headers: [String: String]
    public var rawFields: [String: AgentLibraryValue]
    public var sourceTarget: AgentLibraryTarget?
    public init(name: String, transport: AgentMCPTransport = .stdio, command: String? = nil,
                args: [String] = [], environment: [String: String] = [:], url: String? = nil,
                headers: [String: String] = [:], rawFields: [String: AgentLibraryValue] = [:],
                sourceTarget: AgentLibraryTarget? = nil) {
        self.name = name; self.transport = transport; self.command = command
        self.args = args; self.environment = environment; self.url = url
        self.headers = headers; self.rawFields = rawFields; self.sourceTarget = sourceTarget
    }
}

public struct AgentLibraryFileSummary: Sendable, Identifiable {
    public let target: AgentLibraryTarget
    public let path: String
    public let revision: String
    public let status: AgentLibraryFileStatus
    public let errorCode: String?
    public var id: String { target.rawValue }
}

public struct AgentMCPDefinitionSummary: Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Opaque action identity accepted by read/delete/share.
    public let operationName: String
    public let target: AgentLibraryTarget
    public let path: String
    public let revision: String
    public let transport: AgentMCPTransport
    public let redactedDescription: String
    public let sharedWith: [AgentLibraryTarget]
    public let matchingTargets: [AgentLibraryTarget]
    public let status: AgentLibraryFileStatus
    public let errorCode: String?
    public let projectionOwned: Bool
    public let sharedSourceTarget: AgentLibraryTarget?
    /// Rows for one server name across targets share this identity. It is
    /// derived from the real name, so redacted display names cannot merge.
    public let groupID: String
    /// Targets this definition cannot be shared into, with the error code the
    /// share would fail with (transport, name rules, unportable fields).
    public let unsupportedTargets: [AgentLibraryTarget: String]
}

public struct AgentMCPInventory: Sendable {
    public let files: [AgentLibraryFileSummary]
    public let definitions: [AgentMCPDefinitionSummary]
}
public struct AgentMCPEditDocument: Sendable {
    public let definition: AgentMCPDefinition
    public let revision: String
}
public struct AgentInstructionSummary: Sendable, Identifiable {
    public let id: String
    public let target: AgentLibraryTarget?
    public let path: String
    public let resolvedPath: String?
    public let revision: String
    public let status: AgentLibraryFileStatus
    public let isSymlink: Bool
    public let isCanonical: Bool
    public let overridePath: String?
    public let projectionOwned: Bool
    public let errorCode: String?
    /// The leaf link's own text, as written by whoever created it.
    public let linkDestination: String?
    /// The agent reads the same file as the shared instructions: its link
    /// chain ends where the canonical file's does, whoever created the link
    /// (or the canonical file links to this agent's own file). Sharing is
    /// recognised by path alone; ownership is still `projectionOwned`.
    public let sharesCanonical: Bool
}
public struct AgentInstructionDocument: Sendable {
    public let id: String
    public let text: String
    public let revision: String
}
public struct AgentLibraryProblem: Sendable {
    public let target: AgentLibraryTarget?
    public let code: String
}
public struct AgentLibraryBackup: Codable, Sendable, Identifiable {
    public let id: String
    public let relativePath: String
    public let createdAt: Date
}
public struct AgentLibraryMutationResult: Sendable {
    public var changed: [AgentLibraryTarget]
    public var unchanged: [AgentLibraryTarget]
    public var problems: [AgentLibraryProblem]
    public var backups: [AgentLibraryBackup]
    public init(changed: [AgentLibraryTarget] = [], unchanged: [AgentLibraryTarget] = [],
                problems: [AgentLibraryProblem] = [], backups: [AgentLibraryBackup] = []) {
        self.changed = changed; self.unchanged = unchanged; self.problems = problems; self.backups = backups
    }
}

public enum AgentLibraryError: String, Error, LocalizedError, Sendable {
    case invalidHome, unsafePath, symlinkLoop, unsupportedTarget, invalidDocument, invalidDefinition
    case unsupportedTransport, unsupportedConversion, staleRevision, sameNameConflict, notFound
    case notOwnedProjection, projectionModified, backupMissing, invalidBackup, ioFailure, oversizedFile
    case missingCanonical, unsupportedTOML, ambiguousDefinition, invalidReceipt
    public var code: String { rawValue }
    public var errorDescription: String? { code }
}
