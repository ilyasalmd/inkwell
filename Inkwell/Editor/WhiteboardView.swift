import SwiftUI
import PencilKit

/// Where the whiteboard is currently looking, in canvas points and zoom.
struct Viewport: Equatable {
    var offset: CGPoint = .zero
    var zoom: CGFloat = 1
}

/// A very large pannable, zoomable canvas. Ink is stored in canvas coordinates, so exporting can crop to what was drawn.
struct BoardCanvas: UIViewRepresentable {
    static let extent: CGFloat = 20000

    let pageID: UUID
    let inkStyle: UIUserInterfaceStyle
    let spec: ToolSpec
    let policy: PKCanvasViewDrawingPolicy
    let store: LibraryStore
    let model: EditorModel
    @Binding var viewport: Viewport

    func makeCoordinator() -> Coordinator { Coordinator(pageID: pageID, store: store, model: model, viewport: $viewport) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.contentSize = CGSize(width: Self.extent, height: Self.extent)
        v.minimumZoomScale = 0.15
        v.maximumZoomScale = 4
        v.contentInsetAdjustmentBehavior = .never
        v.showsHorizontalScrollIndicator = false
        v.showsVerticalScrollIndicator = false
        v.bounces = false
        v.drawing = store.drawing(for: pageID)
        context.coordinator.scribble = ScribbleWatcher(drawing: v.drawing)
        context.coordinator.snapper = ShapeSnapWatcher(drawing: v.drawing)
        v.delegate = context.coordinator
        model.activeCanvas = v
        model.boardCanvas = v
        apply(to: v)
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.viewport = $viewport
        if v.window != nil { PalmGuard.shared.register(v) }
        apply(to: v)
        if !context.coordinator.positioned, v.bounds.width > 0 {
            context.coordinator.positioned = true
            let target: CGPoint
            if v.drawing.strokes.isEmpty {
                target = CGPoint(x: Self.extent / 2, y: Self.extent / 2)
            } else {
                target = CGPoint(x: v.drawing.bounds.midX, y: v.drawing.bounds.midY)
            }
            v.contentOffset = CGPoint(x: target.x - v.bounds.width / 2, y: target.y - v.bounds.height / 2)
        }
    }

    private func apply(to v: PKCanvasView) {
        v.overrideUserInterfaceStyle = inkStyle
        v.drawingPolicy = policy
        v.tool = spec.makeTool(for: inkStyle)
        v.keepMenusForPencil(policy == .pencilOnly)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let pageID: UUID
        let store: LibraryStore
        let model: EditorModel
        var viewport: Binding<Viewport>
        var positioned = false
        var scribble: ScribbleWatcher?
        var snapper: ShapeSnapWatcher?

        init(pageID: UUID, store: LibraryStore, model: EditorModel, viewport: Binding<Viewport>) {
            self.pageID = pageID
            self.store = store
            self.model = model
            self.viewport = viewport
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
            PalmGuard.shared.pencilBegan()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            PalmGuard.shared.pencilEnded()
        }

        func scrollViewDidScroll(_ s: UIScrollView) { publish(s) }
        func scrollViewDidZoom(_ s: UIScrollView) { publish(s) }

        private func publish(_ s: UIScrollView) {
            let next = Viewport(offset: s.contentOffset, zoom: s.zoomScale)
            guard next != viewport.wrappedValue else { return }
            DispatchQueue.main.async { self.viewport.wrappedValue = next }
        }
    }
}

/// The template lines for the whiteboard, drawn in screen space so they follow panning and zooming.
struct BoardGrid: View {
    let template: PageTemplate
    let paper: PaperColor
    let viewport: Viewport

    var body: some View {
        Canvas { ctx, size in
            let z = viewport.zoom
            let line = paper.lineColor
            func start(_ offset: CGFloat, _ step: CGFloat) -> CGFloat { -(offset.truncatingRemainder(dividingBy: step)) - (offset < 0 ? step : 0) }

            switch template {
            case .lined:
                let step = 46 * z
                guard step > 7 else { return }
                var y = start(viewport.offset.y, step)
                while y < size.height { stroke(&ctx, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y), color: line, width: max(1, 1.4 * z)); y += step }
            case .squared:
                let step = 40 * z
                guard step > 7 else { return }
                var x = start(viewport.offset.x, step)
                while x < size.width { stroke(&ctx, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height), color: line, width: max(1, 1.2 * z)); x += step }
                var y = start(viewport.offset.y, step)
                while y < size.height { stroke(&ctx, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y), color: line, width: max(1, 1.2 * z)); y += step }
            case .dotted:
                let step = 40 * z
                guard step > 8 else { return }
                let r = max(1.1, 2.2 * z)
                var y = start(viewport.offset.y, step)
                while y < size.height {
                    var x = start(viewport.offset.x, step)
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(line.opacity(1.6)))
                        x += step
                    }
                    y += step
                }
            default:
                break
            }
        }
        .background(paper.color)
        .accessibilityHidden(true)
    }

    private func stroke(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint, color: Color, width: CGFloat) {
        var p = Path()
        p.move(to: a)
        p.addLine(to: b)
        ctx.stroke(p, with: .color(color), lineWidth: width)
    }
}

struct WhiteboardView: View {
    let page: PageInfo
    @Bindable var model: EditorModel
    @Environment(LibraryStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var viewport = Viewport()

    var body: some View {
        ZStack {
            BoardGrid(template: page.template, paper: page.paper, viewport: viewport)
            BoardCanvas(pageID: page.id, inkStyle: page.inkStyle, spec: model.spec,
                        policy: settings.drawingPolicy, store: store, model: model,
                        viewport: $viewport)
        }
        .clipped()
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottomTrailing) { zoomBadge }
    }

    private var zoomBadge: some View {
        Button { withAnimation(.snappy) { model.fitBoard() } } label: {
            Label("\(Int((viewport.zoom * 100).rounded()))%", systemImage: "scope")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(16)
        .padding(.bottom, 4)
        .accessibilityLabel("Zoom \(Int((viewport.zoom * 100).rounded())) percent. Fit to drawing")
    }
}
