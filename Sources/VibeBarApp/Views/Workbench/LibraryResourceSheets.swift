import SwiftUI
import VibeBarCore

struct LibraryResourceEditor: View {
    let draft: LibraryEditorDraft
    @ObservedObject var model: AgentLibraryManagerModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var target: AgentLibraryTarget
    @State private var definition: AgentMCPDefinition
    @State private var arguments: String
    @State private var environment: String
    @State private var headers: String
    @State private var validationMessage: String?

    init(draft: LibraryEditorDraft, model: AgentLibraryManagerModel) {
        self.draft = draft; self.model = model
        _text = State(initialValue: draft.text)
        _target = State(initialValue: draft.target ?? .codex)
        let definition = draft.definition ?? AgentMCPDefinition(name: "")
        _definition = State(initialValue: definition)
        _arguments = State(initialValue: Self.json(definition.args, fallback: "[]"))
        _environment = State(initialValue: Self.json(definition.environment, fallback: "{}"))
        _headers = State(initialValue: Self.json(definition.headers, fallback: "{}"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.title).font(.headline)
            if let logical = draft.logicalPath {
                LibrarySourcePath(title: L10n.Workbench.Skills.Wiring.source, path: logical)
            }
            if let resolved = draft.resolvedPath {
                LibrarySourcePath(title: L10n.Workbench.Library.linkedSource, path: resolved)
            }
            if !draft.affectedTargets.isEmpty {
                Text(L10n.Workbench.Library.availableTo(agents: draft.affectedTargets.map(\.libraryDisplayName).joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .mcp(let originalName) = draft.kind {
                Picker(L10n.Workbench.Library.target, selection: $target) {
                    ForEach(AgentLibraryTarget.allCases) { target in
                        Text(target.libraryDisplayName).tag(target)
                    }
                }.disabled(originalName != nil)
                mcpForm(originalName: originalName).disabled(draft.isReadOnly)
            } else {
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                    .frame(minHeight: 340).workbenchFieldSurface(cornerRadius: 8)
            }
            LibraryMessage(message: validationMessage)
            LibraryMessage(message: model.message)
            HStack {
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }.disabled(model.isBusy)
                Button(L10n.Common.save, action: save)
                    .buttonStyle(WorkbenchPillButtonStyle(prominent: true)).disabled(model.isBusy || draft.isReadOnly)
            }
        }.padding(20).frame(minWidth: 720, minHeight: 520)
            .vibeBarNoInitialFocus().vibeBarSystemControlFocus()
    }

    private func mcpForm(originalName: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L10n.Common.name, text: $definition.name).disabled(originalName != nil)
            Picker(L10n.Workbench.Library.transport, selection: $definition.transport) {
                if definition.transport == .unknown {
                    Text(L10n.Workbench.Library.Error.invalidDefinition).tag(AgentMCPTransport.unknown)
                }
                ForEach([AgentMCPTransport.stdio, .http, .sse], id: \.rawValue) { transport in
                    Text(transport.rawValue).tag(transport)
                }
            }
            if definition.transport == .stdio {
                TextField(L10n.Workbench.Library.command, text: Binding(get: { definition.command ?? "" }, set: { definition.command = $0 }))
                jsonField(L10n.Workbench.Library.arguments, text: $arguments)
                jsonField(L10n.Workbench.Library.environment, text: $environment)
            } else {
                TextField(L10n.Workbench.Library.url, text: Binding(get: { definition.url ?? "" }, set: { definition.url = $0 }))
                jsonField(L10n.Workbench.Library.headers, text: $headers)
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func jsonField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(.caption, design: .monospaced))
                .frame(height: 85).workbenchFieldSurface(cornerRadius: 8)
        }
    }

    private func save() {
        validationMessage = nil
        if case .mcp = draft.kind {
            var submitted = definition
            if definition.transport == .stdio {
                guard let args = Self.decode([String].self, text: arguments) else { invalid(L10n.Workbench.Library.arguments); return }
                guard let env = Self.decode([String: String].self, text: environment) else { invalid(L10n.Workbench.Library.environment); return }
                submitted.args = args; submitted.environment = env
                submitted.url = nil; submitted.headers = [:]
            } else {
                guard let values = Self.decode([String: String].self, text: headers) else { invalid(L10n.Workbench.Library.headers); return }
                submitted.headers = values; submitted.command = nil; submitted.args = []; submitted.environment = [:]
            }
            // rawFields and sourceTarget come unchanged from the explicit
            // read; neither appears in the form the user edits.
            model.save(draft, text: "", target: target, definition: submitted)
        } else { model.save(draft, text: text, target: target) }
    }

    private func invalid(_ field: String) {
        validationMessage = field + ": " + L10n.Workbench.Library.Error.invalidDefinition
    }

    private static func json<T: Encodable>(_ value: T, fallback: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? fallback
    }

    private static func decode<T: Decodable>(_ type: T.Type, text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}
