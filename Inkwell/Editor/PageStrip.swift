import SwiftUI
import PencilKit

struct PageRef: Codable, Transferable {
    var pageID: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct PageThumb: View {
    let page: PageInfo
    let notebook: Node
    let number: Int
    let selected: Bool
    @Environment(LibraryStore.self) private var store
    @State private var ink: UIImage?
    private let width: CGFloat = 112

    var body: some View {
        VStack(spacing: 6) {
            ScaledPage(width: width, aspect: page.heightRatio) {
                ZStack {
                    if let idx = page.pdfIndex, let file = notebook.pdfFile {
                        PDFPageBackground(file: file, index: idx, aspect: page.heightRatio)
                    } else {
                        TemplateBackground(template: page.template, paper: page.paper)
                    }
                    if let ink {
                        Image(uiImage: ink).resizable()
                            .frame(width: PageMetrics.width, height: PageMetrics.width * page.heightRatio)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
            Text("\(number)")
                .font(.caption.weight(selected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .task(id: store.drawingRevision[page.id] ?? 0) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let drawing = store.drawing(for: page.id)
            guard !drawing.strokes.isEmpty else { ink = nil; return }
            let rect = CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio)
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: page.inkStyle).performAsCurrent {
                image = drawing.image(from: rect, scale: 0.3)
            }
            ink = image
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Thumbnails of every page: tap to jump, drag to reorder, long-press for insert and delete.
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
                    PageThumb(page: page, notebook: notebook, number: i + 1, selected: page.id == currentPageID)
                        .onTapGesture { jump(page.id) }
                        .draggable(PageRef(pageID: page.id)) {
                            PageThumb(page: page, notebook: notebook, number: i + 1, selected: true)
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
                            Button("Delete page", systemImage: "trash", role: .destructive) {
                                withAnimation(.snappy) { store.deletePage(page.id, in: notebook.id) }
                            }
                            .disabled(notebook.pages.count < 2)
                        }
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
            .frame(maxWidth: .infinity)
        }
        .frame(width: 148)
        .background(.bar)
    }
}
