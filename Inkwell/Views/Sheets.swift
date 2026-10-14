import SwiftUI

struct NewNotebookSheet: View {
    let parent: UUID?
    var onCreate: (UUID) -> Void
    var eventID: String?
    var suggestedName: String = "Untitled Notebook"

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: PageTemplate = .lined
    @State private var paper: PaperColor = .cream
    @State private var design = CoverDesign.random()
    @State private var mode: NotebookMode = .pages

    init(parent: UUID?, eventID: String? = nil, suggestedName: String = "Untitled Notebook",
         onCreate: @escaping (UUID) -> Void) {
        self.parent = parent
        self.eventID = eventID
        self.suggestedName = suggestedName
        self.onCreate = onCreate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(suggestedName, text: $name)
                }
                Section {
                    Picker("Type", selection: $mode) {
                        Text("Pages").tag(NotebookMode.pages)
                        Text("Whiteboard").tag(NotebookMode.whiteboard)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Type")
                } footer: {
                    Text(mode == .pages
                         ? "Separate pages you can add, reorder and export. Best for lectures and imported PDFs."
                         : "One huge canvas you pan and zoom around. Exporting crops to what you drew.")
                }
                Section(mode == .pages ? "Page template" : "Background") {
                    TemplatePicker(template: $template, paper: $paper,
                                   templates: mode == .pages ? PageTemplate.allCases : PageTemplate.allCases.filter(\.suitsWhiteboard))
                        .padding(.vertical, 6)
                }
                Section("Cover") {
                    CoverDesignerView(design: $design, title: name.isEmpty ? suggestedName : name)
                        .padding(.vertical, 6)
                }
            }
            .onChange(of: mode) { _, new in
                if new == .whiteboard && !template.suitsWhiteboard { template = .dotted }
            }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let n = store.createNotebook(name: name.isEmpty ? suggestedName : name, in: parent,
                                                     template: template, paper: paper, tint: .ink, eventID: eventID, cover: design, mode: mode)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCreate(n.id) }
                    }
                }
            }
        }
        .presentationSizing(.page)
    }
}

/// Pick a destination folder (nil = top level).
struct FolderPickerSheet: View {
    let title: String
    var excluding: UUID?
    var initial: UUID?
    var onPick: (UUID?) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var choice: UUID?

    var body: some View {
        NavigationStack {
            List {
                row(title: "All Notes", symbol: "tray.full.fill", tint: .secondary, depth: 0, id: nil)
                ForEach(store.flatFolders(excluding: excluding), id: \.node.id) { item in
                    row(title: item.node.name, symbol: "folder.fill", tint: item.node.tint.color, depth: item.depth + 1, id: item.node.id)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") { onPick(choice); dismiss() }
                }
            }
            .onAppear { choice = initial }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(title: String, symbol: String, tint: Color, depth: Int, id: UUID?) -> some View {
        Button { choice = id } label: {
            HStack {
                Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                    .padding(.leading, CGFloat(depth) * 18)
                Spacer()
                if choice == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .buttonStyle(.plain)
    }
}
