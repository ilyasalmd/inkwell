import SwiftUI
import PencilKit

struct PageRef: Codable, Transferable {
    var pageID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Small pictures of page backgrounds for the page strip, drawn off the main thread. A thumbnail used to lay out a
/// full 1400-pixel PDF render and a full-size paper canvas per page, which on an iPad was enough memory to get the
/// app closed when the strip opened on a long notebook.
enum PageThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()

    @MainActor
    static func background(for page: PageInfo, pdfURL: URL?, pixelWidth: CGFloat) async -> UIImage {
        let key = "\(pdfURL?.lastPathComponent ?? "")#\(page.pdfIndex ?? -1)-\(page.template.rawValue)-\(page.paper.rawValue)-\(page.heightRatio)-\(pixelWidth)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let art = PageArt(page: page, pdfURL: page.pdfIndex == nil ? nil : pdfURL)
        let ratio = page.heightRatio
        let image = await Task.detached(priority: .userInitiated) {
            let size = CGSize(width: pixelWidth, height: (pixelWidth * ratio).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { r in
                let s = size.width / PageMetrics.width
                r.cgContext.scaleBy(x: s, y: s)
                art.draw(in: r.cgContext, size: CGSize(width: PageMetrics.width, height: PageMetrics.width * ratio))
            }
        }.value
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
}

struct PageThumb: View {
    let page: PageInfo
    let notebook: Node
    let number: Int
    let selected: Bool
    @Environment(LibraryStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var background: UIImage?
    @State private var ink: UIImage?
    private let width: CGFloat = 112

    private var pdfURL: URL? { notebook.pdfFile.map { store.storage.readImport($0) } }
    private var backgroundKey: String {
        "\(notebook.pdfFile ?? "")#\(page.pdfIndex ?? -1)-\(page.template.rawValue)-\(page.paper.rawValue)"
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(uiColor: UIColor(hex: page.pdfIndex == nil ? page.paper.hex : 0xFFFFFF))
                if let background { Image(uiImage: background).resizable() }
                if let ink { Image(uiImage: ink).resizable() }
            }
            .frame(width: width, height: (width * page.heightRatio).rounded())
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
            Text("\(number)")
                .font(.caption.weight(selected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .task(id: backgroundKey) {
            background = await PageThumbnails.background(for: page, pdfURL: pdfURL, pixelWidth: width * displayScale)
        }
        .task(id: store.drawingRevision[page.id] ?? 0) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let drawing = store.drawing(for: page.id)
            guard !drawing.strokes.isEmpty else { ink = nil; return }
            let rect = CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio)
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: page.inkStyle).performAsCurrent {
                image = drawing.image(from: rect, scale: width * displayScale / PageMetrics.width)
            }
            ink = image
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Thumbnails of every page: tap to jump, drag to reorder, swipe left to delete, long-press for insert and delete.
struct PageStrip: View {
    let notebook: Node
    let currentPageID: UUID?
    var jump: (UUID) -> Void
    @Environment(LibraryStore.self) private var store
    @State private var showAdd = false

    private var current: PageInfo? { notebook.pages.first { $0.id == currentPageID } ?? notebook.pages.last }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { i, page in
                    SwipeToDelete(enabled: notebook.pages.count > 1, onDelete: { delete(page, at: i) }) {
                        PageThumb(page: page, notebook: notebook, number: i + 1, selected: page.id == currentPageID)
                            .contentShape(Rectangle())
                            .onTapGesture { jump(page.id) }
                            .draggable(PageRef(pageID: page.id)) {
                                // The drag preview is drawn outside this view tree, so it has to be handed the store.
                                PageThumb(page: page, notebook: notebook, number: i + 1, selected: true)
                                    .environment(store)
                            }
                            .dropDestination(for: PageRef.self) { items, _ in
                                guard let from = items.first.flatMap({ ref in notebook.pages.firstIndex { $0.id == ref.pageID } }),
                                      from != i else { return false }
                                withAnimation(.snappy) {
                                    store.movePages(in: notebook.id, from: IndexSet(integer: from), to: from < i ? i + 1 : i)
                                }
                                return true
                            }
                            .contextMenu {
                                Button("Insert page above", systemImage: "arrow.up.doc") {
                                    withAnimation(.snappy) { store.addPage(to: notebook.id, at: i) }
                                }
                                Button("Insert page below", systemImage: "arrow.down.doc") {
                                    withAnimation(.snappy) { store.addPage(to: notebook.id, at: i + 1) }
                                }
                                Button("Delete page", systemImage: "trash", role: .destructive) { delete(page, at: i) }
                                    .disabled(notebook.pages.count < 2)
                            }
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                }
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 112, height: 44)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                .popover(isPresented: $showAdd) {
                    AddPagePanel(startPaper: current?.paper ?? .white) { t, paper in
                        // Goes straight under the page you're on, and shows it.
                        let id = withAnimation(.snappy) {
                            store.addPage(to: notebook.id, template: t, paper: paper, after: current?.id)
                        }
                        if let id { jump(id) }
                    }
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Add page")
            }
            .padding(.vertical, 14)
        }
        .frame(width: Self.width)
        .background(.bar)
    }

    static let width: CGFloat = 148

    /// Deleting the page you're on moves you to the one that takes its place.
    private func delete(_ page: PageInfo, at i: Int) {
        let wasCurrent = page.id == current?.id
        withAnimation(.snappy) { store.deletePage(page.id, in: notebook.id) }
        if wasCurrent, let pages = store.node(notebook.id)?.pages, !pages.isEmpty {
            jump(pages[min(i, pages.count - 1)].id)
        }
    }
}

/// Slide a page thumbnail left to show a Delete button. The row is its own sideways scroll view, so the swipe never
/// fights the strip's up-and-down scrolling, a tap or drag on the page, or its press-and-hold menu.
private struct SwipeToDelete<Content: View>: View {
    let enabled: Bool
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if enabled {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    content.frame(width: PageStrip.width)
                    Button(role: .destructive, action: onDelete) {
                        VStack(spacing: 4) {
                            Image(systemName: "trash.fill").font(.system(size: 18, weight: .semibold))
                            Text("Delete").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(width: 64)
                        .frame(maxHeight: .infinity)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                    .accessibilityLabel("Delete page")
                }
            }
            .scrollTargetBehavior(SnapOpenOrShut())
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            content.frame(width: PageStrip.width)
        }
    }
}

/// Lets go either fully open (Delete showing) or fully shut, never halfway.
private struct SnapOpenOrShut: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let open = max(0, context.contentSize.width - context.containerSize.width)
        let flick = context.velocity.dx
        let opening = abs(flick) > 0.3 ? flick > 0 : target.rect.minX > open / 2
        target.rect.origin.x = opening ? open : 0
    }
}
