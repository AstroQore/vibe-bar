import Combine
import Foundation
import VibeBarCore

enum LibraryResourceKind: String, CaseIterable, Identifiable {
    case skills, mcp, instructions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skills: L10n.Workbench.Page.Skills.title
        case .mcp: L10n.Workbench.Library.mcp
        case .instructions: L10n.Workbench.Library.instructions
        }
    }
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

struct LibraryShareDraft: Identifiable {
    enum Kind { case mcp(AgentMCPDefinitionSummary), instructions }
    let id = UUID()
    let kind: Kind
    let revisions: [AgentLibraryTarget: String]
}

@MainActor
final class AgentLibraryManagerModel: ObservableObject {
    @Published private(set) var mcp: AgentMCPInventory?
    @Published private(set) var instructions: [AgentInstructionSummary] = []
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var editor: LibraryEditorDraft?
    @Published var shareDraft: LibraryShareDraft?
    @Published var pendingDelete: AgentMCPDefinitionSummary?
    @Published var pendingRemoveProjection: AgentInstructionSummary?
    private let serviceResult: Result<AgentLibraryService, Error>
    private var service: AgentLibraryService { get throws { try serviceResult.get() } }

    init(homeDirectory: URL) {
        serviceResult = Result { try AgentLibraryService(homeDirectory: homeDirectory) }
    }

    func refresh(_ kind: LibraryResourceKind) async {
        do {
            switch kind {
            case .skills: break
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

    func share(_ draft: LibraryShareDraft, targets: Set<AgentLibraryTarget>) {
        perform {
            let result: AgentLibraryMutationResult
            switch draft.kind {
            case .mcp(let row):
                let revisions = draft.revisions.filter { targets.contains($0.key) }
                result = try await self.service.shareMCPDefinition(source: row.target, name: row.operationName,
                    sourceRevision: row.revision, targets: revisions)
                await self.refresh(.mcp)
            case .instructions:
                let revisions = draft.revisions.filter { targets.contains($0.key) }
                result = try await self.service.linkCanonicalInstructions(targets: revisions)
                await self.refresh(.instructions)
            }
            self.report(result)
            if result.problems.isEmpty { self.shareDraft = nil }
        }
    }

    func beginShareMCP(_ row: AgentMCPDefinitionSummary) {
        message = nil
        shareDraft = .init(kind: .mcp(row), revisions: Dictionary(uniqueKeysWithValues:
            (mcp?.files ?? []).filter { $0.target != row.target && ($0.status == .ready || $0.status == .missing) }
                .map { ($0.target, $0.revision) }))
    }

    func beginLinkInstructions() {
        message = nil
        shareDraft = .init(kind: .instructions, revisions: Dictionary(uniqueKeysWithValues:
            instructions.compactMap { row -> (AgentLibraryTarget, String)? in
                guard let target = row.target, row.status == .ready || row.status == .missing else { return nil }
                return (target, row.revision)
            }))
    }

    func removeProjection(_ row: AgentInstructionSummary) {
        guard let target = row.target else { return }
        perform {
            let result = try await self.service.removeInstructionProjection(target: target, expectedRevision: row.revision)
            self.pendingRemoveProjection = nil
            self.report(result)
            await self.refresh(.instructions)
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
        Task {
            defer { isBusy = false }
            do { try await operation() }
            catch { message = Self.message(for: error) }
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
