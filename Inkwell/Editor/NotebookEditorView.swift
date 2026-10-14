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
        context.coordinator.snapper = ShapeSnapWatcher(drawing: v.drawing)
        v.delegate = context.coordinator
        apply(to: v)
        // PencilKit builds its selection gestures lazily; catch them once they exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [policy] in v.keepMenusForPencil(policy == .pencilOnly) }
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: PKCanvasView) {
        v.overrideUserInterfaceStyle = paper.isDark ? .dark : .light
        v.drawingPolicy = policy
        v.tool = spec.makeTool()
        v.keepMenusForPencil(policy == .pencilOnly)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let pageID: UUID
        let store: LibraryStore
        let model: EditorModel
        var scribble: ScribbleWatcher?
        var snapper: ShapeSnapWatcher?

        init(pageID: UUID, store: LibraryStore, model: EditorModel) {
            self.pageID = pageID
            self.store = store
            self.model = model
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if snapper?.didChange(canvasView, enabled: model.shapeSnap, haptic: { [model] in model.haptic?(nil) },
                                  save: { [store, pageID] in store.saveDrawing($0, pageID: pageID) }) == true {
                return   // the snapped shape triggers its own change
            }
            store.saveDrawing(canvasView.drawing, pageID: pageID)
            let id = pageID, store = store
            scribble?.didChange(canvasView, enabled: model.scribbleErase, haptic: { [model] in model.haptic?(nil) },
                                save: { store.saveDrawing($0, pageID: id) })
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            model.activeCanvas = canvasView
            model.pencilBegan()
            PalmGuard.shared.pencilBegan()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            model.pencilEnded()
            PalmGuard.shared.pencilEnded()
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
    @State private var sideID: UUID?
    @State private var sidePageID: UUID?
    @State private var pickSide = false
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
        .sheet(isPresented: $pickSide) {
            OpenNotebookSheet(excluding: [notebookID]) { id in
                sidePageID = nil
                sideID = id
            }
        }
        // A palm at the screen edge shouldn't pull up the Dock, app switcher or Control Centre mid-sentence.
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            tabs.add(notebookID)
            updatePalmGuard()
            PalmGuard.shared.listen(model) { [weak model] blocked in model?.touchBlocked = blocked }
        }
        .onChange(of: settings.palmRejection) { _, _ in updatePalmGuard() }
        .onChange(of: settings.drawWithFinger) { _, _ in updatePalmGuard() }
        .onDisappear {
            PalmGuard.shared.isActive = false
            model.touchBlocked = false
            store.touch(notebookID)
            if let sideID { store.touch(sideID) }
        }
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
            HStack(spacing: 0) {
                NotebookPane(notebookID: notebookID, currentPageID: $currentPageID)
                if let sideID, store.node(sideID) != nil {
                    Divider()
                    VStack(spacing: 0) {
                        sideHeader(sideID)
                        NotebookPane(notebookID: sideID, currentPageID: $sidePageID)
                    }
                    .id(sideID)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy, value: sideID)
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

    /// Name of the notebook open on the right, with buttons to swap it for another or close it.
    private func sideHeader(_ id: UUID) -> some View {
        let node = store.node(id)
        return HStack(spacing: 10) {
            Image(systemName: node?.isWhiteboard == true ? "rectangle.and.pencil.and.ellipsis" : "book.closed.fill")
                .foregroundStyle(node?.displayColor ?? .accentColor)
            Text(node?.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Button { pickSide = true } label: { Image(systemName: "arrow.left.arrow.right") }
                .accessibilityLabel("Open a different notebook here")
            Button { store.touch(id); sideID = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Close side-by-side notebook")
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).frame(height: 40)
        .background(.bar, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }

    private func updatePalmGuard() {
        let guardian = PalmGuard.shared
        guardian.pencilOnly = settings.drawingPolicy == .pencilOnly
        guardian.onPencil = { [settings] in settings.pencilDetected() }
        guardian.isActive = settings.palmRejection
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
            Button {
                if sideID == nil { pickSide = true } else { withAnimation(.snappy) { sideID = nil } }
            } label: {
                Image(systemName: sideID == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
            }
            .accessibilityLabel(sideID == nil ? "Open a notebook side by side" : "Close side by side")
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
}

// MARK: - Pane

/// One notebook's pages in a scroll view with pinch zoom. The editor shows one, or two side by side.
struct NotebookPane: View {
    let notebookID: UUID
    @Binding var currentPageID: UUID?

    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(EditorModel.self) private var model
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var bridge = PageScrollBridge()

    var body: some View {
        if let notebook = store.node(notebookID) {
            Group {
                if notebook.isWhiteboard, let page = notebook.pages.first {
                    WhiteboardView(page: page, model: model)
                } else {
                    GeometryReader { geo in pagesScroll(notebook, width: geo.size.width) }
                }
            }
            .onAppear {
                if currentPageID == nil, let id = LastPage.get(notebookID), notebook.pages.contains(where: { $0.id == id }) {
                    currentPageID = id
                }
            }
            .onChange(of: currentPageID) { _, id in
                if let id { LastPage.set(id, in: notebookID) }
            }
        } else {
            ContentUnavailableView("Notebook not found", systemImage: "book.closed")
        }
    }

    /// True while a palm is resting or the Pencil is in use, so fingers shouldn't scroll, zoom or press things.
    private var touchBlocked: Bool { settings.palmRejection && (model.pencilDown || model.touchBlocked) }

    private func pagesScroll(_ notebook: Node, width: CGFloat) -> some View {
        let available = max(width - 48, 200)
        let baseWidth = min(available, PageMetrics.width * 1.15)
        let pageWidth = baseWidth * zoom
        let atTop = settings.dockAtTop
        let topPadding: CGFloat = atTop ? (settings.dockCollapsed ? 80 : 150) : 20
        return ScrollView(zoom > 1.01 ? [.vertical, .horizontal] : .vertical) {
            LazyVStack(spacing: 28 * zoom) {
                ForEach(notebook.pages) { page in
                    pageView(page, in: notebook, width: pageWidth)
                }
                addPageButton
                    .allowsHitTesting(!touchBlocked)
                .padding(.bottom, atTop ? 40 : (settings.dockCollapsed ? 80 : 150))
            }
            .scrollTargetLayout()
            .frame(minWidth: width)
            .padding(.top, topPadding)
            .background(ScrollViewProbe { sv in bridge.attach(sv) })
        }
        .scrollDisabled(touchBlocked)
        .scrollPosition(id: $currentPageID)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    guard !touchBlocked else { return }
                    let base = pinchBase ?? zoom
                    pinchBase = base
                    setZoom(min(max(base * value.magnification, 1), 4), base: baseWidth,
                            anchor: value.startLocation, top: topPadding)
                }
                .onEnded { _ in pinchBase = nil }
        )
        .overlay(alignment: .topTrailing) {
            if zoom > 1.01 {
                Button {
                    setZoom(1, base: baseWidth, anchor: bridge.visibleCentre, top: topPadding)
                } label: {
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

    /// Changes the zoom and scrolls so the spot between your fingers stays put.
    private func setZoom(_ new: CGFloat, base: CGFloat, anchor: CGPoint, top: CGFloat) {
        let old = zoom
        guard abs(new - old) > 0.001 else { return }
        zoom = new
        DispatchQueue.main.async {
            bridge.keepAnchored(oldPage: base * old, newPage: base * new, anchor: anchor, top: top)
        }
    }

    /// With palm rejection on, adding a page from the bottom of the notebook takes a deliberate press-and-hold,
    /// so a resting palm can't trigger it.
    private var addPageButton: some View {
        let add = { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { store.addPage(to: notebookID) } }
        let label = Label(settings.palmRejection ? "Hold to add page" : "Add page", systemImage: "plus")
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
        return Group {
            if settings.palmRejection {
                label.contentShape(Capsule()).onLongPressGesture(minimumDuration: 0.6) { add() }
            } else {
                Button(action: add) { label }
            }
        }
        .accessibilityLabel("Add page")
        .accessibilityAddTraits(.isButton)
    }

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
