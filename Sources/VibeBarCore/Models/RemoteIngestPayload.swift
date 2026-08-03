import Foundation

struct RemoteIngestPayload: Decodable {
    let schema: Int
    let workspaceID: UUID
    let producerID: UUID
    let probe: Probe
    let previousSequence: Int64?
    let operations: [Operation]
    let status: Status

    struct Probe: Decodable {
        let alias: String
        let version: String
        let platform: String
        let timezone: String
    }

    struct Status: Decodable {
        let lastScanAt: String
        let backlogBatches: Int
        let appliedControlSequence: Int64
        let sources: [String: String]

        private enum CodingKeys: String, CodingKey {
            case lastScanAt = "last_scan_at"
            case backlogBatches = "backlog_batches"
            case appliedControlSequence = "applied_control_sequence"
            case sources
        }
    }

    enum Operation: Decodable {
        case usage(Usage)
        case sourceReset(SourceReset)

        private enum KindKeys: String, CodingKey { case op }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: KindKeys.self)
            switch try container.decode(String.self, forKey: .op) {
            case "usage_upsert": self = .usage(try Usage(from: decoder))
            case "source_reset": self = .sourceReset(try SourceReset(from: decoder))
            default: throw RemoteSyncError.invalidPayload
            }
        }
    }

    struct SourceReset: Decodable {
        let op: String
        let sourceKey: String
        let sourceGeneration: Int
        let tool: String
        let observedAt: String
        let parserVersion: Int

        private enum CodingKeys: String, CodingKey {
            case op, tool
            case sourceKey = "source_key"
            case sourceGeneration = "source_generation"
            case observedAt = "observed_at"
            case parserVersion = "parser_version"
        }
    }

    struct Usage: Decodable {
        let op: String
        let sourceKey: String
        let sourceGeneration: Int
        let eventKey: String
        let tool: String
        let occurredAt: String
        let observedAt: String
        let model: String?
        let tokens: Tokens
        let requestCount: Int
        let serviceTier: String?
        let accounting: String
        let parserVersion: Int

        private enum CodingKeys: String, CodingKey {
            case op, tool, model, tokens, accounting
            case sourceKey = "source_key"
            case sourceGeneration = "source_generation"
            case eventKey = "event_key"
            case occurredAt = "occurred_at"
            case observedAt = "observed_at"
            case requestCount = "request_count"
            case serviceTier = "service_tier"
            case parserVersion = "parser_version"
        }
    }

    struct Tokens: Decodable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        let reasoning: Int
        let tool: Int
        let totalOnly: Int?

        private enum CodingKeys: String, CodingKey {
            case input, output, reasoning, tool
            case cacheRead = "cache_read"
            case cacheCreation = "cache_creation"
            case totalOnly = "total_only"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schema, probe, operations, status
        case workspaceID = "workspace_id"
        case producerID = "producer_id"
        case previousSequence = "previous_sequence"
    }
}

enum RemotePayloadDecoder {
    private static let rootKeys: Set<String> = [
        "schema", "workspace_id", "producer_id", "probe", "previous_sequence",
        "operations", "status"
    ]
    private static let probeKeys: Set<String> = ["alias", "version", "platform", "timezone"]
    private static let statusKeys: Set<String> = [
        "last_scan_at", "backlog_batches", "applied_control_sequence", "sources"
    ]
    private static let usageKeys: Set<String> = [
        "op", "source_key", "source_generation", "event_key", "tool", "occurred_at",
        "observed_at", "model", "tokens", "request_count", "service_tier", "accounting",
        "parser_version"
    ]
    private static let resetKeys: Set<String> = [
        "op", "source_key", "source_generation", "tool", "observed_at", "parser_version"
    ]
    private static let tokenKeys: Set<String> = [
        "input", "output", "cache_read", "cache_creation", "reasoning", "tool", "total_only"
    ]
    private static let tools: Set<String> = ["codex", "claude", "antigravity", "grok"]
    private static let statuses: Set<String> = ["ok", "absent", "locked", "unsupported", "error"]

