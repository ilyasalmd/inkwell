import SwiftUI
import PencilKit
import Network

/// Keeps a folder of page images and an index next to your iCloud library so Claude on your Mac can look at
/// what you're writing without screenshots. Off by default. No network, no API: it only writes files into your own
/// iCloud Drive, and the Inkwell plugin on your Mac reads them. When the Mac is on the same Wi-Fi, each file is also
/// handed to it directly (see LiveLink), so Claude sees a page the moment you pause instead of when iCloud gets to it.
///
///     <iCloud>/Documents/Inkwell/ForClaude/index.json
///     <iCloud>/Documents/Inkwell/ForClaude/pages/<pageID>.png
///     <iCloud>/Documents/Inkwell/ForClaude/link.json     the key the Mac checks direct deliveries against
@MainActor
final class ClaudeBridge {
    static let shared = ClaudeBridge()
    static let key = "shareWithClaude"

    weak var store: LibraryStore?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var syncing: Task<Void, Never>?
    private var lastEdited: (page: UUID, at: Date)?
    private let link = LiveLink()

    /// A random key only your devices know (it travels through your iCloud), so the Mac accepts pages from no one else.
    private var linkKey: String {
        if let key = UserDefaults.standard.string(forKey: "claudeLinkKey") { return key }
        let key = UUID().uuidString + UUID().uuidString
        UserDefaults.standard.set(key, forKey: "claudeLinkKey")
        return key
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    private var folder: URL? {
        #if DEBUG
        if enabled, let dir = UserDefaults.standard.string(forKey: "claudeBridgeDebugFolder") { return URL(fileURLWithPath: dir) }
        #endif
        guard enabled, let store, store.usingICloud else { return nil }
        return store.storage.root.appendingPathComponent("ForClaude", isDirectory: true)
    }

    // MARK: Triggers

    /// Called whenever ink changes. Waits for a short pause in your writing, then refreshes just that page.
    func pageChanged(_ pageID: UUID) {
        guard enabled else { return }
        if folder != nil { link.start() }
        lastEdited = (pageID, Date())
        pending[pageID]?.cancel()
        pending[pageID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, let self else { return }
            self.render(pageID)
            self.writeIndex()
            self.pending[pageID] = nil
        }
    }

    /// Sends any page still waiting for a pause right now (used when you leave the app).
    func flush() {
        guard enabled, !pending.isEmpty else { return }
        let ids = Array(pending.keys)
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        ids.forEach(render)
        writeIndex()
    }

    /// Renders every page that has ink. Runs when the switch is turned on and after launch.
    func syncAll() {
        guard enabled else { return }
        if folder != nil { link.start() }
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
        write(data, to: file)
        link.send(data, path: "pages/\(pageID.uuidString).png", key: linkKey)
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
            write(data, to: folder.appendingPathComponent("index.json"))
            link.send(data, path: "index.json", key: linkKey)
        }
        let keyFile = folder.appendingPathComponent("link.json")
        if !FileManager.default.fileExists(atPath: keyFile.path),
           let data = try? JSONEncoder().encode(["key": linkKey]) {
            write(data, to: keyFile)
        }
    }

    /// A coordinated write tells iCloud about the change straight away, so it starts uploading at once instead of
    /// waiting to notice the file on its own.
    private func write(_ data: Data, to url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? data.write(to: u, options: .atomic)
        }
    }
}

/// Finds Inkwell on your Mac on the local network (Bonjour, `_inkwell._tcp`) and hands it files directly. Purely a
/// speed-up: iCloud still carries every file, so if the Mac isn't around nothing is lost.
@MainActor
final class LiveLink {
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_inkwell._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            // Each Claude window on the Mac may advertise ("Inkwell on Mac", "Inkwell on Mac (2)"): one per Mac is enough.
            var seen = Set<String>()
            let picked = results.compactMap { result -> NWEndpoint? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                let base = name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
                return seen.insert(base).inserted ? result.endpoint : nil
            }
            Task { @MainActor in self?.endpoints = picked }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.browser?.cancel(); self?.browser = nil } }
        }
        b.start(queue: .main)
        browser = b
    }

    func send(_ data: Data, path: String, key: String) {
        for endpoint in endpoints { Self.put(data, path: path, key: key, to: endpoint) }
    }

    /// One small HTTP PUT. Fire and forget, given up after a few seconds.
    nonisolated private static func put(_ data: Data, path: String, key: String, to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var request = Data(("PUT /\(path) HTTP/1.1\r\nHost: inkwell\r\nX-Inkwell-Key: \(key)\r\n"
            + "Content-Type: application/octet-stream\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n").utf8)
        request.append(data)
        let payload = request
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { _, _, _, _ in connection.cancel() }
                })
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { connection.cancel() }
    }
}
