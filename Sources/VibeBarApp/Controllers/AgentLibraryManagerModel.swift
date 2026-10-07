import Combine
import Foundation
import VibeBarCore

enum LibraryResourceKind: String, CaseIterable, Identifiable {
    case mcp, instructions
    var id: String { rawValue }
}

struct LibraryEditorDraft: Identifiable {
    enum Kind { case mcp(originalName: String?), instruction(id: String) }
    let id = UUID()
    let kind: Kind
    let title: String
    let text: String
    let target: AgentLibraryTarget?
    let revisions: [AgentLibraryTarget: String]
    let revision: String
    var definition: AgentMCPDefinition? = nil
    var logicalPath: String? = nil
    var resolvedPath: String? = nil
    var affectedTargets: [AgentLibraryTarget] = []
    var isReadOnly = false
}

@MainActor
final class AgentLibraryManagerModel: ObservableObject {
    @Published private(set) var mcp: AgentMCPInventory? {
        didSet { mcpGroups = mcp.map(AgentMCPGroup.groups) ?? [] }
    }
    /// Derived once per inventory change, never in a view body.
    @Published private(set) var mcpGroups: [AgentMCPGroup] = []
    @Published private(set) var instructions: [AgentInstructionSummary] = [] {
        didSet { instructionStates = AgentLibraryShareState.instructionStates(instructions) }
    }
    @Published private(set) var instructionStates: [AgentLibraryTarget: AgentLibraryShareState] = [:]
    @Published private(set) var isBusy = false
    /// The circle whose share is being written, as "<resource>|<target>".
    @Published private(set) var activeToggle: String?
    /// The last share toggle that failed, with its error code, until the
    /// next action on the page.
    @Published private(set) var failedToggle: (key: String, code: String)?
    @Published var message: String?
    @Published var editor: LibraryEditorDraft?
    @Published var pendingDelete: AgentMCPDefinitionSummary?
    private let serviceResult: Result<AgentLibraryService, Error>
    private var service: AgentLibraryService { get throws { try serviceResult.get() } }

    init(homeDirectory: URL) {
        serviceResult = Result { try AgentLibraryService(homeDirectory: homeDirectory) }
    }

    func refresh(_ kind: LibraryResourceKind) async {
        do {
            switch kind {
            case .mcp: mcp = try await service.mcpInventory()
            case .instructions: instructions = try await service.instructionInventory()
            }
        } catch { message = Self.message(for: error) }
    }

    func beginNewMCP() {
        message = nil
        let revisions = Dictionary(uniqueKeysWithValues: (mcp?.files ?? []).map { ($0.target, $0.revision) })
        let target = (mcp?.files ?? []).first { $0.status == .ready || $0.status == .missing }?.target ?? .codex
        editor = .init(kind: .mcp(originalName: nil), title: L10n.Workbench.Library.addMCP,
                       text: "", target: target,
                       revisions: revisions, revision: revisions[target] ?? "missing",
                       definition: AgentMCPDefinition(name: "", command: ""))
    }

    func editMCP(_ row: AgentMCPDefinitionSummary) {
        perform {
            let document = try await self.service.readMCPDefinition(target: row.target, name: row.operationName, expectedRevision: row.revision)
            self.editor = .init(kind: .mcp(originalName: document.definition.name), title: row.name,
                                text: "", target: row.target,
                                revisions: [row.target: document.revision], revision: document.revision,
                                definition: document.definition, logicalPath: row.path,
                                isReadOnly: document.definition.transport == .unknown)
            if document.definition.transport == .unknown {
                self.message = Self.message(code: row.errorCode ?? AgentLibraryError.invalidDefinition.code)
            }
        }
    }

