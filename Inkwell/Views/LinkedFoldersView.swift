import SwiftUI

/// Bring notes in from Goodnotes (or anything that exports PDFs) and keep them in step.
struct LinkedFoldersView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LinkedFolderService.self) private var linked
    @Environment(\.inkTheme) private var theme
    @State private var showFolderPicker = false
    @State private var showPDFPicker = false
    @State private var pickDestination: LinkedFolder?
    @State private var note: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Bring your Goodnotes notebooks over", systemImage: "square.and.arrow.down.on.square")
                        .font(.headline)
                    Text("Quickest: in Goodnotes, open a notebook, tap Share, choose PDF, then pick Inkwell. It lands as a notebook in No Folder. For everything at once, turn on Auto-backup in Goodnotes (PDF, to iCloud Drive) and link that folder here; Inkwell then keeps itself in step. Your handwriting stays on its own layer above each page, so you can keep writing.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Import PDFs…") { showPDFPicker = true }
                            .buttonStyle(.bordered)
                        Button("Link a folder…") { showFolderPicker = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("Goodnotes' own .goodnotes files can't be read yet. Exports to PDF keep everything you drew on the page.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }

            if !linked.folders.isEmpty {
                Section("Linked folders") {
                    ForEach(linked.folders) { f in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(f.name, systemImage: "link").font(.headline)
                                Spacer()
                                if linked.syncing.contains(f.id) { ProgressView() }
                                else { Button("Sync now") { Task { await linked.sync(f.id, into: store) } }.buttonStyle(.bordered) }
                            }
                            Text("Into: \(store.node(f.destinationID)?.name ?? "No Folder")")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let r = f.lastResult {
                                Text("\(r)\(f.lastSync.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "")")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Change destination…", systemImage: "folder") { pickDestination = f }
                            Button("Unlink", systemImage: "link.badge.minus", role: .destructive) { linked.remove(f.id) }
                        }
                        .swipeActions {
                            Button("Unlink", role: .destructive) { linked.remove(f.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result, let f = linked.link(url: url, destination: nil) else {
                note = "Couldn't link that folder."
                return
            }
            Task { await linked.sync(f.id, into: store) }
        }
        .fileImporter(isPresented: $showPDFPicker, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let made = urls.filter { store.importPDF(from: $0, into: nil) != nil }.count
            note = "Imported \(made) of \(urls.count) PDF\(urls.count == 1 ? "" : "s") into No Folder."
        }
        .sheet(item: $pickDestination) { f in
            FolderPickerSheet(title: "Import into…", initial: f.destinationID) { linked.setDestination(f.id, $0) }
        }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
