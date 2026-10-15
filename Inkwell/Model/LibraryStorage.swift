import Foundation

/// File-per-record storage so iCloud Drive can merge changes from several devices.
///
///     <root>/Library/nodes/<id>.json
///     <root>/Library/rules/<id>.json
///     <root>/Drawings/<pageID>.drawing
///     <root>/Imports/<file>.pdf
final class LibraryStorage {
    static let containerID = "iCloud.com.ilyas.inkwell"

    let root: URL
    let isCloud: Bool

    var nodesDir: URL { root.appendingPathComponent("Library/nodes", isDirectory: true) }
    var rulesDir: URL { root.appendingPathComponent("Library/rules", isDirectory: true) }
    var drawingsDir: URL { root.appendingPathComponent("Drawings", isDirectory: true) }
    var importsDir: URL { root.appendingPathComponent("Imports", isDirectory: true) }

    init(root: URL, isCloud: Bool) {
        self.root = root
        self.isCloud = isCloud
        for d in [nodesDir, rulesDir, drawingsDir, importsDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    // MARK: Locations

    static func localRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inkwell", isDirectory: true)
    }

    /// Blocks on the first call; run off the main thread.
    static func iCloudRoot() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID)?
            .appendingPathComponent("Documents/Inkwell", isDirectory: true)
    }

    // MARK: Records

    struct Loaded {
        var nodes: [Node] = []
        var rules: [ScheduleRule] = []
        var nodeData: [UUID: Data] = [:]
        var ruleData: [UUID: Data] = [:]
    }

    func loadAll() -> Loaded {
        var out = Loaded()
        let dec = JSONDecoder()
        for (url, data) in records(in: nodesDir) {
            if let n = try? dec.decode(Node.self, from: data) { out.nodes.append(n); out.nodeData[n.id] = data }
            _ = url
        }
        for (_, data) in records(in: rulesDir) {
            if let r = try? dec.decode(ScheduleRule.self, from: data) { out.rules.append(r); out.ruleData[r.id] = data }
        }
        return out
    }

    private func records(in dir: URL) -> [(URL, Data)] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                options: [])) ?? []
        var result: [(URL, Data)] = []
        for url in urls {
            let name = url.lastPathComponent
            // iCloud placeholder for a file that has not downloaded yet: ".<name>.icloud"
            if isCloud, name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? fm.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(real))
                continue
            }
            guard url.pathExtension == "json" else { continue }
            if let data = coordinatedRead(url) { result.append((url, data)) }
        }
        return result
    }

    func writeNode(id: UUID, data: Data) { coordinatedWrite(data, to: nodesDir.appendingPathComponent("\(id.uuidString).json")) }
    func deleteNode(id: UUID) { coordinatedDelete(nodesDir.appendingPathComponent("\(id.uuidString).json")) }
    func writeRule(id: UUID, data: Data) { coordinatedWrite(data, to: rulesDir.appendingPathComponent("\(id.uuidString).json")) }
    func deleteRule(id: UUID) { coordinatedDelete(rulesDir.appendingPathComponent("\(id.uuidString).json")) }

    // MARK: Drawings and imports

    func drawingURL(_ pageID: UUID) -> URL { drawingsDir.appendingPathComponent("\(pageID.uuidString).drawing") }
    func importURL(_ file: String) -> URL { importsDir.appendingPathComponent(file) }

    func readDrawing(_ pageID: UUID) -> Data? {
        let url = drawingURL(pageID)
        ensureDownloaded(url)
        return coordinatedRead(url)
    }
    func writeDrawing(_ data: Data, pageID: UUID) { coordinatedWrite(data, to: drawingURL(pageID)) }
    func deleteDrawing(_ pageID: UUID) { coordinatedDelete(drawingURL(pageID)) }

    func readImport(_ file: String) -> URL {
        let url = importURL(file)
        ensureDownloaded(url)
        return url
    }

    private func ensureDownloaded(_ url: URL) {
        guard isCloud else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: Coordination

    private func coordinatedRead(_ url: URL) -> Data? {
        guard isCloud else { return try? Data(contentsOf: url) }
        var result: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) {
        guard isCloud else { try? data.write(to: url, options: .atomic); return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    func coordinatedCopy(_ source: URL, to url: URL) {
        guard isCloud else { try? FileManager.default.copyItem(at: source, to: url); return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? FileManager.default.copyItem(at: source, to: u)
        }
    }

    func coordinatedDelete(_ url: URL) {
        guard isCloud else { try? FileManager.default.removeItem(at: url); return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    // MARK: Migration

    /// Copies every file from `source` into `destination`, never overwriting existing files.
    static func copyContents(from source: LibraryStorage, to destination: LibraryStorage) {
        let fm = FileManager.default
        let pairs: [(URL, URL)] = [
            (source.nodesDir, destination.nodesDir), (source.rulesDir, destination.rulesDir),
            (source.drawingsDir, destination.drawingsDir), (source.importsDir, destination.importsDir)
        ]
        for (from, to) in pairs {
            let items = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                let target = to.appendingPathComponent(item.lastPathComponent)
                guard !fm.fileExists(atPath: target.path) else { continue }
                if destination.isCloud {
                    if let data = try? Data(contentsOf: item) { destination.coordinatedWrite(data, to: target) }
                } else {
                    try? fm.copyItem(at: item, to: target)
                }
            }
        }
    }

    /// One-time import of the first prototype's single `library.json`.
    func migrateLegacyIfNeeded() {
        let legacy = root.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        struct Legacy: Codable { var nodes: [Node]; var rules: [ScheduleRule] }
        if let snap = try? JSONDecoder().decode(Legacy.self, from: data) {
            let enc = JSONEncoder()
            for n in snap.nodes { if let d = try? enc.encode(n) { writeNode(id: n.id, data: d) } }
            for r in snap.rules { if let d = try? enc.encode(r) { writeRule(id: r.id, data: d) } }
        }
        try? FileManager.default.moveItem(at: legacy, to: root.appendingPathComponent("library.json.migrated"))
    }
}
