import SwiftUI
import PencilKit
import PDFKit

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Turns a notebook into a PDF. Page notebooks export every page (template or imported PDF, with the ink on top).
/// A whiteboard exports as one page cropped to what was drawn.
@MainActor
enum NotebookExporter {
    private static let pageWidth: CGFloat = 595   // A4 width in points

    static func exportPDF(_ notebook: Node, store: LibraryStore) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(notebook.name))
        try? FileManager.default.removeItem(at: url)
        do {
            if notebook.isWhiteboard { try writeWhiteboard(notebook, store: store, to: url) }
            else { try writePages(notebook, store: store, to: url) }
            return url
        } catch {
            return nil
        }
    }

    /// One page as a PNG (template or PDF page, ink on top). Used to show Claude what you're writing.
    static func pageImageData(_ page: PageInfo, notebook: Node, store: LibraryStore, width: CGFloat = 1100) -> Data? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        if notebook.isWhiteboard {
            let drawing = store.drawing(for: page.id)
            guard !drawing.strokes.isEmpty else { return nil }
            let area = drawing.bounds.insetBy(dx: -60, dy: -60)
            let fit = min(1, 1600 / max(area.width, area.height))
            let rect = CGRect(x: 0, y: 0, width: area.width * fit, height: area.height * fit)
            return UIGraphicsImageRenderer(bounds: rect, format: fmt).image { ctx in
                UIColor(page.paper.color).setFill()
                ctx.cgContext.fill(rect)
                drawInk(drawing, style: page.inkStyle, logical: area, into: rect, scale: fit)
            }.pngData()
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: width * page.heightRatio)
        let source = notebook.pdfFile.flatMap { PDFDocument(url: store.storage.readImport($0)) }
        return UIGraphicsImageRenderer(bounds: rect, format: fmt).image { ctx in
            drawBackground(page, in: rect, source: source, cg: ctx.cgContext)
            drawInk(store.drawing(for: page.id), style: page.inkStyle,
                    logical: CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio),
                    into: rect, scale: width / PageMetrics.width)
        }.pngData()
    }

    private static func fileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean.isEmpty ? "Notebook" : clean) + ".pdf"
    }

    // MARK: Pages

    private static func writePages(_ notebook: Node, store: LibraryStore, to url: URL) throws {
        guard let first = notebook.pages.first else { return }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * first.heightRatio))
        let source = notebook.pdfFile.flatMap { PDFDocument(url: store.storage.readImport($0)) }

        try renderer.writePDF(to: url) { ctx in
            for page in notebook.pages {
                let rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageWidth * page.heightRatio)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                drawBackground(page, in: rect, source: source, cg: ctx.cgContext)
                drawInk(store.drawing(for: page.id), style: page.inkStyle,
                        logical: CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio),
                        into: rect)
            }
        }
    }

    private static func drawBackground(_ page: PageInfo, in rect: CGRect, source: PDFDocument?, cg: CGContext) {
        if let idx = page.pdfIndex, let pdfPage = source?.page(at: idx) {
            UIColor.white.setFill()
            cg.fill(rect)
            if pdfPage.rotation == 0 {
                let box = pdfPage.bounds(for: .cropBox)
                cg.saveGState()
                cg.translateBy(x: 0, y: rect.height)
                cg.scaleBy(x: rect.width / box.width, y: -rect.height / box.height)
                cg.translateBy(x: -box.minX, y: -box.minY)
                pdfPage.draw(with: .cropBox, to: cg)
                cg.restoreGState()
            } else {
                pdfPage.thumbnail(of: CGSize(width: 1600, height: 1600 * page.heightRatio), for: .cropBox).draw(in: rect)
            }
            return
        }
        let view = TemplateBackground(template: page.template, paper: page.paper)
            .frame(width: PageMetrics.width, height: PageMetrics.height)
        let image = ImageRenderer(content: view)
        image.scale = 2
        image.uiImage?.draw(in: rect)
    }

    private static func drawInk(_ drawing: PKDrawing, style: UIUserInterfaceStyle, logical: CGRect, into rect: CGRect, scale: CGFloat = 2) {
        guard !drawing.strokes.isEmpty else { return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: style).performAsCurrent {
            image = drawing.image(from: logical, scale: scale)
        }
        image?.draw(in: rect)
    }

    // MARK: Whiteboard

    private static func writeWhiteboard(_ notebook: Node, store: LibraryStore, to url: URL) throws {
        guard let page = notebook.pages.first else { return }
        let drawing = store.drawing(for: page.id)
        var area = drawing.strokes.isEmpty ? CGRect(x: 0, y: 0, width: 1000, height: 700) : drawing.bounds
        area = area.insetBy(dx: -80, dy: -80)

        let fit = min(1, 14000 / max(area.width, area.height))          // PDF pages top out near 14,400 pt
        let pageRect = CGRect(x: 0, y: 0, width: area.width * fit, height: area.height * fit)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        try renderer.writePDF(to: url) { ctx in
            ctx.beginPage()
            let cg = ctx.cgContext
            UIColor(page.paper.color).setFill()
            cg.fill(pageRect)
            cg.saveGState()
            cg.scaleBy(x: fit, y: fit)
            cg.translateBy(x: -area.minX, y: -area.minY)
            drawBoardGrid(template: page.template, paper: page.paper, area: area, cg: cg)
            cg.restoreGState()
            drawInk(drawing, style: page.inkStyle, logical: area, into: pageRect,
                    scale: min(2, 5000 / max(area.width, area.height)))
        }
    }

    static func drawBoardGrid(template: PageTemplate, paper: PaperColor, area: CGRect, cg: CGContext) {
        let line = UIColor(paper.lineColor)
        func lines(spacing: CGFloat, horizontal: Bool, vertical: Bool) {
            cg.setStrokeColor(line.cgColor)
            cg.setLineWidth(1.2)
            if vertical {
                var x = (area.minX / spacing).rounded(.down) * spacing
                while x <= area.maxX { cg.move(to: CGPoint(x: x, y: area.minY)); cg.addLine(to: CGPoint(x: x, y: area.maxY)); x += spacing }
            }
            if horizontal {
                var y = (area.minY / spacing).rounded(.down) * spacing
                while y <= area.maxY { cg.move(to: CGPoint(x: area.minX, y: y)); cg.addLine(to: CGPoint(x: area.maxX, y: y)); y += spacing }
            }
            cg.strokePath()
        }
        switch template {
        case .lined: lines(spacing: 46, horizontal: true, vertical: false)
        case .squared: lines(spacing: 40, horizontal: true, vertical: true)
        case .dotted:
            cg.setFillColor(line.withAlphaComponent(0.9).cgColor)
            var y = (area.minY / 40).rounded(.down) * 40
            while y <= area.maxY {
                var x = (area.minX / 40).rounded(.down) * 40
                while x <= area.maxX { cg.fillEllipse(in: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)); x += 40 }
                y += 40
            }
        default: break
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
