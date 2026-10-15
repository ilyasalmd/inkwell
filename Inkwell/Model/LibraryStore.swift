import SwiftUI
import PencilKit

@MainActor @Observable
final class LibraryStore {
    private(set) var nodes: [UUID: Node] = [:]
    var rules: [ScheduleRule] = []
    private(set) var usingICloud = false
    var syncMessage: String?
    /// Nodes created by the most recent `runSchedules` call (used for toasts and notifications).
    private(set) var lastCreated: [Node] = []

    /// Bumped whenever a page's ink changes so thumbnails know to redraw.
    private(set) var drawingRevision: [UUID: Int] = [:]

    @ObservationIgnored private(set) var storage: LibraryStorage
    @ObservationIgnored private var drawingCache: [UUID: PKDrawing] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var writtenNodes: [UUID: Data] = [:]
    @ObservationIgnored private var writtenRules: [UUID: Data] = [:]
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(root: URL? = nil) {
        storage = LibraryStorage(root: root ?? LibraryStorage.localRoot(), isCloud: false)
        storage.migrateLegacyIfNeeded()
        reload()
        if nodes.isEmpty { seed() }
    }

    // MARK: Persistence

    private func reload() {
        let loaded = storage.loadAll()
        nodes = Dictionary(loaded.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        rules = loaded.rules
        writtenNodes = loaded.nodeData
        writtenRules = loaded.ruleData
        drawingCache.removeAll()
    }

    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    /// Writes only the records that changed since the last write.
    func flush() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for (id, node) in nodes {
            guard let data = try? enc.encode(node), writtenNodes[id] != data else { continue }
            storage.writeNode(id: id, data: data)
            writtenNodes[id] = data
        }
        for id in writtenNodes.keys where nodes[id] == nil {
            storage.deleteNode(id: id)
            writtenNodes[id] = nil
        }
        for rule in rules {
            guard let data = try? enc.encode(rule), writtenRules[rule.id] != data else { continue }
            storage.writeRule(id: rule.id, data: data)
            writtenRules[rule.id] = data
        }
        let live = Set(rules.map(\.id))
        for id in writtenRules.keys where !live.contains(id) {
            storage.deleteRule(id: id)
            writtenRules[id] = nil
        }
    }

    // MARK: Backups

    /// Writes any pending changes now and, when one is due, takes a backup. Called when the app goes to the
    /// background and at launch, so a backup is never more than a few hours behind.
    @discardableResult
    func backUp(force: Bool = false) async -> LibraryBackup? {
        flush()
        let storage = storage
        #if canImport(UIKit)
        // Leaving the app gives only a few seconds; ask for enough time to finish copying.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Inkwell backup")
        defer { UIApplication.shared.endBackgroundTask(task) }
        #endif
        let made = await Task.detached(priority: .utility) { LibraryBackup.snapshot(storage, force: force) }.value
        backupsChanged += 1
        return made
    }

    /// Bumped after each backup so the Settings list refreshes.
    private(set) var backupsChanged = 0

    var backups: [LibraryBackup] {
        _ = backupsChanged
        return LibraryBackup.list(storage)
    }

