import SwiftUI
import PencilKit

// MARK: - Canvas

struct InkCanvas: UIViewRepresentable {
    let pageID: UUID
    let paper: PaperColor
    let spec: ToolSpec
    let policy: PKCanvasViewDrawingPolicy
    let store: LibraryStore
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(pageID: pageID, store: store, model: model) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.isScrollEnabled = false
        v.drawing = store.drawing(for: pageID)
        context.coordinator.scribble = ScribbleWatcher(drawing: v.drawing)
        v.delegate = context.coordinator
        apply(to: v)
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: PKCanvasView) {
        v.overrideUserInterfaceStyle = paper.isDark ? .dark : .light
        v.drawingPolicy = policy
        v.tool = spec.makeTool()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let pageID: UUID
        let store: LibraryStore
        let model: EditorModel
        var scribble: ScribbleWatcher?

        init(pageID: UUID, store: LibraryStore, model: EditorModel) {
            self.pageID = pageID
            self.store = store
            self.model = model
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            store.saveDrawing(canvasView.drawing, pageID: pageID)
            let id = pageID, store = store
            scribble?.didChange(canvasView, enabled: model.scribbleErase, haptic: { [model] in model.haptic?(nil) },
                                save: { store.saveDrawing($0, pageID: id) })
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            model.activeCanvas = canvasView
            model.pencilDown = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            Task { @MainActor [model] in
                try? await Task.sleep(for: .milliseconds(450))
                model.pencilDown = false
            }
        }
    }
}

/// Remembers which page each notebook was on, so it reopens where you left off.
enum LastPage {
    private static func key(_ notebook: UUID) -> String { "inkwell.lastPage.\(notebook.uuidString)" }
    static func get(_ notebook: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: key(notebook)).flatMap(UUID.init(uuidString:))
    }
    static func set(_ page: UUID, in notebook: UUID) {
        UserDefaults.standard.set(page.uuidString, forKey: key(notebook))
    }
}

// MARK: - Editor

