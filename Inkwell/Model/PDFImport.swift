import SwiftUI
import PDFKit

extension LibraryStore {
    /// Imports a PDF as a notebook whose pages sit on top of the PDF's pages.
    @discardableResult
    func importPDF(from url: URL, into parent: UUID?, name: String? = nil,
                   sourceKey: String? = nil, stamp: Double? = nil) -> Node? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }

        let file = UUID().uuidString + ".pdf"
        let dest = storage.importURL(file)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }

        let title = name ?? url.deletingPathExtension().lastPathComponent
        var node = Node(name: uniqueName(title, in: parent), kind: .notebook, parentID: parent)
        node.pdfFile = file
        node.sourceKey = sourceKey
        node.sourceStamp = stamp
        node.cover = CoverDesign.randomForImport(seed: title)
        node.pages = Self.pdfPages(doc, from: 0)
        addNode(node)
        return node
    }

    /// Replaces an imported notebook's PDF with a newer export while keeping the ink already written on it.
    func refreshImportedPDF(_ id: UUID, from url: URL, stamp: Double) {
        guard let node = nodes[id] else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return }

        let file = UUID().uuidString + ".pdf"
        guard (try? FileManager.default.copyItem(at: url, to: storage.importURL(file))) != nil else { return }
        if let old = node.pdfFile { try? FileManager.default.removeItem(at: storage.importURL(old)) }

        mutate(id) { n in
            n.pdfFile = file
            n.sourceStamp = stamp
            let existing = n.pages.compactMap(\.pdfIndex).max().map { $0 + 1 } ?? 0
            if doc.pageCount > existing { n.pages += Self.pdfPages(doc, from: existing) }
            for i in n.pages.indices {
                if let idx = n.pages[i].pdfIndex, let page = doc.page(at: idx) {
                    n.pages[i].aspect = Self.aspect(of: page)
                }
            }
            n.modifiedAt = Date()
        }
    }

    static func aspect(of page: PDFPage) -> Double {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let w = rotated ? box.height : box.width
        let h = rotated ? box.width : box.height
        return w > 0 ? Double(h / w) : 1.414
    }

    static func pdfPages(_ doc: PDFDocument, from start: Int) -> [PageInfo] {
        guard start < doc.pageCount else { return [] }
        return (start..<doc.pageCount).map { i in
            PageInfo(template: .blank, paper: .white, pdfIndex: i,
                     aspect: doc.page(at: i).map(aspect(of:)) ?? 1.414)
        }
    }
}

extension CoverDesign {
    /// Imported notebooks get a stable, distinct cover derived from their title.
    static func randomForImport(seed: String) -> CoverDesign {
        var hash: UInt64 = 1469598103934665603
        for b in seed.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let p = presets[Int(hash % UInt64(presets.count))]
        let patterns = CoverPattern.allCases
        return CoverDesign(primary: p.primary, secondary: p.secondary,
                           pattern: patterns[Int((hash >> 8) % UInt64(patterns.count))],
                           symbol: symbols[Int((hash >> 16) % UInt64(symbols.count))],
                           titleStyle: .serif, label: .plate, material: .cloth, ribbon: true)
    }
}

// MARK: - Rendering imported pages

@MainActor
final class PDFPageCache {
    static let shared = PDFPageCache()
    private let images = NSCache<NSString, UIImage>()
    private var docs: [String: PDFDocument] = [:]

    init() { images.totalCostLimit = 160 * 1024 * 1024 }

    func image(file: String, index: Int, url: URL, aspect: CGFloat) async -> UIImage? {
        let key = "\(file)#\(index)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let doc: PDFDocument
        if let d = docs[file] { doc = d } else {
            guard let d = PDFDocument(url: url) else { return nil }
            docs[file] = d
            doc = d
        }
        guard let page = doc.page(at: index) else { return nil }
        let size = CGSize(width: 1400, height: 1400 * aspect)
        let img = page.thumbnail(of: size, for: .cropBox)
        images.setObject(img, forKey: key, cost: Int(size.width * size.height * 4))
        return img
    }
}

struct PDFPageBackground: View {
    let file: String
    let index: Int
    let aspect: CGFloat
    @Environment(LibraryStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: "\(file)#\(index)") {
            image = await PDFPageCache.shared.image(file: file, index: index,
                                                    url: store.storage.readImport(file), aspect: aspect)
        }
    }
}
