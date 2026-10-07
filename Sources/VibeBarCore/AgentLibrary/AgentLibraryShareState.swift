import Foundation

/// What one harness switch says about a Library resource, derived from
/// inventory alone so the views never compute it in a body. Holds codes,
/// never localized text.
public enum AgentLibraryShareState: Equatable, Sendable {
    /// Present and equal (MCP) or reading the shared file (instructions).
    /// `managed` means Vibe Bar's own receipt still covers it.
    case shared(managed: Bool)
    /// Reading the shared instructions through a link Vibe Bar did not make.
    case linked
    /// Present under the same name with different content, or linked to a
    /// different source.
    case differs
    case off
    case unavailable(code: String)

    public var isOn: Bool {
        switch self {
        case .shared, .linked, .differs: true
        case .off, .unavailable: false
        }
    }
}

/// One MCP server name across every harness that defines it.
public struct AgentMCPGroup: Identifiable, Sendable {
    public let id: String
    public let rows: [AgentLibraryTarget: AgentMCPDefinitionSummary]
    /// The definition a new share copies: the receipt's source while a
    /// managed copy exists, otherwise the first readable row.
    public let primary: AgentMCPDefinitionSummary
    public let states: [AgentLibraryTarget: AgentLibraryShareState]

    public var name: String { primary.name }

    public static func groups(_ inventory: AgentMCPInventory) -> [AgentMCPGroup] {
        let files = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.target, $0) })
        var order: [String] = []
        var grouped: [String: [AgentLibraryTarget: AgentMCPDefinitionSummary]] = [:]
        for row in inventory.definitions {
            if grouped[row.groupID] == nil { order.append(row.groupID) }
            grouped[row.groupID, default: [:]][row.target] = row
        }
        return order.compactMap { id -> AgentMCPGroup? in
            guard let rows = grouped[id] else { return nil }
            let ordered = AgentLibraryTarget.allCases.compactMap { rows[$0] }
            let source = ordered.first { $0.projectionOwned }?.sharedSourceTarget.flatMap { rows[$0] }
            guard let primary = source ?? ordered.first(where: { $0.status == .ready }) ?? ordered.first else { return nil }
            var states: [AgentLibraryTarget: AgentLibraryShareState] = [:]
            for target in AgentLibraryTarget.allCases {
                if let row = rows[target] {
                    if target == primary.target || primary.matchingTargets.contains(target) {
                        states[target] = .shared(managed: row.projectionOwned)
                    } else {
                        states[target] = .differs
                    }
                } else if let file = files[target], file.status != .ready && file.status != .missing {
                    states[target] = .unavailable(code: file.errorCode ?? AgentLibraryError.ioFailure.code)
                } else if primary.status != .ready {
                    states[target] = .unavailable(code: primary.errorCode ?? AgentLibraryError.invalidDefinition.code)
                } else if let code = primary.unsupportedTargets[target] {
                    states[target] = .unavailable(code: code)
                } else {
                    states[target] = .off
                }
            }
            return AgentMCPGroup(id: id, rows: rows, primary: primary, states: states)
        }
    }
}

extension AgentLibraryShareState {
    /// Per agent, from one instruction inventory. Agents without a
    /// supported instruction file get no entry, so they draw no circle.
    public static func instructionStates(_ rows: [AgentInstructionSummary]) -> [AgentLibraryTarget: AgentLibraryShareState] {
        let canonical = rows.first { $0.isCanonical }
        var states: [AgentLibraryTarget: AgentLibraryShareState] = [:]
        for row in rows {
            guard let target = row.target, row.status != .unsupported else { continue }
            if row.sharesCanonical {
                states[target] = row.projectionOwned ? .shared(managed: true) : .linked
            } else if row.status != .ready && row.status != .missing {
                states[target] = .unavailable(code: row.errorCode ?? AgentLibraryError.ioFailure.code)
            } else if canonical?.status != .ready {
                states[target] = .unavailable(code: canonical?.status == .missing
                    ? AgentLibraryError.missingCanonical.code
                    : canonical?.errorCode ?? AgentLibraryError.missingCanonical.code)
            } else if row.isSymlink {
                states[target] = .differs
            } else if row.status == .ready, row.contentDigest != canonical?.contentDigest {
                // A regular file whose text is not the canonical text: linking
                // would be refused as a same-name conflict, so the circle must
                // not look like an empty target.
                states[target] = .differs
            } else {
                states[target] = .off
            }
        }
        return states
    }
}