    func editInstruction(_ row: AgentInstructionSummary) {
        message = nil
        // A missing canonical source is a creation draft, not a read error.
        if row.status == .missing {
            editor = .init(kind: .instruction(id: row.id), title: row.isCanonical ? L10n.Workbench.Library.canonical : row.path,
                           text: "", target: row.target, revisions: [:], revision: row.revision,
                           logicalPath: row.path, resolvedPath: row.resolvedPath)
            return
        }
        perform {
            let document = try await self.service.readInstruction(id: row.id, expectedRevision: row.revision)
            self.editor = .init(kind: .instruction(id: row.id), title: row.isCanonical ? L10n.Workbench.Library.canonical : row.path,
                                text: document.text, target: row.target, revisions: [:], revision: document.revision,
                                logicalPath: row.path, resolvedPath: row.resolvedPath,
                                affectedTargets: self.instructions.filter {
                                    row.resolvedPath != nil && $0.resolvedPath == row.resolvedPath
                                }.compactMap(\.target))
        }
    }

    func save(_ draft: LibraryEditorDraft, text: String, target: AgentLibraryTarget,
              definition: AgentMCPDefinition? = nil) {
        perform {
            let result: AgentLibraryMutationResult
            switch draft.kind {
            case .mcp(let originalName):
                guard let definition else { throw AgentLibraryError.invalidDefinition }
                if let originalName, definition.name != originalName { throw AgentLibraryError.invalidDefinition }
                result = try await self.service.saveMCPDefinition(target: target, definition: definition,
                    expectedRevision: draft.revisions[target] ?? draft.revision, replaceExisting: originalName != nil)
                await self.refresh(.mcp)
            case .instruction(let id):
                result = try await self.service.saveInstruction(id: id, text: text, expectedRevision: draft.revision)
                await self.refresh(.instructions)
            }
            self.report(result)
            if result.problems.isEmpty { self.editor = nil }
        }
    }

    func deleteMCP(_ row: AgentMCPDefinitionSummary) {
        perform {
            let result = try await self.service.deleteMCPDefinition(target: row.target, name: row.operationName, expectedRevision: row.revision)
            self.pendingDelete = nil
            self.report(result)
            await self.refresh(.mcp)
        }
    }

    static func toggleKey(id resource: String, _ target: AgentLibraryTarget) -> String {
        resource + "|" + target.rawValue
    }

    /// One click on an MCP harness circle. Sharing copies the group's
    /// primary definition through `shareMCPDefinition`; switching off removes
    /// only a copy Vibe Bar still owns, and asks first for anything else.
    func toggleMCP(_ group: AgentMCPGroup, target: AgentLibraryTarget) {
        guard let state = group.states[target] else { return }
        let key = Self.toggleKey(id: group.id, target)
        switch state {
        case .off:
            guard let revision = mcp?.files.first(where: { $0.target == target })?.revision else { return }
            let source = group.primary
            perform(key: key) {
                let result = try await self.service.shareMCPDefinition(source: source.target, name: source.operationName,
                    sourceRevision: source.revision, targets: [target: revision])
                await self.refresh(.mcp)
                return result
            }
        case .shared(managed: true) where target != group.primary.target:
            guard let row = group.rows[target] else { return }
            perform(key: key) {
                let result = try await self.service.withdrawMCPShare(target: row.target, name: row.operationName,
                                                                    expectedRevision: row.revision)
                await self.refresh(.mcp)
                return result
            }
        case .shared, .linked, .differs:
            // The user's own definition: removing it is an explicit delete.
            message = nil
            pendingDelete = group.rows[target]
        case .unavailable(let code):
            message = Self.message(code: code)
        }
    }

    /// One click on an instructions harness circle. Linking reuses
    /// `linkCanonicalInstructions`; only a link Vibe Bar made is removed, and
    /// a link the user made stays as it is, with the reason shown.
    func toggleInstruction(_ target: AgentLibraryTarget) {
        guard let state = instructionStates[target],
              let row = instructions.first(where: { $0.target == target }) else { return }
        let key = Self.toggleKey(id: "instructions", target)
        switch state {
        case .off, .differs:
            perform(key: key) {
                let result = try await self.service.linkCanonicalInstructions(targets: [target: row.revision])
                await self.refresh(.instructions)
                return result
            }
        case .shared(managed: true):
            perform(key: key) {
                let result = try await self.service.removeInstructionProjection(target: target, expectedRevision: row.revision)
                await self.refresh(.instructions)
                return result
            }
        case .shared(managed: false), .linked:
            failedToggle = nil
            message = Self.message(code: AgentLibraryError.notOwnedProjection.code)
        case .unavailable(let code):
            failedToggle = nil
            message = Self.message(code: code)
        }
    }


