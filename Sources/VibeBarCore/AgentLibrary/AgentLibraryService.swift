import Foundation

/// No default home, background sync, command execution or network handshake.
/// The host explicitly supplies the home and invokes individual operations.
public actor AgentLibraryService {
    let files: AgentLibraryFiles
    var mcpReceiptRevision: String?
    var instructionReceiptRevision: String?
    let beforeMCPReceiptWrite: (@Sendable (URL) throws -> Void)?
    public init(homeDirectory: URL) throws {
        files = try AgentLibraryFiles(homeDirectory: homeDirectory)
        beforeMCPReceiptWrite = nil
    }
    /// Internal filesystem-failure injection; application callers cannot
    /// replace the receipt writer or bypass its revision checks.
    init(homeDirectory: URL, beforeMCPReceiptWrite: @escaping @Sendable (URL) throws -> Void) throws {
        files = try AgentLibraryFiles(homeDirectory: homeDirectory)
        self.beforeMCPReceiptWrite = beforeMCPReceiptWrite
    }

    public func mcpInventory() -> AgentMCPInventory {
        let receipts = try? mcpReceipts()
        var summaries: [AgentLibraryFileSummary] = []
        var found: [(AgentLibraryTarget, AgentLibraryFileSnapshot, AgentMCPDefinition)] = []
        for target in AgentLibraryTarget.allCases {
            do {
                let document = try mcpFile(target)
                summaries.append(.init(target: target, path: document.snapshot.logical.path,
                                       revision: document.snapshot.revision,
                                       status: document.snapshot.data == nil ? .missing : .ready, errorCode: nil))
                for name in document.entries.keys.sorted() {
                    let definition = Self.decode(name: name, fields: document.entries[name]!, target: target)
                    found.append((target, document.snapshot, definition))
                }
            } catch {
                let code = Self.code(error)
                summaries.append(.init(target: target, path: files.home.appendingPathComponent(target.mcpRelativePath).path,
                                       revision: "unavailable", status: Self.status(error), errorCode: code))
            }
        }
        let definitions = found.map { target, snapshot, definition in
            let peers = found.filter { $0.0 != target && $0.2.name == definition.name }
            let error = Self.validationError(definition, target: target)
            let token = Self.operationToken(target: target, name: definition.name)
            let receipt = receipts?[token]
            let owned = receipt?.fingerprint == Self.definitionFingerprint(definition.rawFields)
            return AgentMCPDefinitionSummary(
                id: token,
                name: VisibleSecretRedactor.redact(definition.name) ?? "<redacted>", operationName: token, target: target,
                path: snapshot.logical.path, revision: snapshot.revision, transport: definition.transport,
                // Values, command paths, URLs and arguments are deliberately
                // absent, including values that don't resemble known secrets.
                redactedDescription: definition.transport.rawValue + " · args:" + String(definition.args.count)
                    + " · env:" + String(definition.environment.count) + " · headers:" + String(definition.headers.count),
                sharedWith: peers.map(\.0),
                matchingTargets: peers.filter { Self.same(definition, $0.2) }.map(\.0),
                status: error == nil ? .ready : .unsupported, errorCode: error?.code,
                projectionOwned: owned, sharedSourceTarget: owned ? receipt?.source : nil)
        }
        return .init(files: summaries, definitions: definitions)
    }

    public func readMCPDefinition(target: AgentLibraryTarget, name: String, expectedRevision: String) throws -> AgentMCPEditDocument {
        let document = try mcpFile(target, expectedRevision: expectedRevision)
        let actualName = try Self.lookup(name, target: target, entries: document.entries)
        return .init(definition: Self.decode(name: actualName, fields: document.entries[actualName]!, target: target),
                     revision: document.snapshot.revision)
    }

    public func saveMCPDefinition(target: AgentLibraryTarget, definition: AgentMCPDefinition,
                                  expectedRevision: String, replaceExisting: Bool = false) throws -> AgentLibraryMutationResult {
        try writeMCPDefinition(target: target, definition: definition, expectedRevision: expectedRevision,
                               replaceExisting: replaceExisting)
    }

    /// Every native write first withdraws the old incoming permission. Only
    /// shareMCPDefinition publishes a new receipt after a successful write.
    func writeMCPDefinition(target: AgentLibraryTarget, definition: AgentMCPDefinition,
                            expectedRevision: String, replaceExisting: Bool) throws -> AgentLibraryMutationResult {
        if let error = Self.validationError(definition, target: target) { throw error }
        let document = try mcpFile(target, expectedRevision: expectedRevision)
        let old = document.entries[definition.name]
        let desired = try Self.fields(definition, target: target, existing: old)
        if let old {
            if old == desired { return .init(unchanged: [target]) }
            guard replaceExisting else { throw AgentLibraryError.sameNameConflict }
        }
        let data = try document.replacing(definition.name, fields: desired)
        _ = try files.prepareWrite(target.mcpRelativePath, data: data, expectedRevision: expectedRevision)
        try revokeMCPReceipts(target: target, name: definition.name)
        let backup = try files.write(target.mcpRelativePath, data: data, expectedRevision: expectedRevision)
        return .init(changed: [target], backups: [backup])
    }

    public func deleteMCPDefinition(target: AgentLibraryTarget, name: String, expectedRevision: String) throws -> AgentLibraryMutationResult {
        let document = try mcpFile(target, expectedRevision: expectedRevision)
        let actualName = try Self.lookup(name, target: target, entries: document.entries)
        let data = try document.replacing(actualName, fields: nil)
        _ = try files.prepareWrite(target.mcpRelativePath, data: data, expectedRevision: expectedRevision)
        try revokeMCPReceipts(target: target, name: actualName)
        let backup = try files.write(target.mcpRelativePath, data: data, expectedRevision: expectedRevision)
        return .init(changed: [target], backups: [backup])
    }

    public func shareMCPDefinition(source: AgentLibraryTarget, name: String, sourceRevision: String,
                                   targets: [AgentLibraryTarget: String]) throws -> AgentLibraryMutationResult {
        let sourceDocument = try readMCPDefinition(target: source, name: name, expectedRevision: sourceRevision)
        let name = sourceDocument.definition.name
        if let error = Self.validationError(sourceDocument.definition, target: source) { throw error }
        var result = AgentLibraryMutationResult()
        for target in AgentLibraryTarget.allCases where targets[target] != nil {
            if target == source { result.unchanged.append(target); continue }
            do {
                // A source changed during a multi-target operation must not
                // be copied into the next target using its stale content.
                _ = try files.guarded(source.mcpRelativePath, revision: sourceRevision)
                let document = try mcpFile(target, expectedRevision: targets[target]!)
                var replaceExisting = false
                if let old = document.entries[name] {
                    if Self.same(sourceDocument.definition, Self.decode(name: name, fields: old, target: target)) {
                        result.unchanged.append(target)
                        continue
                    }
                    let receipt = try mcpReceipts()[Self.operationToken(target: target, name: name)]
                    guard receipt?.source == source, receipt?.fingerprint == Self.definitionFingerprint(old) else {
                        throw AgentLibraryError.sameNameConflict
                    }
                    replaceExisting = true
                }
                let change = try writeMCPDefinition(target: target, definition: sourceDocument.definition,
                                                    expectedRevision: targets[target]!, replaceExisting: replaceExisting)
                result.changed += change.changed; result.unchanged += change.unchanged
                result.backups += change.backups
                let written = try mcpFile(target)
                guard let fields = written.entries[name] else { throw AgentLibraryError.ioFailure }
                let token = Self.operationToken(target: target, name: name)
                // Never re-publish a pre-revocation local snapshot: direct
                // edits/deletes and other selected writes may withdraw keys.
                var receipts = try mcpReceipts()
                receipts[token] = .init(source: source, target: target, name: name,
                                        fingerprint: Self.definitionFingerprint(fields))
                try saveMCPReceipts(receipts)
            } catch { result.problems.append(.init(target: target, code: Self.code(error))) }
        }
        return result
    }

    public func restoreBackup(id: String, expectedRevision: String) throws -> AgentLibraryMutationResult {
        let record = try files.backup(id)
        _ = try files.prepareRestore(record, expectedRevision: expectedRevision)
        if let target = AgentLibraryTarget.allCases.first(where: { $0.mcpRelativePath == record.relativePath }) {
            // Restoring a whole native config withdraws all incoming
            // permissions for this target, even if some values coincide.
            try revokeMCPReceipts(target: target)
        } else if let target = AgentLibraryTarget.allCases.first(where: { $0.instructionRelativePath == record.relativePath }) {
            // This entry point replaces a projection leaf, unlike an
            // instruction edit through a link that only updates its source.
            var receipts = try instructionReceipts()
            if receipts.removeValue(forKey: target.rawValue) != nil { try saveInstructionReceipts(receipts) }
        }
        let backup = try files.restore(record, expectedRevision: expectedRevision)
        let target = AgentLibraryTarget.allCases.first {
            $0.mcpRelativePath == record.relativePath || $0.instructionRelativePath == record.relativePath
        }
        return .init(changed: target.map { [$0] } ?? [], backups: [backup])
    }

    struct MCPFile {
        let snapshot: AgentLibraryFileSnapshot
        let entries: [String: [String: AgentLibraryValue]]
        let json: [String: AgentLibraryValue]?
        let toml: AgentLibraryTOML?
        func replacing(_ name: String, fields: [String: AgentLibraryValue]?) throws -> Data {
            if let toml { return try toml.replacing(name, fields: fields) }
            var root = json ?? [:]
            var servers = entries.mapValues(AgentLibraryValue.object)
            if let fields { servers[name] = .object(fields) } else { servers.removeValue(forKey: name) }
            root["mcpServers"] = .object(servers)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(root) + Data("\n".utf8)
        }
    }
    func mcpFile(_ target: AgentLibraryTarget, expectedRevision: String? = nil) throws -> MCPFile {
        let snapshot = try expectedRevision.map { try files.guarded(target.mcpRelativePath, revision: $0) }
            ?? files.snapshot(target.mcpRelativePath)
        if target.isTOML {
            let toml = try AgentLibraryTOML(snapshot.data)
            return .init(snapshot: snapshot, entries: toml.entries, json: nil, toml: toml)
        }
        let root: [String: AgentLibraryValue]
        if let data = snapshot.data {
            guard let decoded = try? JSONDecoder().decode([String: AgentLibraryValue].self, from: data) else {
                throw AgentLibraryError.invalidDocument
            }
            root = decoded
        } else { root = [:] }
        var entries: [String: [String: AgentLibraryValue]] = [:]
        if let servers = root["mcpServers"] {
            guard let object = servers.object else { throw AgentLibraryError.invalidDocument }
            for (name, value) in object {
                guard let fields = value.object else { throw AgentLibraryError.invalidDefinition }
                entries[name] = fields
            }
        }
        return .init(snapshot: snapshot, entries: entries, json: root, toml: nil)
    }

    static let commonKeys: Set<String> = ["type", "command", "args", "env", "url", "httpUrl", "headers", "http_headers"]
    static func nativeKeys(_ target: AgentLibraryTarget) -> Set<String> {
        let base: Set<String> = ["command", "args", "env"]
        switch target {
        case .codex: return base.union(["url", "http_headers", "type"])
        case .gemini: return base.union(["url", "httpUrl", "headers"])
        case .claude, .cursor, .grok: return base.union(["type", "url", "headers"])
        }
    }
    static func decode(name: String, fields: [String: AgentLibraryValue], target: AgentLibraryTarget) -> AgentMCPDefinition {
        let explicit = fields["type"]?.string
        let transport: AgentMCPTransport
        let url: String?
        if target == .gemini, let http = fields["httpUrl"]?.string { transport = .http; url = http }
        else if let remote = fields["url"]?.string {
            transport = (target == .gemini || explicit == "sse") ? .sse : (explicit == nil || explicit == "http" ? .http : .unknown)
            url = remote
        } else { transport = explicit == nil || explicit == "stdio" ? .stdio : .unknown; url = nil }
        var definition = AgentMCPDefinition(name: name, transport: transport, command: fields["command"]?.string,
                                            args: fields["args"]?.strings ?? [], environment: fields["env"]?.stringMap ?? [:],
                                            url: url, headers: fields[target.headerKey]?.stringMap ?? [:],
                                            rawFields: fields, sourceTarget: target)
        for key in ["command", "url", "httpUrl"] where fields[key] != nil && fields[key]?.string == nil {
            definition.transport = .unknown
        }
        if fields["args"] != nil && fields["args"]?.strings == nil { definition.transport = .unknown }
        if fields["type"] != nil && fields["type"]?.string == nil { definition.transport = .unknown }
        if fields["env"] != nil && fields["env"]?.stringMap == nil { definition.transport = .unknown }
        if fields[target.headerKey] != nil && fields[target.headerKey]?.stringMap == nil { definition.transport = .unknown }
        if fields["httpUrl"] != nil && fields["url"] != nil { definition.transport = .unknown }
        return definition
    }
    static func validationError(_ definition: AgentMCPDefinition, target: AgentLibraryTarget) -> AgentLibraryError? {
        guard !definition.name.isEmpty, definition.name.count <= 128,
              !definition.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .invalidDefinition
        }
        if target == .grok {
            guard definition.name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
                  !definition.name.contains("__"), !definition.name.hasSuffix("_") else { return .invalidDefinition }
        }
        if definition.transport == .unknown { return .unsupportedTransport }
        if definition.transport == .sse && target == .codex { return .unsupportedTransport }
        if definition.transport == .stdio {
            if definition.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || definition.url != nil || !definition.headers.isEmpty { return .invalidDefinition }
        } else {
            guard definition.command == nil, definition.args.isEmpty, definition.environment.isEmpty,
                  let url = definition.url, let components = URLComponents(string: url),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else {
                return .invalidDefinition
            }
        }
        return nil
    }
    static func fields(_ definition: AgentMCPDefinition, target: AgentLibraryTarget,
                        existing: [String: AgentLibraryValue]?) throws -> [String: AgentLibraryValue] {
        let sourceKeys = definition.sourceTarget.map(nativeKeys) ?? commonKeys
        var extras = definition.rawFields.filter { !sourceKeys.contains($0.key) }
        if let source = definition.sourceTarget, source != target {
            if case .bool(true)? = extras["enabled"] {
                if !target.isTOML { extras.removeValue(forKey: "enabled") }
            } else if extras["enabled"] != nil && !target.isTOML {
                throw AgentLibraryError.unsupportedConversion
            }
            let portable: Set<String> = source.isTOML && target.isTOML
                ? ["enabled", "startup_timeout_sec", "tool_timeout_sec"] : ["enabled"]
            if extras.keys.contains(where: { !portable.contains($0) }) { throw AgentLibraryError.unsupportedConversion }
        }
        var fields = (existing ?? [:]).filter { !nativeKeys(target).contains($0.key) }
        fields.merge(extras) { _, new in new }
        if definition.transport == .stdio {
            fields["command"] = .string(definition.command!)
            fields["args"] = .array(definition.args.map(AgentLibraryValue.string))
            if !definition.environment.isEmpty { fields["env"] = .object(definition.environment.mapValues(AgentLibraryValue.string)) }
        } else {
            fields[target == .gemini && definition.transport == .http ? "httpUrl" : "url"] = .string(definition.url!)
            if !definition.headers.isEmpty { fields[target.headerKey] = .object(definition.headers.mapValues(AgentLibraryValue.string)) }
        }
        if target == .claude || ((target == .cursor || target == .grok) && definition.transport == .sse) {
            fields["type"] = .string(definition.transport.rawValue)
        }
        return fields
    }
    static func same(_ left: AgentMCPDefinition, _ right: AgentMCPDefinition) -> Bool {
        left.transport == right.transport && left.command == right.command && left.args == right.args
            && left.environment == right.environment && left.url == right.url && left.headers == right.headers
            && comparableExtras(left) == comparableExtras(right)
    }
    static func comparableExtras(_ definition: AgentMCPDefinition) -> [String: AgentLibraryValue] {
        let keys = definition.sourceTarget.map(nativeKeys) ?? commonKeys
        return definition.rawFields.filter {
            !keys.contains($0.key) && !($0.key == "enabled" && $0.value == .bool(true))
        }
    }
    static func code(_ error: Error) -> String { (error as? AgentLibraryError)?.code ?? AgentLibraryError.ioFailure.code }
    static func operationToken(target: AgentLibraryTarget, name: String) -> String {
        "mcp-id:" + AgentLibraryFiles.digest(Data((target.rawValue + "\n" + name).utf8))
    }
    static func lookup(_ input: String, target: AgentLibraryTarget,
                       entries: [String: [String: AgentLibraryValue]]) throws -> String {
        if input.hasPrefix("mcp-id:") {
            guard let name = entries.keys.first(where: { operationToken(target: target, name: $0) == input }) else {
                throw AgentLibraryError.notFound
            }
            return name
        }
        guard entries[input] != nil else { throw AgentLibraryError.notFound }
        return input
    }
    static func definitionFingerprint(_ fields: [String: AgentLibraryValue]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AgentLibraryFiles.digest((try? encoder.encode(fields)) ?? Data())
    }
    static func status(_ error: Error) -> AgentLibraryFileStatus {
        switch error as? AgentLibraryError {
        case .unsafePath, .symlinkLoop: .unsafe
        default: .invalid
        }
    }
}
