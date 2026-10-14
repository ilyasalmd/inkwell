import SwiftUI

enum SidebarItem: Hashable {
    case library, favorites, recents, schedules, suggestions, importer
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
        if settings.iCloudEnabled {
            let ok = await store.setICloud(true)
            if !ok { settings.iCloudEnabled = false }
        }
        runSchedules()
        await notifications.refreshStatus()
        await notifications.reschedule(rules: store.rules, enabled: settings.notificationsEnabled)
        NotificationService.scheduleRefresh(rules: store.rules)
        await linked.syncAll(into: store)
    }

    private func runSchedules() {
        let n = store.runSchedules()
        if n > 0 {
            let names = store.lastCreated.map(\.name)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                toast = n == 1 ? "Created “\(names[0])”" : "Created \(n) notebooks from your schedules"
            }
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation { toast = nil }
            }
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
        case .favorites:
            FolderBrowser(scope: .favorites, search: $search, open: open, navigate: { selection = $0 })
                .id("favorites")
        case .recents:
            FolderBrowser(scope: .recents, search: $search, open: open, navigate: { selection = $0 })
                .id("recents")
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

    var body: some View {
        List(selection: $selection) {
            Section {
                row("All Notes", "tray.full.fill", .library)
                    .dropDestination(for: NodeRef.self) { items, _ in
                        items.map { store.move($0.id, to: nil) }.contains(true)
                    }
                row("Favorites", "star.fill", .favorites)
                row("Recents", "clock.fill", .recents)
            }
            Section("Folders") {
                OutlineGroup(store.folderTree(), children: \.children) { tree in
                    Label {
                        Text(tree.node.name)
                    } icon: {
                        Image(systemName: tree.node.cover?.symbol ?? "folder.fill").foregroundStyle(tree.node.displayColor)
                    }
                    .font(.callout)
                    .tag(SidebarItem.folder(tree.id))
                    .dropDestination(for: NodeRef.self) { items, _ in
                        items.map { store.move($0.id, to: tree.id) }.contains(true)
                    }
                }
            }
            Section("Automate") {
                row("Import", "square.and.arrow.down.fill", .importer)
                row("Schedules", "calendar.badge.clock", .schedules)
                row("Suggested", "sparkles", .suggestions)
            }
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

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem) -> some View {
        Label(title, systemImage: symbol).font(.callout).tag(item)
    }
}
