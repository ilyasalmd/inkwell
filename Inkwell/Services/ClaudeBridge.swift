import SwiftUI
import PencilKit

/// Keeps a folder of page images and an index next to your iCloud library so Claude on your Mac can look at
/// what you're writing without screenshots. Off by default. No network, no API: it only writes files into your own
/// iCloud Drive, and the Inkwell plugin on your Mac reads them.
///
///     <iCloud>/Documents/Inkwell/ForClaude/index.json
///     <iCloud>/Documents/Inkwell/ForClaude/pages/<pageID>.png
@MainActor
final class ClaudeBridge {
    static let shared = ClaudeBridge()
    static let key = "shareWithClaude"

    weak var store: LibraryStore?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var syncing: Task<Void, Never>?
    private var lastEdited: (page: UUID, at: Date)?

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    private var folder: URL? {
        #if DEBUG
        if enabled, let dir = UserDefaults.standard.string(forKey: "claudeBridgeDebugFolder") { return URL(fileURLWithPath: dir) }
        #endif
        guard enabled, let store, store.usingICloud else { return nil }
        return store.storage.root.appendingPathComponent("ForClaude", isDirectory: true)
    }

    // MARK: Triggers

    /// Called whenever ink changes. Waits until you pause, then refreshes just that page.
    func pageChanged(_ pageID: UUID) {
        guard enabled else { return }
        lastEdited = (pageID, Date())
        pending[pageID]?.cancel()
        pending[pageID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.render(pageID)
            self.writeIndex()
            self.pending[pageID] = nil
        }
    }

    /// Renders every page that has ink. Runs when the switch is turned on and after launch.
    func syncAll() {
        guard enabled else { return }
        syncing?.cancel()
        syncing = Task { [weak self] in
            guard let self, let store = self.store else { return }
            for node in store.nodes.values where !node.isFolder {
                for page in node.pages where !store.drawing(for: page.id).strokes.isEmpty {
                    if Task.isCancelled { return }
                    self.render(page.id)
                    await Task.yield()
                }
            }
            self.writeIndex()
        }
    }

    // MARK: Files

    private func render(_ pageID: UUID) {
        guard let folder, let store,
              let node = store.nodes.values.first(where: { $0.pages.contains { $0.id == pageID } }),
              let page = node.pages.first(where: { $0.id == pageID }) else { return }
        let dir = folder.appendingPathComponent("pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(pageID.uuidString).png")
        guard let data = NotebookExporter.pageImageData(page, notebook: node, store: store) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func writeIndex() {
        guard let folder, let store else { return }
        struct PageEntry: Encodable { var id: String; var number: Int; var hasInk: Bool }
        struct NotebookEntry: Encodable {
            var id: String; var name: String; var folder: String; var whiteboard: Bool
            var modified: Date; var pages: [PageEntry]
        }
        struct Index: Encodable {
            var updated: Date; var lastEditedPage: String?; var lastEditedNotebook: String?; var notebooks: [NotebookEntry]
        }
        let books = store.nodes.values.filter { !$0.isFolder }.sorted { $0.modifiedAt > $1.modifiedAt }.map { n in
            NotebookEntry(id: n.id.uuidString, name: n.name,
                          folder: store.path(to: n.parentID).map(\.name).joined(separator: "/"),
                          whiteboard: n.isWhiteboard, modified: n.modifiedAt,
                          pages: n.pages.enumerated().map { i, p in
                              PageEntry(id: p.id.uuidString, number: i + 1, hasInk: !store.drawing(for: p.id).strokes.isEmpty)
                          })
        }
        let lastNotebook = lastEdited.flatMap { e in
            store.nodes.values.first { $0.pages.contains { $0.id == e.page } }?.id.uuidString
        }
        let index = Index(updated: Date(), lastEditedPage: lastEdited?.page.uuidString,
                          lastEditedNotebook: lastNotebook, notebooks: books)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? enc.encode(index) {
            try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}