struct NotebookEditorView: View {
    let notebookID: UUID
    var switchTo: (UUID) -> Void = { _ in }
    var closeTab: (UUID) -> Void = { _ in }

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(EditorModel.self) private var model
    @Environment(NotebookTabs.self) private var tabs
    @Environment(\.inkTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var currentPageID: UUID?
    @State private var showPages = false
    @State private var showStyle = false
    @State private var showAddPage = false
    @State private var showCover = false
    @State private var showSettings = false
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportFailed = false

    var body: some View {
        Group {
            if let notebook = store.node(notebookID) {
                editor(notebook)
            } else {
                ContentUnavailableView("Notebook not found", systemImage: "book.closed")
            }
        }
    }

    private func editor(_ notebook: Node) -> some View {
        let left = settings.leftHanded
        return HStack(spacing: 0) {
            if showPages && !notebook.isWhiteboard && !left { pageStrip(notebook, edge: .leading) }
            canvasArea(notebook)
            if showPages && !notebook.isWhiteboard && left { pageStrip(notebook, edge: .trailing) }
        }
        .animation(.snappy, value: showPages)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar(notebook) }
        .sheet(isPresented: $showStyle) {
            PageStyleSheet(notebook: notebook, pageID: currentPageID ?? notebook.pages.first?.id)
                .presentationSizing(.page)
        }
        .sheet(isPresented: $showCover) { CustomiseSheet(nodeID: notebookID) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $exportFile) { file in
            ShareSheet(url: file.url).presentationDetents([.medium, .large])
        }
        .overlay { if exporting { exportingOverlay } }
        .alert("Couldn't make the PDF", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Something went wrong while writing the file. Try again.") }
        .onAppear {
            tabs.add(notebookID)
            if currentPageID == nil, let id = LastPage.get(notebookID), notebook.pages.contains(where: { $0.id == id }) {
                currentPageID = id
            }
        }
        .onChange(of: currentPageID) { _, id in
            if let id { LastPage.set(id, in: notebookID) }
        }
        .onDisappear { store.touch(notebookID) }
    }

    @ViewBuilder
    private func pageStrip(_ notebook: Node, edge: Edge) -> some View {
        if edge == .trailing { Divider() }
        PageStrip(notebook: notebook, currentPageID: currentPageID ?? notebook.pages.first?.id) { id in
            withAnimation(.snappy) { currentPageID = id }
        }
        .transition(.move(edge: edge))
        if edge == .leading { Divider() }
    }

    // MARK: Canvas area

    private func canvasArea(_ notebook: Node) -> some View {
        GeometryReader { geo in
            Group {
                if notebook.isWhiteboard, let page = notebook.pages.first {
                    WhiteboardView(page: page, model: model)
                } else {
                    pagesScroll(notebook, width: geo.size.width)
                }
            }
            .background(theme.background)
            .background(PencilInteractionLayer(model: model, settings: settings))
            .overlay {
                if model.quickPalettePoint != nil {
                    QuickPalette(model: model, container: geo.size)
                }
            }
        }
        .overlay(alignment: settings.dockAtTop ? .top : .bottom) {
            PenDock(model: model).animation(.snappy, value: model.kind.usesColor)
        }
    }

    private func pagesScroll(_ notebook: Node, width: CGFloat) -> some View {
        let available = max(width - 48, 200)
        let pageWidth = min(available, PageMetrics.width * 1.15) * zoom
        let atTop = settings.dockAtTop
        return ScrollView(zoom > 1.01 ? [.vertical, .horizontal] : .vertical) {
            LazyVStack(spacing: 28) {
                ForEach(notebook.pages) { page in
                    pageView(page, in: notebook, width: pageWidth)
                }
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { store.addPage(to: notebookID) }
                } label: {
                    Label("Add page", systemImage: "plus")
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .padding(.bottom, atTop ? 40 : (settings.dockCollapsed ? 80 : 150))
            }
            .scrollTargetLayout()
            .frame(minWidth: width)
            .padding(.top, atTop ? (settings.dockCollapsed ? 80 : 150) : 20)
        }
        .scrollDisabled(model.pencilDown && settings.palmRejection)
        .scrollPosition(id: $currentPageID)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? zoom
                    pinchBase = base
                    zoom = min(max(base * value.magnification, 1), 4)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .overlay(alignment: .topTrailing) {
            if zoom > 1.01 {
                Button { withAnimation(.snappy) { zoom = 1 } } label: {
                    Label("\(Int((zoom * 100).rounded()))%", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(12)
                .transition(.opacity)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ notebook: Node) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Back to library")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !notebook.isWhiteboard {
                Button { showPages.toggle() } label: {
                    Image(systemName: showPages ? "sidebar.left" : "square.stack")
                }
                .accessibilityLabel(showPages ? "Hide pages" : "Show pages")
            }
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("Redo")
            @Bindable var settings = settings
            Toggle(isOn: $settings.drawWithFinger) {
                Image(systemName: settings.drawWithFinger ? "hand.draw.fill" : "hand.draw")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Draw with finger")
            if notebook.isWhiteboard {
                Button { withAnimation(.snappy) { model.fitBoard() } } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .accessibilityLabel("Fit to drawing")
            } else {
                Button { showAddPage = true } label: { Image(systemName: "doc.badge.plus") }
                    .popover(isPresented: $showAddPage) {
                        AddPagePanel(startPaper: notebook.pages.last?.paper ?? .white) { t, paper in
                            store.addPage(to: notebookID, template: t, paper: paper)
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityLabel("Add page")
            }
            Menu {
                Button(notebook.isWhiteboard ? "Background…" : "Page style…", systemImage: "square.grid.3x3.square") { showStyle = true }
                Button("Design cover…", systemImage: "paintbrush.pointed") { showCover = true }
                Divider()
                Button("Export as PDF…", systemImage: "square.and.arrow.up") { export(notebook) }
                Divider()
                Button(settings.dockAtTop ? "Move pens to the bottom" : "Move pens to the top",
                       systemImage: settings.dockAtTop ? "arrow.down.to.line" : "arrow.up.to.line") {
                    withAnimation(.snappy) { settings.dockAtTop.toggle() }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
        }
    }

    // MARK: Export

    private var exportingOverlay: some View {
        ProgressView("Making PDF…")
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 18)
    }

    private func export(_ notebook: Node) {
        exporting = true
        Task { @MainActor in
            await Task.yield()
            if let url = NotebookExporter.exportPDF(notebook, store: store) {
                exportFile = ExportFile(url: url)
            } else {
                exportFailed = true
            }
            exporting = false
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ page: PageInfo, in notebook: Node, width: CGFloat) -> some View {
        ScaledPage(width: width, aspect: page.heightRatio) {
            ZStack {
                if let idx = page.pdfIndex, let file = notebook.pdfFile {
                    PDFPageBackground(file: file, index: idx, aspect: page.heightRatio)
                } else {
                    TemplateBackground(template: page.template, paper: page.paper)
                }
                InkCanvas(pageID: page.id, paper: page.paper, spec: model.spec,
                          policy: settings.drawingPolicy, store: store, model: model)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .id(page.id)
        .contextMenu {
            Button("Insert page after", systemImage: "plus.square.on.square") {
                store.addPage(to: notebookID, after: page.id)
            }
            Button("Delete page", systemImage: "trash", role: .destructive) {
                store.deletePage(page.id, in: notebookID)
            }
            .disabled(notebook.pages.count < 2)
        }
    }
}

struct PageStyleSheet: View {
    let notebook: Node
    let pageID: UUID?
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var template: PageTemplate = .lined
    @State private var paper: PaperColor = .white
    @State private var applyToAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TemplatePicker(template: $template, paper: $paper,
                                   templates: notebook.isWhiteboard ? PageTemplate.allCases.filter(\.suitsWhiteboard) : PageTemplate.allCases)
                        .padding(.vertical, 6)
                }
                if !notebook.isWhiteboard {
                    Section {
                        Toggle("Apply to every page in this notebook", isOn: $applyToAll)
                    }
                }
            }
            .navigationTitle(notebook.isWhiteboard ? "Whiteboard background" : "Page style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        store.setStyle(notebookID: notebook.id, pageID: applyToAll ? nil : pageID,
                                       template: template, paper: paper)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let page = notebook.pages.first(where: { $0.id == pageID }) ?? notebook.pages.first {
                    template = page.template
                    paper = page.paper
                }
            }
        }
    }
}