    /// Brings a backup back as a copy in a new folder. Nothing already in the library is changed or replaced.
    /// Returns how many notebooks came back.
    @discardableResult
    func restoreCopy(of backup: LibraryBackup) -> Int {
        let saved = backup.nodes()
        guard !saved.isEmpty else { return 0 }
        let title = "Restored " + backup.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        let folder = createFolder(name: title, in: nil, tint: .ink)
        let newIDs = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, UUID()) })
        var notebooks = 0
        for var n in saved {
            n.id = newIDs[n.id]!
            n.parentID = n.parentID.flatMap { newIDs[$0] } ?? folder.id
            n.pages = n.pages.map { page in
                var p = page
                p.id = UUID()
                if let data = backup.drawing(page.id) { storage.writeDrawing(data, pageID: p.id) }
                return p
            }
            if let file = n.pdfFile, !FileManager.default.fileExists(atPath: storage.importURL(file).path) {
                storage.coordinatedCopy(backup.importURL(file), to: storage.importURL(file))
            }
            nodes[n.id] = n
            if !n.isFolder { notebooks += 1 }
        }
        save()
        return notebooks
    }

    // MARK: iCloud

    /// Switches between this device's storage and the iCloud Drive container. Returns false if iCloud is unavailable.
    @discardableResult
    func setICloud(_ enabled: Bool) async -> Bool {
        flush()
        if enabled {
            let root = await Task.detached { LibraryStorage.iCloudRoot() }.value
            guard let root else {
                syncMessage = "iCloud isn't available. Sign in to iCloud and allow Inkwell in Settings."
                return false
            }
            let cloud = LibraryStorage(root: root, isCloud: true)
            await Task.detached { [storage] in LibraryStorage.copyContents(from: storage, to: cloud) }.value
            storage = cloud
            usingICloud = true
            reload()
            startWatching()
            syncMessage = nil
        } else {
            stopWatching()
            let local = LibraryStorage(root: LibraryStorage.localRoot(), isCloud: false)
            await Task.detached { [storage] in LibraryStorage.copyContents(from: storage, to: local) }.value
            storage = local
            usingICloud = false
            reload()
            syncMessage = nil
        }
        return true
    }

    private func startWatching() {
        stopWatching()
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.remoteChanged() }
        }
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main, using: handler),
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main, using: handler)
        ]
        q.start()
        query = q
    }

    private func stopWatching() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func remoteChanged() {
        // Local edits that haven't been written yet win; the next update will bring remote changes in.
        guard saveTask == nil || saveTask?.isCancelled == true || !hasUnsavedChanges else { return }
        reload()
    }

    private var hasUnsavedChanges: Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for (id, node) in nodes where (try? enc.encode(node)) != writtenNodes[id] { return true }
        return false
    }

    private func seed() {
        let lectures = createFolder(name: "Lectures", in: nil, tint: .ocean)
        _ = createFolder(name: "Ideas", in: nil, tint: .gold)
        var welcome = CoverDesign(primary: 0xD6452B, secondary: 0xF7D7A8, pattern: .arches, symbol: "pencil.and.ruler.fill",
                                  titleStyle: .serif, label: .plate, material: .cloth, ribbon: true)
        welcome.symbol = "pencil.and.ruler.fill"
        createNotebook(name: "Welcome to Inkwell", in: nil, template: .lined, paper: .cream, tint: .ink, cover: welcome)
        let lecture = CoverDesign(primary: 0x1F2A44, secondary: 0xE8C26B, pattern: .grid, symbol: "graduationcap.fill",
                                  titleStyle: .serif, label: .band, material: .leather, ribbon: true)
        createNotebook(name: "Lecture notes", in: lectures.id, template: .cornell, paper: .white, tint: .ocean, cover: lecture)
    }

    // MARK: Queries

    func node(_ id: UUID?) -> Node? { id.flatMap { nodes[$0] } }

    func children(of parent: UUID?) -> [Node] {
        nodes.values.filter { $0.parentID == parent }
    }

    func sortedChildren(of parent: UUID?, by sort: SortOption) -> [Node] {
        Self.sorted(children(of: parent), by: sort)
    }

    static func sorted(_ items: [Node], by sort: SortOption) -> [Node] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modified: return a.modifiedAt > b.modifiedAt
            case .created: return a.createdAt > b.createdAt
            }
        }
    }

    func itemCount(in folder: UUID) -> Int { children(of: folder).count }

    /// Ancestors from the top of the library down to (and including) `id`.
    func path(to id: UUID?) -> [Node] {
        var result: [Node] = []
        var current = id
        while let cid = current, let n = nodes[cid] {
            result.insert(n, at: 0)
            current = n.parentID
        }
        return result
    }

    func isDescendant(_ id: UUID, of ancestor: UUID) -> Bool {
        var current = nodes[id]?.parentID
        while let c = current {
            if c == ancestor { return true }
            current = nodes[c]?.parentID
        }
        return false
    }

    func folderTree(parent: UUID? = nil) -> [FolderTree] {
        children(of: parent)
            .filter(\.isFolder)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { n in
                let kids = folderTree(parent: n.id)
                return FolderTree(id: n.id, node: n, children: kids.isEmpty ? nil : kids)
            }
    }

    /// Folders flattened with their depth, for pickers.
    func flatFolders(parent: UUID? = nil, depth: Int = 0, excluding: UUID? = nil) -> [(node: Node, depth: Int)] {
        var out: [(Node, Int)] = []
        for t in folderTree(parent: parent) where t.id != excluding {
            out.append((t.node, depth))
            out += flatFolders(parent: t.id, depth: depth + 1, excluding: excluding)
        }
        return out
    }

    func uniqueName(_ base: String, in parent: UUID?, ignoring: UUID? = nil) -> String {
        let taken = Set(children(of: parent).filter { $0.id != ignoring }.map(\.name))
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: Create

    @discardableResult
    func createFolder(name: String, in parent: UUID?, tint: NodeTint = .ink, cover: CoverDesign? = nil) -> Node {
        var n = Node(name: uniqueName(name, in: parent), kind: .folder, parentID: parent, tint: tint)
        n.cover = cover
        nodes[n.id] = n
        save()
        return n
    }

    @discardableResult
    func createNotebook(name: String, in parent: UUID?, template: PageTemplate,
                        paper: PaperColor, tint: NodeTint, eventID: String? = nil,
                        cover: CoverDesign? = nil, mode: NotebookMode = .pages) -> Node {
        var n = Node(name: uniqueName(name, in: parent), kind: .notebook, parentID: parent, tint: tint)
        n.pages = [PageInfo(template: template, paper: paper)]
        n.mode = mode == .whiteboard ? .whiteboard : nil
        n.sourceEventID = eventID
        n.cover = cover
        nodes[n.id] = n
        save()
        return n
    }

    // MARK: Edit

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var n = nodes[id] else { return }
        n.name = uniqueName(trimmed, in: n.parentID, ignoring: id)
        n.modifiedAt = Date()
        nodes[id] = n
        save()
    }

    func setTint(_ id: UUID, _ tint: NodeTint) {
        nodes[id]?.tint = tint
        save()
    }

    func touch(_ id: UUID) {
        nodes[id]?.modifiedAt = Date()
        save()
    }

    @discardableResult
    func move(_ id: UUID, to newParent: UUID?) -> Bool {
        guard var n = nodes[id], n.parentID != newParent else { return false }
        if let p = newParent {
            guard nodes[p]?.isFolder == true, p != id, !isDescendant(p, of: id) else { return false }
        }
        n.parentID = newParent
        n.name = uniqueName(n.name, in: newParent, ignoring: id)
        nodes[id] = n
        save()
        return true
    }

    func delete(_ id: UUID) {
        var doomed: [UUID] = []
        func collect(_ nid: UUID) {
            doomed.append(nid)
            children(of: nid).forEach { collect($0.id) }
        }
        collect(id)
        for nid in doomed {
            if let n = nodes[nid] {
                for p in n.pages {
                    drawingCache[p.id] = nil
                    storage.deleteDrawing(p.id)
                }
                if let f = n.pdfFile { try? FileManager.default.removeItem(at: storage.importURL(f)) }
            }
            nodes[nid] = nil
        }
        for i in rules.indices where rules[i].destinationID.map(doomed.contains) == true {
            rules[i].destinationID = nil
        }
        save()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let src = nodes[id] else { return nil }
        return copy(src, into: src.parentID, rename: true)
    }

    private func copy(_ src: Node, into parent: UUID?, rename: Bool) -> UUID {
        var n = src
        n.id = UUID()
        n.parentID = parent
        n.createdAt = Date()
        n.modifiedAt = Date()
        n.sourceEventID = nil
        n.sourceKey = nil
        n.sourceStamp = nil
        if let f = src.pdfFile {
            let newName = UUID().uuidString + ".pdf"
            try? FileManager.default.copyItem(at: storage.readImport(f), to: storage.importURL(newName))
            n.pdfFile = newName
        }
        if rename { n.name = uniqueName(src.name + " copy", in: parent) }
        n.pages = src.pages.map { old in
            var p = old
            p.id = UUID()
            if let d = storage.readDrawing(old.id) { storage.writeDrawing(d, pageID: p.id) }
            return p
        }
        nodes[n.id] = n
        if src.isFolder {
            for child in children(of: src.id) { _ = copy(child, into: n.id, rename: false) }
        }
        save()
        return n.id
    }

    // MARK: Pages & drawings

    /// Adds a page at the end, or right after `afterPageID` when given.
    func addPage(to notebookID: UUID, template: PageTemplate? = nil, paper: PaperColor? = nil, after afterPageID: UUID? = nil) {
        guard var n = nodes[notebookID], !n.isWhiteboard else { return }
        let anchor = afterPageID.flatMap { id in n.pages.firstIndex { $0.id == id } }
        let reference = anchor.map { n.pages[$0] } ?? n.pages.last
        let page = PageInfo(template: template ?? reference?.template ?? .blank,
                            paper: paper ?? reference?.paper ?? .white)
        if let anchor { n.pages.insert(page, at: anchor + 1) } else { n.pages.append(page) }
        n.modifiedAt = Date()
        nodes[notebookID] = n
        save()
    }

    func deletePage(_ pageID: UUID, in notebookID: UUID) {
        guard var n = nodes[notebookID], n.pages.count > 1 else { return }
        n.pages.removeAll { $0.id == pageID }
        nodes[notebookID] = n
        drawingCache[pageID] = nil
        storage.deleteDrawing(pageID)
        save()
    }

    func movePages(in notebookID: UUID, from source: IndexSet, to destination: Int) {
        guard var n = nodes[notebookID] else { return }
        n.pages.move(fromOffsets: source, toOffset: destination)
        n.modifiedAt = Date()
        nodes[notebookID] = n
        save()
    }

    func setStyle(notebookID: UUID, pageID: UUID?, template: PageTemplate, paper: PaperColor) {
        guard var n = nodes[notebookID] else { return }
        for i in n.pages.indices where pageID == nil || n.pages[i].id == pageID {
            n.pages[i].template = template
            n.pages[i].paper = paper
        }
        nodes[notebookID] = n
        save()
    }

    func drawing(for pageID: UUID) -> PKDrawing {
        if let d = drawingCache[pageID] { return d }
        let d = storage.readDrawing(pageID).flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        drawingCache[pageID] = d
        return d
    }

    func saveDrawing(_ drawing: PKDrawing, pageID: UUID) {
        drawingCache[pageID] = drawing
        drawingRevision[pageID, default: 0] += 1
        storage.writeDrawing(drawing.dataRepresentation(), pageID: pageID)
        ClaudeBridge.shared.pageChanged(pageID)
    }

    // MARK: Schedules

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static func format(_ pattern: String, title: String, n: Int, date: Date) -> String {
        pattern
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{n}", with: String(n))
            .replacingOccurrences(of: "{date}", with: shortDateFormatter.string(from: date))
    }

    /// Creates every folder/notebook that a rule says should exist by now. Safe to call repeatedly.
    @discardableResult
    func runSchedules(now: Date = Date()) -> Int {
        let cal = Calendar.current
        var created = 0
        lastCreated = []
        for ri in rules.indices where rules[ri].isEnabled {
            let rule = rules[ri]
            let start = cal.startOfDay(for: rule.startDate)
            guard let horizonBase = cal.date(byAdding: .day, value: rule.leadDays, to: cal.startOfDay(for: now)) else { continue }
            var end = horizonBase
            if let e = rule.endDate { end = min(end, cal.startOfDay(for: e)) }
            guard start <= end else { continue }

            let destination = node(rule.destinationID)?.isFolder == true ? rule.destinationID : nil
            var day = start
            var n = 0
            var steps = 0
            while day <= end && steps < 800 {
                if rule.weekdays.contains(cal.component(.weekday, from: day)) {
                    n += 1
                    let key = Self.dayKeyFormatter.string(from: day)
                    if !rules[ri].generated.contains(key) {
                        let name = Self.format(rule.nameFormat, title: rule.title, n: n, date: day)
                        switch rule.output {
                        case .notebook:
                            let nb = createNotebook(name: name, in: destination, template: rule.template,
                                                    paper: rule.paper, tint: rule.tint, cover: rule.cover)
                            lastCreated.append(nb)
                        case .folder:
                            let f = createFolder(name: name, in: destination, tint: rule.tint, cover: rule.cover)
                            let nb = createNotebook(name: "Notes", in: f.id, template: rule.template,
                                                    paper: rule.paper, tint: rule.tint, cover: rule.cover)
                            lastCreated.append(nb)
                        }
                        rules[ri].generated.insert(key)
                        created += 1
                    }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                steps += 1
            }
        }
        if created > 0 { save() }
        return created
    }

    func saveRules() { save() }

    func notebookExists(forEvent id: String) -> Bool {
        nodes.values.contains { $0.sourceEventID == id }
    }

    // MARK: Helpers for importers

    func addNode(_ node: Node) {
        nodes[node.id] = node
        save()
    }

    func mutate(_ id: UUID, _ change: (inout Node) -> Void) {
        guard var n = nodes[id] else { return }
        change(&n)
        nodes[id] = n
        save()
    }

    func setCover(_ id: UUID, _ design: CoverDesign) {
        mutate(id) { $0.cover = design }
    }
}
