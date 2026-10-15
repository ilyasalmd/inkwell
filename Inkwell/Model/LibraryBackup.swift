import Foundation

/// Automatic snapshots of the whole library, so a notebook can always be brought back, even after a deletion or an
/// erase that has already synced to every device.
///
///     <root>/Backups/<yyyy-MM-dd HHmm>/Library/nodes, Library/rules, Drawings
///     <root>/Backups/Imports/     imported PDFs never change, so one shared copy serves every snapshot
///
/// With iCloud sync on, the root is in iCloud Drive, so the snapshots live off the device as well.
struct LibraryBackup: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }

    /// How many snapshots are kept (the oldest go first).
    static let keep = 30
    /// A new snapshot is taken when the newest is at least this old.
    static let interval: TimeInterval = 4 * 3600

    private static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()

    static func directory(_ storage: LibraryStorage) -> URL {
        storage.root.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Newest first.
    static func list(_ storage: LibraryStorage) -> [LibraryBackup] {
        let dir = directory(storage)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            nameFormat.date(from: name).map { LibraryBackup(url: dir.appendingPathComponent(name, isDirectory: true), date: $0) }
        }
        .sorted { $0.date > $1.date }
    }

    /// The notebooks and folders saved in this snapshot.
    func nodes() -> [Node] {
        let dir = url.appendingPathComponent("Library/nodes", isDirectory: true)
        let dec = JSONDecoder()
        return Self.realFiles(in: dir).compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(Node.self, from: $0) } }
    }

    func drawing(_ pageID: UUID) -> Data? {
        try? Data(contentsOf: url.appendingPathComponent("Drawings/\(pageID.uuidString).drawing"))
    }

    func importURL(_ file: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Imports/\(file)")
    }

    /// Takes a snapshot when one is due (or always, with `force`). Does file work, so call it off the main thread.
    @discardableResult
    static func snapshot(_ storage: LibraryStorage, force: Bool = false) -> LibraryBackup? {
        let fm = FileManager.default
        if !force, let newest = list(storage).first, Date().timeIntervalSince(newest.date) < interval { return nil }

        // Build it privately first and move it into place in one step, so a half-written snapshot never appears.
        let temp = fm.temporaryDirectory.appendingPathComponent("inkwell-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        var copied = 0
        for (sub, from) in [("Library/nodes", storage.nodesDir), ("Library/rules", storage.rulesDir),
                            ("Drawings", storage.drawingsDir)] {
            let to = temp.appendingPathComponent(sub, isDirectory: true)
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            for item in realFiles(in: from) where (try? fm.copyItem(at: item, to: to.appendingPathComponent(item.lastPathComponent))) != nil {
                copied += 1
            }
        }
        guard copied > 0 else { return nil }

        let dir = directory(storage)
        let pool = dir.appendingPathComponent("Imports", isDirectory: true)
        try? fm.createDirectory(at: pool, withIntermediateDirectories: true)
        for item in realFiles(in: storage.importsDir) {
            let target = pool.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { storage.coordinatedCopy(item, to: target) }
        }

        let now = Date()
        let dest = dir.appendingPathComponent(nameFormat.string(from: now), isDirectory: true)
        if fm.fileExists(atPath: dest.path) { storage.coordinatedDelete(dest) }   // "Back up now" twice in a minute
        storage.coordinatedCopy(temp, to: dest)
        guard fm.fileExists(atPath: dest.path) else { return nil }

        for old in list(storage).dropFirst(keep) { storage.coordinatedDelete(old.url) }
        return LibraryBackup(url: dest, date: nameFormat.date(from: dest.lastPathComponent) ?? now)
    }

    /// Files that are really on this device (skips hidden files and iCloud placeholders that haven't downloaded).
    private static func realFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }
}