    static func decode(_ data: Data) throws -> RemoteIngestPayload {
        guard data.count <= 4 * 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == rootKeys,
              let probe = object["probe"] as? [String: Any], Set(probe.keys) == probeKeys,
              let status = object["status"] as? [String: Any], Set(status.keys) == statusKeys,
              let sourceStatuses = status["sources"] as? [String: String],
              Set(sourceStatuses.keys).isSubset(of: tools),
              sourceStatuses.values.allSatisfy(statuses.contains),
              let operations = object["operations"] as? [[String: Any]], operations.count <= 5000
        else { throw RemoteSyncError.invalidPayload }
        for operation in operations {
            switch operation["op"] as? String {
            case "usage_upsert":
                guard Set(operation.keys) == usageKeys,
                      let tokens = operation["tokens"] as? [String: Any],
                      Set(tokens.keys) == tokenKeys
                else { throw RemoteSyncError.invalidPayload }
            case "source_reset":
                guard Set(operation.keys) == resetKeys else {
                    throw RemoteSyncError.invalidPayload
                }
            default:
                throw RemoteSyncError.invalidPayload
            }
        }
        let payload = try JSONDecoder().decode(RemoteIngestPayload.self, from: data)
        try validate(payload)
        return payload
    }

    private static func validate(_ payload: RemoteIngestPayload) throws {
        guard payload.schema == 1,
              (1...96).contains(payload.probe.alias.count),
              (1...32).contains(payload.probe.version.count),
              (1...64).contains(payload.probe.platform.count),
              (1...64).contains(payload.probe.timezone.count),
              RemoteProtocolCrypto.parseTimestamp(payload.status.lastScanAt) != nil,
              (0...9_007_199_254_740_991).contains(payload.status.backlogBatches),
              (0...9_007_199_254_740_991).contains(payload.status.appliedControlSequence)
        else { throw RemoteSyncError.invalidPayload }
        for operation in payload.operations {
            switch operation {
            case let .sourceReset(reset):
                guard reset.op == "source_reset", (2..<Int(Int32.max)).contains(reset.sourceGeneration),
                      tools.contains(reset.tool), (1..<Int(Int32.max)).contains(reset.parserVersion),
                      validOpaqueKey(reset.sourceKey),
                      RemoteProtocolCrypto.parseTimestamp(reset.observedAt) != nil
                else { throw RemoteSyncError.invalidPayload }
            case let .usage(usage):
                let values = [
                    usage.tokens.input, usage.tokens.output, usage.tokens.cacheRead,
                    usage.tokens.cacheCreation, usage.tokens.reasoning, usage.tokens.tool,
                    usage.requestCount
                ]
                let componentTotal = values.dropLast().reduce(0, +)
                guard usage.op == "usage_upsert",
                      (1..<Int(Int32.max)).contains(usage.sourceGeneration),
                      tools.contains(usage.tool),
                      (1..<Int(Int32.max)).contains(usage.parserVersion),
                      validOpaqueKey(usage.sourceKey), validOpaqueKey(usage.eventKey),
                      values.allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }),
                      componentTotal <= 9_007_199_254_740_991,
                      RemoteProtocolCrypto.parseTimestamp(usage.occurredAt) != nil,
                      RemoteProtocolCrypto.parseTimestamp(usage.observedAt) != nil,
                      usage.model?.count ?? 0 <= 128,
                      usage.serviceTier?.count ?? 0 <= 64
                else { throw RemoteSyncError.invalidPayload }
                if let totalOnly = usage.tokens.totalOnly {
                    guard totalOnly >= 0, totalOnly <= 9_007_199_254_740_991,
                          usage.tokens.input == 0, usage.tokens.output == 0,
                          usage.tokens.cacheRead == 0, usage.tokens.cacheCreation == 0,
                          usage.tokens.reasoning == 0, usage.tokens.tool == 0
                    else { throw RemoteSyncError.invalidPayload }
                }
            }
        }
    }

    private static func validOpaqueKey(_ value: String) -> Bool {
        guard (32...96).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }
}