    private func report(_ result: AgentLibraryMutationResult) {
        var parts: [String] = []
        if !result.changed.isEmpty || !result.backups.isEmpty {
            let targets = result.changed.map(\.libraryDisplayName).joined(separator: ", ")
            parts.append(L10n.Workbench.Library.saveResult + (targets.isEmpty ? "" : ": " + targets))
        }
        if !result.unchanged.isEmpty {
            parts.append(L10n.Workbench.Skills.Import.conflictsCount(count: result.unchanged.count)
                         + ": " + result.unchanged.map(\.libraryDisplayName).joined(separator: ", "))
        }
        parts += result.problems.map {
            let reason = Self.message(code: $0.code)
            return $0.target.map { $0.libraryDisplayName + ": " + reason } ?? reason
        }
        message = parts.isEmpty ? L10n.Workbench.Library.saveResult : parts.joined(separator: "\n")
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        failedToggle = nil
        Task {
            defer { isBusy = false }
            do { try await operation() }
            catch { message = Self.message(for: error) }
        }
    }

    /// A share toggle: the same single-flight guard, plus which circle is
    /// working and, on failure, which one to mark.
    private func perform(key: String, _ operation: @escaping @MainActor () async throws -> AgentLibraryMutationResult) {
        guard !isBusy else { return }
        isBusy = true
        activeToggle = key
        message = nil
        failedToggle = nil
        Task {
            defer { isBusy = false; activeToggle = nil }
            do {
                let result = try await operation()
                if let problem = result.problems.first {
                    failedToggle = (key, problem.code)
                    report(result)
                } else {
                    message = nil
                }
            } catch {
                failedToggle = (key, (error as? AgentLibraryError)?.code ?? AgentLibraryError.ioFailure.code)
                message = Self.message(for: error)
            }
        }
    }

    static func message(for error: Error) -> String {
        guard let error = error as? AgentLibraryError else {
            return L10n.Workbench.Library.failed(code: AppLocale.number((error as NSError).code))
        }
        return message(code: error.code)
    }

    static func message(code: String) -> String {
        guard let error = AgentLibraryError(rawValue: code) else { return L10n.Workbench.Library.failed(code: code) }
        return switch error {
        case .invalidHome: L10n.Workbench.Library.Error.invalidHome
        case .unsafePath: L10n.Workbench.Library.Error.unsafePath
        case .symlinkLoop: L10n.Workbench.Library.Error.symlinkLoop
        case .unsupportedTarget: L10n.Workbench.Library.Error.unsupportedTarget
        case .invalidDocument: L10n.Workbench.Library.Error.invalidDocument
        case .invalidDefinition: L10n.Workbench.Library.Error.invalidDefinition
        case .unsupportedTransport: L10n.Workbench.Library.Error.unsupportedTransport
        case .unsupportedConversion: L10n.Workbench.Library.Error.unsupportedConversion
        case .staleRevision: L10n.Workbench.Library.Error.staleRevision
        case .sameNameConflict: L10n.Workbench.Library.Error.sameNameConflict
        case .notFound: L10n.Workbench.Library.Error.notFound
        case .notOwnedProjection: L10n.Workbench.Library.Error.notOwnedProjection
        case .projectionModified: L10n.Workbench.Library.Error.projectionModified
        case .backupMissing: L10n.Workbench.Library.Error.backupMissing
        case .invalidBackup: L10n.Workbench.Library.Error.invalidBackup
        case .ioFailure: L10n.Workbench.Library.Error.ioFailure
        case .oversizedFile: L10n.Workbench.Library.Error.oversizedFile
        case .missingCanonical: L10n.Workbench.Library.Error.missingCanonical
        case .unsupportedTOML: L10n.Workbench.Library.Error.unsupportedTOML
        case .ambiguousDefinition: L10n.Workbench.Library.Error.ambiguousDefinition
        case .invalidReceipt: L10n.Workbench.Library.Error.invalidReceipt
        }
    }
}

extension AgentLibraryTarget {
    var libraryDisplayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .gemini: "Gemini CLI"
        case .grok: "Grok Build"
        }
    }
}
