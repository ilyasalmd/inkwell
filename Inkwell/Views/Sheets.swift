import SwiftUI

struct NewNotebookSheet: View {
    let parent: UUID?
    var onCreate: (UUID) -> Void
    var eventID: String?
    var suggestedName: String = "Untitled Notebook"

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var template: PageTemplate = .lined
    @State private var paper: PaperColor = .cream
    @State private var design = CoverDesign.random()
    @State private var mode: NotebookMode = .pages
    @State private var destination: UUID?
    @State private var moreCover = false

    init(parent: UUID?, eventID: String? = nil, suggestedName: String = "Untitled Notebook",
         onCreate: @escaping (UUID) -> Void) {
        self.parent = parent
        self.eventID = eventID
        self.suggestedName = suggestedName
        self.onCreate = onCreate
        _destination = State(initialValue: parent)
    }

    private var shownName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? suggestedName : name }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    CoverArtwork(design: design, title: shownName, width: 170)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                        .padding(.top, 8)
                        .animation(.snappy, value: design)

                    VStack(spacing: 6) {
                        TextField(suggestedName, text: $name)
                            .font(.system(size: 26, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(create)
                        Text("The name goes on the cover.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 420)

                    swatches
                    typeAndPages
                    folderRow

                    DisclosureGroup(isExpanded: $moreCover) {
                        CoverDesignerView(design: $design, title: shownName, showPreview: false)
                            .padding(.top, 12)
                    } label: {
                        Label("More cover options", systemImage: "paintbrush.pointed").font(.headline)
                    }
                    .frame(maxWidth: 560)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .onChange(of: mode) { _, new in
                if new == .whiteboard && !template.suitsWhiteboard { template = .dotted }
            }
            .onAppear { matchFolder() }
            .onChange(of: destination) { matchFolder() }
            .navigationTitle("New Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create", action: create).fontWeight(.semibold) }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                nameFocused = true
            }
        }
        .presentationSizing(.page)
    }

    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) { design = CoverDesign.random() }
                } label: {
                    Image(systemName: "dice.fill").font(.callout)
                        .frame(width: 38, height: 38)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("Surprise me")
                ForEach(Array(CoverDesign.presets.enumerated()), id: \.offset) { _, p in
                    Button {
                        withAnimation(.snappy) { design.primary = p.primary; design.secondary = p.secondary }
                    } label: {
                        Circle().fill(Color(hex: p.primary))
                            .frame(width: 38, height: 38)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: design.primary == p.primary ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.name)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
        .frame(maxWidth: 560)
    }

    private var typeAndPages: some View {
        VStack(spacing: 14) {
            Picker("Type", selection: $mode) {
                Text("Pages").tag(NotebookMode.pages)
                Text("Whiteboard").tag(NotebookMode.whiteboard)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(mode == .pages ? PageTemplate.allCases : PageTemplate.allCases.filter(\.suitsWhiteboard)) { t in
                        Button { template = t } label: {
                            VStack(spacing: 5) {
                                TemplateThumbnail(template: t, paper: paper, width: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: template == t ? 3 : 0))
                                Text(t.title).font(.caption2)
                                    .foregroundStyle(template == t ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
            HStack(spacing: 12) {
                ForEach(PaperColor.allCases) { p in
                    Button { paper = p } label: {
                        Circle().fill(p.color).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: paper == p ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.title)
                }
            }
        }
        .frame(maxWidth: 560)
    }

    private var folderRow: some View {
        HStack {
            Label("Folder", systemImage: "folder").foregroundStyle(.secondary)
            Spacer()
            Picker("Folder", selection: $destination) {
                Text("Library").tag(UUID?.none)
                ForEach(store.flatFolders(), id: \.node.id) { item in
                    Text(String(repeating: "   ", count: item.depth) + item.node.name).tag(UUID?.some(item.node.id))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 420)
    }

    /// In a folder that already has notebooks, a new one starts out like the first notebook made there (cover,
    /// pages and type). Everything can still be changed here or later.
    private func matchFolder() {
        guard let first = store.styleNotebook(in: destination) else { return }
        mode = first.isWhiteboard ? .whiteboard : .pages
        if let page = first.pages.first {
            template = page.template
            paper = page.paper
        }
        design = first.coverDesign
    }

    private func create() {
        let n = store.createNotebook(name: shownName, in: destination, template: template, paper: paper,
                                     tint: .ink, eventID: eventID, cover: design, mode: mode)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCreate(n.id) }
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
                row(title: "Library", symbol: "books.vertical", tint: .secondary, depth: 0, id: nil)
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
