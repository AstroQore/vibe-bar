import SwiftUI
import VibeBarCore

/// A fresh selection draft for one explicit slide. The sheet owns its state,
/// so presenting it cannot capture a stale parent view's empty selection.
struct EInkContentPicker: View {
    struct Choice: Identifiable { let id: String; let title: String }
    struct Section: Identifiable { let id: String; let title: String; let choices: [Choice] }
    struct Request: Identifiable {
        let id = UUID()
        let slideID: String
        let initial: [String]
        let sections: [Section]
    }

    let request: Request
    let onSave: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selection: Set<String>
    @State private var query = ""

    init(request: Request, onSave: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.request = request; self.onSave = onSave; self.onCancel = onCancel
        _selection = State(initialValue: Set(request.initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.Settings.Eink.Workflow.chooseContent).font(.headline)
                Spacer()
                Button(L10n.Common.cancel, action: onCancel)
                Button(L10n.Common.done) {
                    let kept = request.initial.filter(selection.contains)
                    let added = request.sections.flatMap(\.choices).map(\.id).filter { selection.contains($0) && !kept.contains($0) }
                    onSave(kept + added)
                }.disabled(selection.isEmpty)
            }
            TextField(L10n.Settings.Eink.Workflow.searchContent, text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(request.sections) { section in
                        let choices = section.choices.filter {
                            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                                || section.title.localizedCaseInsensitiveContains(query)
                        }
                        if !choices.isEmpty {
                            Text(section.title).font(.subheadline.weight(.semibold)).padding(.top, 4)
                            ForEach(choices) { choice in
                                Toggle(choice.title, isOn: Binding(get: { selection.contains(choice.id) }, set: { value in
                                    if value { selection.insert(choice.id) } else { selection.remove(choice.id) }
                                })).toggleStyle(.checkbox)
                            }
                        }
                    }
                }.padding(8)
            }
            Text(L10n.Settings.Eink.Workflow.automaticPages).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 520, height: 560)
    }
}
