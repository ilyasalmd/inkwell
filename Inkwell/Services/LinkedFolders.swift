import SwiftUI

struct LinkedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var bookmark: Data
    var destinationID: UUID?
    var lastSync: Date?
    var lastResult: String?
}

struct SyncReport {
    var created = 0, updated = 0, unchanged = 0, waiting = 0, failed = 0
    var summary: String {
        var parts: [String] = []
        if created > 0 { parts.append("\(created) new") }
        if updated > 0 { parts.append("\(updated) updated") }
        if unchanged > 0 { parts.append("\(unchanged) up to date") }
        if waiting > 0 { parts.append("\(waiting) still downloading from iCloud") }
        if failed > 0 { parts.append("\(failed) couldn't be read") }
        return parts.isEmpty ? "No PDFs found" : parts.joined(separator: " · ")
    }
}

/// Watches folders of exported PDFs (for example a Goodnotes auto-backup folder) and mirrors them into the library.
@MainActor @Observable
final class LinkedFolderService {
    var folders: [LinkedFolder] = []
    var syncing: Set<UUID> = []

    @ObservationIgnored private let defaultsKey = "linkedFolders"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([LinkedFolder].self, from: data) {
            folders = saved
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func link(url: URL, destination: UUID?) -> LinkedFolder? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        guard let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        let folder = LinkedFolder(name: url.lastPathComponent, bookmark: data, destinationID: destination)
        folders.append(folder)
        persist()
        return folder
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persist()
    }

    func setDestination(_ id: UUID, _ destination: UUID?) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].destinationID = destination
        persist()
    }

    func syncAll(into store: LibraryStore) async {
        for f in folders { await sync(f.id, into: store) }
    }

    func sync(_ id: UUID, into store: LibraryStore) async {
        guard let idx = folders.firstIndex(where: { $0.id == id }), !syncing.contains(id) else { return }
        syncing.insert(id)
        defer { syncing.remove(id) }

        var stale = false
        #if targetEnvironment(macCatalyst)
        let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let resolveOptions: URL.BookmarkResolutionOptions = []
        #endif
        guard let root = try? URL(resolvingBookmarkData: folders[idx].bookmark, options: resolveOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) else {
            folders[idx].lastResult = "Folder is no longer available. Link it again."
            persist()
            return
        }
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let destination = folders[idx].destinationID
        let report = scan(root: root, folderID: id, destination: destination, store: store)

        if let i = folders.firstIndex(where: { $0.id == id }) {
            folders[i].lastSync = Date()
            folders[i].lastResult = report.summary
            persist()
        }
    }

    private func scan(root: URL, folderID: UUID, destination: UUID?, store: LibraryStore) -> SyncReport {
        var report = SyncReport()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                         options: [.skipsPackageDescendants]) else { return report }
        var folderIndex: [String: UUID] = [:]    // relative directory path -> folder node

        func folderNode(for relativeDir: String) -> UUID? {
            if relativeDir.isEmpty { return destination }
            if let hit = folderIndex[relativeDir] { return hit }
            let parentPath = (relativeDir as NSString).deletingLastPathComponent
            let parent = folderNode(for: parentPath == "." ? "" : parentPath)
            let name = (relativeDir as NSString).lastPathComponent
            let key = "dir:\(folderID.uuidString):\(relativeDir)"
            if let existing = store.nodes.values.first(where: { $0.sourceKey == key }) {
                folderIndex[relativeDir] = existing.id
                return existing.id
            }
            var f = store.createFolder(name: name, in: parent, tint: .slate)
            f.sourceKey = key
            store.mutate(f.id) { $0.sourceKey = key }
            folderIndex[relativeDir] = f.id
            return f.id
        }

        let rootPath = root.standardizedFileURL.path
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                // iCloud placeholder for a PDF that isn't on this device yet
                if name.hasSuffix(".pdf.icloud") {
                    let real = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                    try? fm.startDownloadingUbiquitousItem(at: real)
                    report.waiting += 1
                }
                continue
            }
            guard url.pathExtension.lowercased() == "pdf" else { continue }

            let full = url.standardizedFileURL.path
            let relative = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : name
            let relativeDir = (relative as NSString).deletingLastPathComponent
            let key = "pdf:\(folderID.uuidString):\(relative)"
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0

            if let existing = store.nodes.values.first(where: { $0.sourceKey == key }) {
                if existing.sourceStamp == stamp {
                    report.unchanged += 1
                } else {
                    store.refreshImportedPDF(existing.id, from: url, stamp: stamp)
                    report.updated += 1
                }
            } else {
                let parent = folderNode(for: relativeDir == "." ? "" : relativeDir)
                let title = url.deletingPathExtension().lastPathComponent
                if store.importPDF(from: url, into: parent, name: title, sourceKey: key, stamp: stamp) != nil {
                    report.created += 1
                } else {
                    report.failed += 1
                }
            }
        }
        return report
    }
}
