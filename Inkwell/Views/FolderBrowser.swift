import SwiftUI

enum BrowserScope: Hashable {
    case folder(UUID?)
}

// MARK: - Icons

struct NodeIcon: View {
    let node: Node
    var size: CGFloat = 96

    var body: some View {
        if node.isFolder {
            FolderGlyph(color: node.displayColor, symbol: node.cover?.symbol, size: size)
                .frame(width: size, height: size * 1.3)
        } else {
            CoverArtwork(design: node.coverDesign, title: node.name, width: size * 0.9)
                .shadow(color: .black.opacity(0.28), radius: 6, y: 4)
                .frame(width: size, height: size * 1.3)
        }
    }
}

// MARK: - Browser

struct FolderBrowser: View {
    let scope: BrowserScope
    @Binding var search: String
    var open: (UUID) -> Void
    var navigate: (SidebarItem) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.inkTheme) private var theme
    @AppStorage("viewMode") private var viewMode: ViewMode = .icons
    @AppStorage("sortOption") private var sort: SortOption = .name
    @State private var selected: UUID?
    @State private var renameTarget: Node?
    @State private var renameText = ""
    @State private var showNewNotebook = false
    @State private var moveTarget: Node?
    @State private var deleteTarget: Node?
    @State private var customiseTarget: UUID?
    @State private var showImporter = false
    @State private var importNote: String?

    private var folderID: UUID? {
        if case .folder(let id) = scope { return id }
        return nil
    }

    private var title: String {
        folderID == nil ? "No Folder" : (store.node(folderID)?.name ?? "No Folder")
    }

    private var items: [Node] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return LibraryStore.sorted(store.nodes.values.filter { $0.name.localizedCaseInsensitiveContains(q) }, by: sort)
        }
        // The top level is "No Folder": only loose notebooks. Folders live in the sidebar.
        let base = store.children(of: folderID).filter { folderID != nil || !$0.isFolder }
        return LibraryStore.sorted(base, by: sort)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? (folderID == nil ? "No loose notebooks" : "This folder is empty") : "No results",
                          systemImage: search.isEmpty ? "tray" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty
                         ? (folderID == nil ? "Notebooks that aren't in a folder show up here. Tap + to make one." : "Tap + to add a notebook.")
                         : "Try a different name.")
                }
            } else if viewMode == .icons {
                iconGrid
            } else {
                listView
            }
        }
        .background(theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search notes")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if folderID != nil, store.path(to: folderID).count > 1 { PathBar(folderID: folderID, navigate: navigate) } }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(parent: folderID) { open($0) }
        }
        .sheet(item: Binding(get: { customiseTarget.map { IDBox(id: $0) } }, set: { customiseTarget = $0?.id })) { box in
            CustomiseSheet(nodeID: box.id)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var made = 0
            for url in urls where store.importPDF(from: url, into: folderID) != nil { made += 1 }
            importNote = made == urls.count ? "Imported \(made) notebook\(made == 1 ? "" : "s")." : "Imported \(made) of \(urls.count). Some files couldn't be read."
        }
        .alert(importNote ?? "", isPresented: Binding(get: { importNote != nil }, set: { if !$0 { importNote = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $moveTarget) { node in
            FolderPickerSheet(title: "Move “\(node.name)”", excluding: node.id, initial: node.parentID) { dest in
                store.move(node.id, to: dest)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let t = renameTarget { store.rename(t.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) { if let t = deleteTarget { store.delete(t.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteTarget?.isFolder == true ? "Everything inside it will be deleted too." : "This can’t be undone.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let id = folderID, let parent = store.node(id)?.parentID {
                Button { navigate(.folder(parent)) } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Enclosing folder")
            }
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(ViewMode.icons)
                Image(systemName: "list.bullet").tag(ViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 100)
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(SortOption.allCases) { Text($0.title).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            Menu {
                Button("New Notebook", systemImage: "book.closed") { showNewNotebook = true }
                Button("Import PDFs…", systemImage: "square.and.arrow.down") { showImporter = true }
                Divider()
                Button("New Folder", systemImage: "folder.badge.plus") {
                    let f = store.createFolder(name: "New Folder", in: folderID)
                    selected = f.id
                    renameText = f.name
                    renameTarget = f
                }
            } label: { Image(systemName: "plus") }
        }
    }

    // MARK: Icon grid

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 40, weight: .bold, design: .serif))
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 8)
    }

    private var subtitle: String {
        let notebooks = items.filter { !$0.isFolder }.count
        let folders = items.filter(\.isFolder).count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if notebooks > 0 { parts.append("\(notebooks) notebook\(notebooks == 1 ? "" : "s")") }
        return parts.isEmpty ? Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)) : parts.joined(separator: " · ")
    }

    private var iconGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 20) {
                    ForEach(items) { node in
                        VStack(spacing: 8) {
                            NodeIcon(node: node, size: 104)
                            Text(node.name)
                                .font(.callout.weight(.medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(selected == node.id ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(selected == node.id ? Color.white : Color.primary)
                        }
                        .padding(8)
                        .background(selected == node.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                        .hoverEffect(.highlight)
                        .modifier(NodeInteractions(node: node, selected: $selected, open: openNode))
                        .nodeMenu(node, rename: beginRename, move: { moveTarget = $0 }, delete: { deleteTarget = $0 }, open: openNode, customise: { customiseTarget = $0.id })
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .animation(.spring(response: 0.45, dampingFraction: 0.78), value: items.map(\.id))
            }
            .padding(.vertical, 12)
        }
        .onTapGesture { selected = nil }
    }

    // MARK: List

    private var listView: some View {
        List {
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Date Modified").frame(width: 170, alignment: .leading)
                Text("Kind").frame(width: 90, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)

            ForEach(items) { node in
                HStack {
                    HStack(spacing: 10) {
                        NodeIcon(node: node, size: 28).frame(width: 34, height: 38)
                        Text(node.name).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(node.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .frame(width: 170, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(node.isFolder ? "\(store.itemCount(in: node.id)) items" : "Notebook")
                        .frame(width: 90, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .contentShape(Rectangle())
                .listRowBackground(selected == node.id ? Color.accentColor.opacity(0.15) : Color.clear)
                .modifier(NodeInteractions(node: node, selected: $selected, open: openNode))
                .nodeMenu(node, rename: beginRename, move: { moveTarget = $0 }, delete: { deleteTarget = $0 }, open: openNode, customise: { customiseTarget = $0.id })
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: Actions

    private func openNode(_ node: Node) {
        if node.isFolder { navigate(.folder(node.id)) } else { open(node.id) }
    }

    private func beginRename(_ node: Node) {
        renameText = node.name
        renameTarget = node
    }
}

// MARK: - Shared item behaviour

struct IDBox: Identifiable { let id: UUID }

struct NodeInteractions: ViewModifier {
    let node: Node
    @Binding var selected: UUID?
    let open: (Node) -> Void
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        content
            .onTapGesture { open(node) }
            .draggable(NodeRef(id: node.id)) {
                NodeIcon(node: node, size: 56).opacity(0.9)
            }
            .modifier(FolderDrop(node: node))
    }
}

private struct FolderDrop: ViewModifier {
    let node: Node
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        if node.isFolder {
            content.dropDestination(for: NodeRef.self) { items, _ in
                items.map { store.move($0.id, to: node.id) }.contains(true)
            }
        } else {
            content
        }
    }
}

extension View {
    func nodeMenu(_ node: Node, rename: @escaping (Node) -> Void, move: @escaping (Node) -> Void,
                  delete: @escaping (Node) -> Void, open: @escaping (Node) -> Void,
                  customise: @escaping (Node) -> Void) -> some View {
        modifier(NodeMenu(node: node, rename: rename, move: move, delete: delete, open: open, customise: customise))
    }
}

struct NodeMenu: ViewModifier {
    let node: Node
    let rename: (Node) -> Void
    let move: (Node) -> Void
    let delete: (Node) -> Void
    let open: (Node) -> Void
    let customise: (Node) -> Void
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square") { open(node) }
            Button("Rename", systemImage: "pencil") { rename(node) }
            Menu("Colour", systemImage: "paintpalette") {
                ForEach(CoverDesign.presets, id: \.name) { preset in
                    Button { recolour(preset.primary, preset.secondary) } label: {
                        Label { Text(preset.name) } icon: { Image(uiImage: Self.swatch(preset.primary)) }
                    }
                }
                Divider()
                Button("Custom colour…", systemImage: "eyedropper") { customise(node) }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(node.id) }
            Button("Move to…", systemImage: "folder") { move(node) }
            Button(node.isFolder ? "Customise…" : "Design cover…", systemImage: "paintbrush.pointed") { customise(node) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete(node) }
        }
    }

    private func recolour(_ primary: UInt32, _ secondary: UInt32) {
        var design = node.coverDesign
        design.primary = primary
        design.secondary = secondary
        store.setCover(node.id, design)
    }

    /// A coloured dot that keeps its colour inside a menu.
    private static func swatch(_ hex: UInt32) -> UIImage {
        let size = CGSize(width: 20, height: 20)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(hex: hex).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Path bar (Finder-style)

struct PathBar: View {
    let folderID: UUID?
    var navigate: (SidebarItem) -> Void
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let crumbs = store.path(to: folderID)
        HStack(spacing: 6) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, n in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                crumb(title: n.name, symbol: "folder.fill", tint: n.tint.color, dest: n.id)
            }
            Spacer()
            Text("\(store.children(of: folderID).count) items")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private func crumb(title: String, symbol: String, tint: Color, dest: UUID?) -> some View {
        Button {
            navigate(dest.map { .folder($0) } ?? .library)
        } label: {
            Label { Text(title).lineLimit(1) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.footnote)
        }
        .buttonStyle(.plain)
        .dropDestination(for: NodeRef.self) { items, _ in
            items.map { store.move($0.id, to: dest) }.contains(true)
        }
    }
}
