import SwiftUI

enum SidebarItem: Hashable {
    /// Notebooks that aren't in any folder.
    case library
    case schedules, suggestions, importer
    case folder(UUID)
}

struct NotebookRoute: Hashable { let id: UUID }

struct RootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationService.self) private var notifications
    @Environment(LinkedFolderService.self) private var linked
    @Environment(NotebookTabs.self) private var tabs
    @Environment(\.inkTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: SidebarItem? = .library
    @State private var path: [NotebookRoute] = []
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var search = ""
    @State private var showSettings = false
    @State private var toast: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(selection: $selection, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: NotebookRoute.self) { route in
                        NotebookEditorView(notebookID: route.id, switchTo: switchTo, closeTab: closeTab)
                    }
            }
            .toolbar(removing: path.isEmpty ? nil : .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: path) { _, new in
            withAnimation { columns = new.isEmpty ? .all : .detailOnly }
        }
        .overlay(alignment: .top) { toastView }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task { await startup() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runSchedules()
            calendar.refresh()
            Task { await linked.syncAll(into: store) }
        }
        .onChange(of: notifications.pendingOpenRule) { _, ruleID in
            guard let ruleID else { return }
            notifications.pendingOpenRule = nil
            runSchedules()
            if let rule = store.rules.first(where: { $0.id == ruleID }),
               let nb = store.nodes.values.filter({ !$0.isFolder && $0.name.localizedCaseInsensitiveContains(rule.title) })
                .max(by: { $0.createdAt < $1.createdAt }) {
                path = [NotebookRoute(id: nb.id)]
            }
        }
        .onChange(of: settings.iCloudEnabled) { _, _ in }
        .onOpenURL { openFile($0) }
    }

    /// "Share → Inkwell" from Goodnotes (or Files, Mail, Safari): a PDF becomes a notebook right away.
    private func openFile(_ url: URL) {
        guard url.isFileURL else { return }
        guard url.pathExtension.lowercased() == "pdf" else {
            showToast(url.pathExtension.lowercased() == "goodnotes"
                      ? "In Goodnotes, share the notebook as a PDF instead."
                      : "Inkwell opens PDF files.")
            return
        }
        if let node = store.importPDF(from: url, into: nil) {
            selection = .library
            switchTo(node.id)
            showToast("Imported “\(node.name)”")
        } else {
            showToast("Couldn't read that PDF.")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation { toast = nil }
        }
    }

    private func switchTo(_ id: UUID) {
        tabs.add(id)
        path = [NotebookRoute(id: id)]
    }

    private func closeTab(_ id: UUID) {
        guard let i = tabs.open.firstIndex(of: id) else { return }
        let wasCurrent = path.last?.id == id
        tabs.open.remove(at: i)
        guard wasCurrent else { return }
        if let next = tabs.open.indices.contains(i) ? tabs.open[i] : tabs.open.last {
            path = [NotebookRoute(id: next)]
        } else {
            path = []
        }
    }

    private func startup() async {
        ClaudeBridge.shared.store = store
        if settings.iCloudEnabled {
            let ok = await store.setICloud(true)
            if !ok { settings.iCloudEnabled = false }
        }
        runSchedules()
        await notifications.refreshStatus()
        await notifications.reschedule(rules: store.rules, enabled: settings.notificationsEnabled)
        NotificationService.scheduleRefresh(rules: store.rules)
        await linked.syncAll(into: store)
        ClaudeBridge.shared.syncAll()
    }

    private func runSchedules() {
        let n = store.runSchedules()
        if n > 0 {
            let names = store.lastCreated.map(\.name)
            showToast(n == 1 ? "Created “\(names[0])”" : "Created \(n) notebooks from your schedules")
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "sparkles")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var detail: some View {
        let open: (UUID) -> Void = { path.append(NotebookRoute(id: $0)) }
        switch selection ?? .library {
        case .library:
            FolderBrowser(scope: .folder(nil), search: $search, open: open, navigate: { selection = $0 })
                .id("library")
        case .folder(let id):
            FolderBrowser(scope: .folder(id), search: $search, open: open, navigate: { selection = $0 })
                .id(id)
        case .schedules:
            SchedulesView()
        case .suggestions:
            SuggestionsView(open: open)
        case .importer:
            LinkedFoldersView()
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var showSettings: Bool
    @Environment(LibraryStore.self) private var store
    @Environment(\.inkTheme) private var theme
    @State private var folderAlert: FolderAlert?
    @State private var folderName = ""
    @State private var customiseID: UUID?
    @State private var deleteTarget: Node?

    private enum FolderAlert: Identifiable {
        case new(parent: UUID?), rename(UUID)
        var id: String {
            switch self {
            case .new(let p): return "new-\(p?.uuidString ?? "root")"
            case .rename(let i): return "rename-\(i)"
            }
        }
    }

    private func count(_ parent: UUID?) -> Int { store.children(of: parent).count }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("No Folder", systemImage: "tray")
                    .font(.callout)
                    .badge(store.children(of: nil).filter { !$0.isFolder }.count)
                    .tag(SidebarItem.library)
                    .dropDestination(for: NodeRef.self) { items, _ in
                        items.map { store.move($0.id, to: nil) }.contains(true)
                    }
            }
            Section {
                OutlineGroup(store.folderTree(), children: \.children) { tree in
                    Label {
                        Text(tree.node.name)
                    } icon: {
                        Image(systemName: tree.node.cover?.symbol ?? "folder.fill").foregroundStyle(tree.node.displayColor)
                    }
                    .font(.callout)
                    .badge(count(tree.id))
                    .tag(SidebarItem.folder(tree.id))
                    .dropDestination(for: NodeRef.self) { items, _ in
                        items.map { store.move($0.id, to: tree.id) }.contains(true)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { folderName = tree.node.name; folderAlert = .rename(tree.id) }
                        Button("New Subfolder", systemImage: "folder.badge.plus") { folderName = ""; folderAlert = .new(parent: tree.id) }
                        Button("Customise…", systemImage: "paintbrush.pointed") { customiseID = tree.id }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = tree.node }
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { folderName = ""; folderAlert = .new(parent: nil) } label: {
                        Image(systemName: "folder.badge.plus").font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("New folder")
                }
            }
            Section("Automate") {
                row("Import", "square.and.arrow.down.fill", .importer)
                row("Schedules", "calendar.badge.clock", .schedules)
                row("Suggested", "sparkles", .suggestions)
            }
        }
        .alert(folderAlertTitle, isPresented: Binding(get: { folderAlert != nil }, set: { if !$0 { folderAlert = nil } })) {
            TextField("Folder name", text: $folderName)
            Button(folderAlertButton) { commitFolderAlert() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget {
                    store.delete(t.id)
                    if case .folder(let sel)? = selection, store.node(sel) == nil { selection = .library }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Everything inside it will be deleted too.") }
        .sheet(item: Binding(get: { customiseID.map { IDBox(id: $0) } }, set: { customiseID = $0?.id })) { box in
            CustomiseSheet(nodeID: box.id)
        }
        .environment(\.defaultMinListRowHeight, 34)
        .listStyle(.sidebar)
        .navigationTitle("Inkwell")
        .scrollContentBackground(.hidden)
        .background(theme.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(theme.sidebar)
        }
    }

    private var folderAlertTitle: String {
        switch folderAlert {
        case .rename: return "Rename folder"
        case .new(let p): return p == nil ? "New folder" : "New subfolder"
        case nil: return ""
        }
    }

    private var folderAlertButton: String {
        if case .rename = folderAlert { return "Save" }
        return "Create"
    }

    private func commitFolderAlert() {
        switch folderAlert {
        case .rename(let id):
            store.rename(id, to: folderName)
        case .new(let parent):
            let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let f = store.createFolder(name: name.isEmpty ? "New Folder" : name, in: parent)
            selection = .folder(f.id)
        case nil:
            break
        }
    }

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem) -> some View {
        Label(title, systemImage: symbol).font(.callout).tag(item)
    }
}
