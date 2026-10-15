import SwiftUI
import PencilKit

/// A notebook's pages in a UIKit zooming scroll view.
///
/// Pinching uses UIScrollView's own zoom, so iPadOS keeps the spot under your fingers fixed. When the pinch ends the
/// zoom is "baked": the scroll view goes back to scale 1 and everything is laid out again at the new real size, so
/// ink (PencilKit vectors), paper lines and PDF slides (tiled, drawn from the vector source) are re-rendered sharp at
/// screen resolution instead of being a stretched bitmap. Only pages near the screen are kept alive.
struct PagesView: UIViewRepresentable {
    let notebook: Node
    @Binding var currentPageID: UUID?
    let spec: ToolSpec
    let policy: PKCanvasViewDrawingPolicy
    let topInset: CGFloat
    let bottomInset: CGFloat
    let palmRejection: Bool
    /// Bumped by the zoom badge to go back to 100%.
    let resetZoom: Int
    let store: LibraryStore
    let model: EditorModel
    var onZoom: (CGFloat) -> Void
    var onAddPage: () -> Void
    /// Hold in the gap between two pages: insert a page at that position (0 is above the first page).
    var onInsertPage: (Int) -> Void

    func makeCoordinator() -> PagesController { PagesController(store: store, model: model) }

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.update(self)
        return context.coordinator.scrollView
    }

    func updateUIView(_ v: UIScrollView, context: Context) {
        context.coordinator.update(self)
    }
}

// MARK: - Controller

final class PagesController: NSObject, UIScrollViewDelegate {
    static let maxZoom: CGFloat = 6
    private static let pageGap: CGFloat = 28
    private static let buttonHeight: CGFloat = 44

    let scrollView = PagesScrollView()
    private let container = UIView()
    private let addButton = UIButton(type: .system)
    private let store: LibraryStore
    private let model: EditorModel

    private var config: PagesView?
    private var pages: [PageInfo] = []
    private var pdfURL: URL?
    private var pdfFile: String?
    /// Page frames at 100% zoom, in container coordinates.
    private var baseFrames: [CGRect] = []
    private var baseHeight: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    /// The zoom the pages are currently laid out at. The scroll view's own zoomScale is extra, live pinch on top.
    private var zoom: CGFloat = 1
    private var cells: [UUID: PageCell] = [:]
    private var shownPageID: UUID?
    private var restored = false
    private var baking = false
    private var settleLink: CADisplayLink?
    private var settleStart: CFTimeInterval = 0
    private var resetToken = 0

    init(store: LibraryStore, model: EditorModel) {
        self.store = store
        self.model = model
        super.init()
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.alwaysBounceVertical = true
        scrollView.bouncesZoom = true
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maxZoom
        scrollView.backgroundColor = .clear
        scrollView.addSubview(container)
        scrollView.onLayout = { [weak self] in self?.boundsChanged() }
        PalmGuard.shared.register(scrollView)

        var c = UIButton.Configuration.tinted()
        c.cornerStyle = .capsule
        c.image = UIImage(systemName: "plus")
        c.imagePadding = 6
        c.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        addButton.configuration = c
        addButton.accessibilityLabel = "Add page"
        addButton.addTarget(self, action: #selector(addTapped), for: .primaryActionTriggered)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(addHeld(_:)))
        hold.minimumPressDuration = 0.6
        addButton.addGestureRecognizer(hold)
        container.addSubview(addButton)

        let gapHold = UILongPressGestureRecognizer(target: self, action: #selector(gapHeld(_:)))
        gapHold.minimumPressDuration = 0.5
        gapHold.delegate = self
        scrollView.addGestureRecognizer(gapHold)
    }

    // MARK: Updates from SwiftUI

    func update(_ p: PagesView) {
        let old = config
        config = p

        scrollView.contentInset = UIEdgeInsets(top: p.topInset, left: 0, bottom: p.bottomInset, right: 0)
        // Drawing with a finger takes one finger, so scrolling then takes two (as in Goodnotes).
        scrollView.panGestureRecognizer.minimumNumberOfTouches = p.policy == .anyInput ? 2 : 1

        var title = AttributedString(p.palmRejection ? "Hold to add page" : "Add page")
        title.font = .preferredFont(forTextStyle: .body)
        addButton.configuration?.attributedTitle = title

        let newURL = p.notebook.pdfFile.map { store.storage.readImport($0) }
        if p.notebook.pages != pages || p.notebook.pdfFile != pdfFile {
            let changed = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
            pages = p.notebook.pages
            pdfFile = p.notebook.pdfFile
            pdfURL = newURL
            let ids = Set(pages.map(\.id))
            for (id, cell) in cells where !ids.contains(id) || changed[id] != pages.first(where: { $0.id == id })
                || cell.pdfURL != pdfURL {
                // Gone, or its paper/template/PDF changed: rebuild it next time it's on screen.
                cell.removeFromSuperview()
                cells[id] = nil
            }
            relayout(keepingPlace: true)
        }

        if old?.spec != p.spec || old?.policy != p.policy {
            for cell in cells.values { cell.apply(spec: p.spec, policy: p.policy) }
        }

        if p.resetZoom != resetToken {
            resetToken = p.resetZoom
            if old != nil { animateZoom(to: 1) }
        }

        if restored, let id = p.currentPageID, id != shownPageID {
            shownPageID = id
            scroll(to: id, animated: true)
        }
    }

    // MARK: Layout

    private func boundsChanged() {
        let w = scrollView.bounds.width
        guard w > 0, !baking else { return }
        if abs(w - laidOutWidth) > 0.5 {
            relayout(keepingPlace: restored)
            if !restored { restore() }
        }
        centreWhileZooming()
    }

    /// Lays the pages out for the current width and zoom. With `keepingPlace`, the page you were reading stays put.
    private func relayout(keepingPlace: Bool) {
        let w = scrollView.bounds.width
        guard w > 0, !scrollView.isZooming else { return }
        let place = keepingPlace && laidOutWidth > 0 ? readingPlace() : nil
        if scrollView.zoomScale != 1 { bake() }

        laidOutWidth = w
        let pageW = min(max(w - 48, 200), PageMetrics.width * 1.15)
        var y: CGFloat = 0
        baseFrames = pages.map { page in
            let h = (pageW * page.heightRatio).rounded()
            defer { y += h + Self.pageGap }
            return CGRect(x: ((w - pageW) / 2).rounded(), y: y, width: pageW, height: h)
        }
        baseHeight = y + Self.buttonHeight + 16
        applyLayout()
        if let place { restore(place) }
        updateVisible()
    }

    private func frame(_ i: Int) -> CGRect {
        let f = baseFrames[i]
        return CGRect(x: f.minX * zoom, y: f.minY * zoom, width: f.width * zoom, height: f.height * zoom)
    }

    private func applyLayout() {
        let size = CGSize(width: laidOutWidth * zoom, height: baseHeight * zoom)
        container.transform = .identity
        container.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        for (i, page) in pages.enumerated() {
            cells[page.id]?.setFrame(frame(i))
        }
        let lastBottom = baseFrames.last.map { $0.maxY + Self.pageGap } ?? 0
        addButton.sizeToFit()
        addButton.center = CGPoint(x: size.width / 2, y: (lastBottom + Self.buttonHeight / 2) * zoom)
    }

    /// The visible area in container coordinates (includes live pinch).
    private var visibleRect: CGRect { scrollView.convert(scrollView.bounds, to: container) }

    /// Mounts pages near the screen, drops far ones, and moves each live canvas to cover what you can see.
    private func updateVisible() {
        guard laidOutWidth > 0, let config else { return }
        let vis = visibleRect
        let mountZone = vis.insetBy(dx: -vis.width * 0.5, dy: -vis.height * 0.75)
        let keepZone = vis.insetBy(dx: -vis.width, dy: -vis.height * 1.5)
        let zooming = scrollView.isZooming || scrollView.isZoomBouncing
        for (i, page) in pages.enumerated() {
            let f = frame(i)
            if let cell = cells[page.id] {
                if !f.intersects(keepZone) {
                    cell.removeFromSuperview()
                    cells[page.id] = nil
                } else if !zooming {
                    cell.fitCanvas(to: container.convert(vis, to: cell))
                }
            } else if f.intersects(mountZone) {
                let cell = PageCell(page: page, pdfURL: pdfURL, store: store, model: model)
                cell.setFrame(f)
                cell.apply(spec: config.spec, policy: config.policy)
                container.insertSubview(cell, belowSubview: addButton)
                cells[page.id] = cell
                cell.fitCanvas(to: container.convert(vis, to: cell))
                if zooming { cell.prepareForZoom() }
            }
        }
    }

    // MARK: Current page

    private func trackCurrentPage() {
        guard restored, !pages.isEmpty, let config else { return }
        let vis = visibleRect
        let probe = vis.minY + vis.height * 0.3
        let s = zoom * scrollView.zoomScale
        var index = pages.count - 1
        for (i, f) in baseFrames.enumerated() where probe < (f.maxY + Self.pageGap) * s {
            index = i
            break
        }
        let id = pages[index].id
        guard id != shownPageID else { return }
        shownPageID = id
        if config.currentPageID != id { config.currentPageID = id }
    }

    private func scroll(to id: UUID, animated: Bool) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let y = frame(i).minY - scrollView.contentInset.top
        let maxY = max(-scrollView.contentInset.top,
                       scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(max(y, -scrollView.contentInset.top), maxY)),
                                    animated: animated)
    }

    /// Opens the notebook on the page you were last on.
    private func restore() {
        guard let config else { return }
        let last = LastPage.get(config.notebook.id).flatMap { id in pages.contains { $0.id == id } ? id : nil }
        if let target = config.currentPageID ?? last {
            shownPageID = target
            if config.currentPageID != target { config.currentPageID = target }
            scroll(to: target, animated: false)
        }
        restored = true
        updateVisible()
        if shownPageID == nil { trackCurrentPage() }
    }

    private struct Place { var index: Int; var fraction: CGFloat; var x: CGFloat }

    private func readingPlace() -> Place? {
        guard !baseFrames.isEmpty else { return nil }
        let vis = visibleRect
        let y = vis.minY + scrollView.contentInset.top
        let i = (0..<pages.count).first { y < frame($0).maxY + Self.pageGap * zoom } ?? pages.count - 1
        let f = frame(i)
        let width = max(container.frame.width, 1)
        return Place(index: i, fraction: (y - f.minY) / max(f.height, 1), x: scrollView.contentOffset.x / width)
    }

    private func restore(_ place: Place) {
        guard pages.indices.contains(place.index) else { return }
        let f = frame(place.index)
        let y = f.minY + place.fraction * f.height - scrollView.contentInset.top
        scrollView.contentOffset = clamped(CGPoint(x: place.x * container.frame.width, y: y))
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        let i = scrollView.contentInset
        let maxX = max(-i.left, scrollView.contentSize.width - scrollView.bounds.width + i.right)
        let maxY = max(-i.top, scrollView.contentSize.height - scrollView.bounds.height + i.bottom)
        return CGPoint(x: min(max(p.x, -i.left), maxX), y: min(max(p.y, -i.top), maxY))
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        settleLink?.invalidate()
        settleLink = nil
        for cell in cells.values { cell.prepareForZoom() }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !baking else { return }
        centreWhileZooming()
        updateVisible()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        bakeWhenSettled()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !baking else { return }
        if scrollView.isZooming || scrollView.isZoomBouncing { centreWhileZooming() }
        updateVisible()
        // Only your own scrolling changes the current page; layout passes (rotation, closing the notebook) and page
        // strip jumps move the offset too, and must not overwrite where you were.
        if scrollView.isDragging || scrollView.isDecelerating || scrollView.isZooming { trackCurrentPage() }
    }

    /// While a pinch takes the pages below 100%, keep them centred on screen instead of sliding sideways with the
    /// fingers (the pinch moves the scroll offset even when the pages are narrower than the screen).
    private func centreWhileZooming() {
        let w = container.frame.width, bw = scrollView.bounds.width
        let x = w < bw ? scrollView.contentOffset.x + bw / 2 : w / 2
        if abs(container.center.x - x) > 0.5 { container.center.x = x }
    }

    /// A pinch past 100% or 600% springs back after you let go. Folding the zoom into the layout before that spring
    /// has finished cuts it short and the page jumps, so wait for it.
    private func bakeWhenSettled() {
        settleLink?.invalidate()
        settleLink = nil
        guard !isSettled else { return bake() }
        settleStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(settleTick))
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    @objc private func settleTick() {
        guard isSettled || CACurrentMediaTime() - settleStart > 1 else { return }
        settleLink?.invalidate()
        settleLink = nil
        bake()
    }

    private var isSettled: Bool {
        !scrollView.isZooming && !scrollView.isZoomBouncing
            && (container.layer.animationKeys() ?? []).isEmpty && (scrollView.layer.animationKeys() ?? []).isEmpty
    }

    /// Folds the live pinch into the layout: same picture on screen, now rendered at the new size.
    private func bake() {
        let s = scrollView.zoomScale
        guard abs(s - 1) > 0.0001, laidOutWidth > 0 else { return }
        baking = true
        let offset = scrollView.contentOffset
        zoom = min(max(zoom * s, 1), Self.maxZoom)
        scrollView.minimumZoomScale = min(1, s)
        scrollView.maximumZoomScale = max(1, s)
        scrollView.zoomScale = 1
        applyLayout()
        scrollView.contentOffset = clamped(offset)
        scrollView.minimumZoomScale = 1 / zoom
        scrollView.maximumZoomScale = Self.maxZoom / zoom
        baking = false
        let vis = visibleRect
        for cell in cells.values { cell.didBake(visible: container.convert(vis, to: cell)) }
        updateVisible()
        trackCurrentPage()
        config?.onZoom(zoom)
    }

    private func animateZoom(to target: CGFloat) {
        guard abs(zoom * scrollView.zoomScale - target) > 0.001 else { return }
        for cell in cells.values { cell.prepareForZoom() }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.scrollView.setZoomScale(target / self.zoom, animated: false)
            self.centreWhileZooming()
        } completion: { _ in
            self.bake()
        }
    }

    // MARK: Add page

    @objc private func addTapped() {
        guard config?.palmRejection == false else { return }
        config?.onAddPage()
    }

    @objc private func addHeld(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, config?.palmRejection == true else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        config?.onAddPage()
    }

    @objc private func gapHeld(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let position = gapPosition(at: g.location(in: container)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        config?.onInsertPage(position)
    }

    /// Which gap between pages a point is in, as the position a new page would take there.
    fileprivate func gapPosition(at p: CGPoint) -> Int? {
        guard !pages.isEmpty, !baseFrames.isEmpty else { return nil }
        let first = frame(0)
        guard p.x > first.minX - 24, p.x < first.maxX + 24 else { return nil }
        for i in 0..<min(pages.count, baseFrames.count) {
            let top = i == 0 ? first.minY - Self.pageGap * zoom : frame(i - 1).maxY
            if p.y >= top, p.y < frame(i).minY { return i }
        }
        return nil
    }
}

extension PagesController: UIGestureRecognizerDelegate {
    /// The gap hold only starts between pages, so it never takes a touch from the ink.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        gapPosition(at: g.location(in: container)) != nil
    }
}

/// Reports layout passes so the controller can react to size changes (rotation, split view, side-by-side panes).
final class PagesScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Page

/// One page: shadowed card with a tiled background (paper or PDF) and a PencilKit canvas over the part you can see.
final class PageCell: UIView {
    let page: PageInfo
    let pdfURL: URL?
    private let store: LibraryStore
    private let model: EditorModel
    private let card = UIView()
    private let underlay = UIImageView()
    private let tiles: TiledPageView
    private let snapshot = UIImageView()
    private let snapshotMask = CAShapeLayer()
    private var canvas: PKCanvasView?
    private var delegateRef: InkCanvas.Coordinator?
    private var canvasRect: CGRect = .null
    private var snapshotJob = 0
    /// A still picture of the ink shown on top while PencilKit redraws after the canvas moved or changed scale.
    private var freeze: UIView?
    private var freezeJob = 0
    /// True from the start of a pinch until it is folded into the layout (the page picture is needed meanwhile).
    private var snapshotPending = false

    init(page: PageInfo, pdfURL: URL?, store: LibraryStore, model: EditorModel) {
        self.page = page
        self.pdfURL = page.pdfIndex == nil ? nil : pdfURL
        self.store = store
        self.model = model
        tiles = TiledPageView(art: PageArt(page: page, pdfURL: page.pdfIndex == nil ? nil : pdfURL))
        super.init(frame: .zero)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        card.layer.cornerRadius = 6
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.backgroundColor = page.pdfIndex == nil ? UIColor(hex: page.paper.hex) : .white
        addSubview(card)

        underlay.contentMode = .scaleToFill
        card.addSubview(underlay)
        // The paper is laid out once at its logical size and scaled to fit, so a zoom or resize only changes its
        // transform: tiles already drawn stay valid and nothing has to be redrawn when a pinch ends.
        tiles.bounds = CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio)
        card.addSubview(tiles)
        snapshot.contentMode = .scaleToFill
        snapshot.isHidden = true
        snapshotMask.fillRule = .evenOdd
        snapshot.layer.mask = snapshotMask
        card.addSubview(snapshot)
        loadUnderlay()
        attachCanvas()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFrame(_ f: CGRect) {
        guard frame != f else { return }
        let scale = bounds.width > 0 ? f.width / bounds.width : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bounds.width > 0 { freezeInk(scaledBy: scale) }
        frame = f
        let b = CGRect(origin: .zero, size: f.size)
        card.frame = b
        underlay.frame = b
        let s = f.width / PageMetrics.width
        tiles.transform = CGAffineTransform(scaleX: s, y: s)
        tiles.center = CGPoint(x: b.midX, y: b.midY)
        snapshot.frame = b
        snapshotMask.frame = b
        layer.shadowPath = UIBezierPath(roundedRect: b, cornerRadius: 6).cgPath
        CATransaction.commit()
        canvasRect = .null   // the canvas must be re-fitted at the new scale
    }

    // MARK: Canvas

    private func attachCanvas() {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.isScrollEnabled = false
        v.contentInsetAdjustmentBehavior = .never
        v.showsVerticalScrollIndicator = false
        v.showsHorizontalScrollIndicator = false
        v.overrideUserInterfaceStyle = page.inkStyle
        v.drawing = store.drawing(for: page.id)
        let d = InkCanvas.Coordinator(pageID: page.id, store: store, model: model)
        d.onRendered = { [weak self] in self?.thaw() }
        d.scribble = ScribbleWatcher(drawing: v.drawing)
        d.snapper = ShapeSnapWatcher(drawing: v.drawing)
        v.delegate = d
        delegateRef = d
        card.addSubview(v)
        canvas = v
    }

    func apply(spec: ToolSpec, policy: PKCanvasViewDrawingPolicy) {
        guard let v = canvas else { return }
        v.drawingPolicy = policy
        v.tool = spec.makeTool(for: page.inkStyle)
        v.keepMenusForPencil(policy == .pencilOnly)
        // PencilKit builds its selection gestures lazily; catch them once they exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak v] in v?.keepMenusForPencil(policy == .pencilOnly) }
    }

    /// Sizes the live canvas to the part of the page on or near the screen. A canvas the size of a whole page at
    /// 600% would be gigantic; ink is stored in 1000-point page coordinates and PencilKit's own zoom maps it to size.
    func fitCanvas(to visible: CGRect) {
        guard let v = canvas, bounds.width > 0 else { return }
        let page = bounds
        let needed = page.intersection(visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25))
        if !canvasRect.isNull, needed.isNull || canvasRect.contains(needed) { return }
        if delegateRef?.inUse == true { return }   // never move the canvas mid-stroke
        if !canvasRect.isNull { freezeInk(scaledBy: 1) }

        var target = page.intersection(visible.insetBy(dx: -visible.width, dy: -visible.height)).integral
        if target.isNull || target.isEmpty { target = CGRect(x: 0, y: 0, width: min(page.width, 1), height: min(page.height, 1)) }
        let scale = page.width / PageMetrics.width
        if abs(v.zoomScale - scale) > 0.0001 {
            v.minimumZoomScale = min(v.minimumZoomScale, scale)
            v.maximumZoomScale = max(v.maximumZoomScale, scale)
            v.zoomScale = scale
            v.minimumZoomScale = scale
            v.maximumZoomScale = scale
        }
        v.frame = target
        v.contentSize = page.size
        v.contentOffset = target.origin
        canvasRect = target
        updateSnapshotMask()
        if freeze != nil {
            freezeJob += 1
            let job = freezeJob
            // In case PencilKit has nothing new to draw and never reports finishing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                if self?.freezeJob == job { self?.thaw() }
            }
        }
    }

    /// Covers the live canvas with a still picture of its ink, scaled with the page, until PencilKit has redrawn.
    private func freezeInk(scaledBy scale: CGFloat) {
        if let freeze {
            // Already frozen (two changes in a row): keep the picture, just follow the page.
            let f = freeze.frame
            freeze.frame = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
            return
        }
        guard let v = canvas, !v.drawing.strokes.isEmpty, v.bounds.width > 0,
              let still = v.snapshotView(afterScreenUpdates: false) else { return }
        let f = v.frame
        still.frame = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
        still.isUserInteractionEnabled = false
        card.addSubview(still)
        freeze = still
    }

    /// PencilKit has redrawn the ink at its new size: drop the stand-ins.
    private func thaw() {
        guard let still = freeze else { return }
        freezeJob += 1
        freeze = nil
        still.removeFromSuperview()
        if snapshotPending == false {
            snapshot.isHidden = true
            snapshot.image = nil
        }
        updateSnapshotMask()
    }

    // MARK: Zoom support

    /// Ink outside the live canvas would vanish while zooming out, so show a picture of the page's ink there.
    func prepareForZoom() {
        snapshotPending = true
        guard let v = canvas, !canvasRect.contains(bounds) else { return }
        let drawing = v.drawing
        guard !drawing.strokes.isEmpty else { return }
        snapshotJob += 1
        let job = snapshotJob
        let rect = CGRect(x: 0, y: 0, width: PageMetrics.width, height: PageMetrics.width * page.heightRatio)
        let style: UIUserInterfaceStyle = v.overrideUserInterfaceStyle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                image = drawing.image(from: rect, scale: 1.5)
            }
            DispatchQueue.main.async {
                guard let self, self.snapshotJob == job else { return }
                self.snapshot.image = image
                self.snapshot.isHidden = false
                self.updateSnapshotMask()
            }
        }
    }

    func didBake(visible: CGRect) {
        fitCanvas(to: visible)
        snapshotJob += 1
        snapshotPending = false
        // Ink outside the old canvas is only in the page picture; keep it until the canvas has redrawn there.
        if freeze == nil {
            snapshot.isHidden = true
            snapshot.image = nil
        }
    }

    private func updateSnapshotMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath(rect: bounds)
        let hole = freeze?.frame ?? canvasRect
        if !hole.isNull { path.append(UIBezierPath(rect: hole)) }
        snapshotMask.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: Background

    /// A small picture of the page shown under the tiles, so nothing flashes blank while sharp tiles render.
    private func loadUnderlay() {
        if let idx = page.pdfIndex, let url = pdfURL {
            let file = url.lastPathComponent, aspect = page.heightRatio
            Task { @MainActor [weak self] in
                self?.underlay.image = await PDFPageCache.shared.image(file: file, index: idx, url: url, aspect: aspect)
            }
        } else {
            underlay.image = PageArt.underlay(for: page)
        }
    }
}

// MARK: - Tiled background

private final class InstantTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// Draws paper or a PDF page in tiles at whatever resolution the screen needs, including mid-pinch.
final class TiledPageView: UIView {
    private let art: PageArt

    override class var layerClass: AnyClass { InstantTiledLayer.self }

    init(art: PageArt) {
        self.art = art
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        let tiled = layer as! CATiledLayer
        tiled.tileSize = CGSize(width: 1024, height: 1024)
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 3   // up to 8× sharper while a pinch is still in progress
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ layer: CALayer, in ctx: CGContext) {
        let b = layer.bounds
        guard b.width > 0 else { return }
        let s = b.width / PageMetrics.width
        ctx.scaleBy(x: s, y: s)
        art.draw(in: ctx, size: CGSize(width: PageMetrics.width, height: b.height / s))
    }
}

/// Everything needed to draw a page background, safe to use from the tile-drawing threads.
struct PageArt: @unchecked Sendable {
    let template: PageTemplate
    let paper: CGColor
    let line: CGColor
    let dot: CGColor
    let accent: CGColor
    let pdf: CGPDFPage?
    private let doc: CGPDFDocument?   // keeps the page's document alive

    init(page: PageInfo, pdfURL: URL?) {
        template = page.template
        paper = UIColor(hex: page.paper.hex).cgColor
        let l = UIColor(page.paper.lineColor).cgColor
        line = l
        dot = l.copy(alpha: min(1, l.alpha * 1.6)) ?? l
        accent = UIColor(page.paper.accentLineColor).cgColor
        if let idx = page.pdfIndex, let url = pdfURL, let d = PDFDocuments.shared.document(url) {
            doc = d
            pdf = d.page(at: idx + 1)
        } else {
            doc = nil
            pdf = nil
        }
    }

    private static let underlays = NSCache<NSString, UIImage>()

    static func underlay(for page: PageInfo) -> UIImage {
        let key = "\(page.template.rawValue)-\(page.paper.rawValue)-\(page.heightRatio)" as NSString
        if let hit = underlays.object(forKey: key) { return hit }
        let art = PageArt(page: page, pdfURL: nil)
        let size = CGSize(width: 600, height: 600 * page.heightRatio)
        let image = UIGraphicsImageRenderer(size: size).image { r in
            let s = size.width / PageMetrics.width
            r.cgContext.scaleBy(x: s, y: s)
            art.draw(in: r.cgContext, size: CGSize(width: PageMetrics.width, height: PageMetrics.width * page.heightRatio))
        }
        underlays.setObject(image, forKey: key)
        return image
    }

    /// Draws in logical page coordinates (1000 wide).
    func draw(in ctx: CGContext, size: CGSize) {
        if let pdf {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            drawPDF(pdf, in: ctx, size: size)
            return
        }
        ctx.setFillColor(paper)
        ctx.fill(CGRect(origin: .zero, size: size))
        drawTemplate(in: ctx, w: size.width, h: size.height)
    }

    private func drawPDF(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        let box = page.getBoxRect(.cropBox)
        let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
        let turned = rot == 90 || rot == 270
        let pw = turned ? box.height : box.width
        let ph = turned ? box.width : box.height
        guard pw > 0, ph > 0 else { return }
        let s = size.width / pw
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: ph * s)
        ctx.scaleBy(x: s, y: -s)
        switch rot {
        case 90: ctx.translateBy(x: 0, y: ph); ctx.rotate(by: -.pi / 2)
        case 180: ctx.translateBy(x: pw, y: ph); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: pw, y: 0); ctx.rotate(by: .pi / 2)
        default: break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    private func drawTemplate(in ctx: CGContext, w: CGFloat, h: CGFloat) {
        func stroke(_ a: CGPoint, _ b: CGPoint, _ color: CGColor, _ width: CGFloat) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        }
        func hLine(_ y: CGFloat, from x0: CGFloat = 0, to x1: CGFloat? = nil, color: CGColor? = nil, width: CGFloat = 1.5) {
            stroke(CGPoint(x: x0, y: y), CGPoint(x: x1 ?? w, y: y), color ?? line, width)
        }
        func vLine(_ x: CGFloat, from y0: CGFloat = 0, to y1: CGFloat? = nil, color: CGColor? = nil, width: CGFloat = 1.5) {
            stroke(CGPoint(x: x, y: y0), CGPoint(x: x, y: y1 ?? h), color ?? line, width)
        }
        func lined(in rect: CGRect, spacing: CGFloat = 46) {
            var y = rect.minY + spacing
            while y < rect.maxY - 2 {
                hLine(y, from: rect.minX, to: rect.maxX)
                y += spacing
            }
        }
        func grid(in rect: CGRect, spacing: CGFloat = 40) {
            var x = rect.minX
            while x <= rect.maxX + 0.5 { vLine(x, from: rect.minY, to: rect.maxY, width: 1.2); x += spacing }
            var y = rect.minY
            while y <= rect.maxY + 0.5 { hLine(y, from: rect.minX, to: rect.maxX, width: 1.2); y += spacing }
        }
        func dots(in rect: CGRect, spacing: CGFloat = 40) {
            ctx.setFillColor(dot)
            var y = rect.minY + spacing
            while y < rect.maxY {
                var x = rect.minX + spacing
                while x < rect.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4))
                    x += spacing
                }
                y += spacing
            }
        }

        switch template {
        case .blank:
            break
        case .lined:
            lined(in: CGRect(x: 0, y: 70, width: w, height: h - 70))
            vLine(110, color: accent)
        case .squared:
            grid(in: CGRect(x: 20, y: 20, width: w - 40, height: h - 40))
        case .dotted:
            dots(in: CGRect(x: 0, y: 0, width: w, height: h))
        case .cornell, .cornellGrid:
            let header: CGFloat = 150, summary: CGFloat = 250, cue: CGFloat = 280
            let bodyBottom = h - summary
            hLine(header, color: accent, width: 2)
            hLine(bodyBottom, color: accent, width: 2)
            vLine(cue, from: header, to: bodyBottom, color: accent, width: 2)
            if template == .cornell {
                lined(in: CGRect(x: cue, y: header, width: w - cue, height: bodyBottom - header))
                lined(in: CGRect(x: 0, y: bodyBottom, width: w, height: summary))
            } else {
                grid(in: CGRect(x: cue, y: header, width: w - cue, height: bodyBottom - header))
            }
        }
    }
}

/// Open PDF documents for tile drawing, shared across pages. CGPDFDocument is safe to draw from several threads.
final class PDFDocuments: @unchecked Sendable {
    static let shared = PDFDocuments()
    private let lock = NSLock()
    private var docs: [URL: CGPDFDocument] = [:]

    func document(_ url: URL) -> CGPDFDocument? {
        lock.lock()
        defer { lock.unlock() }
        if let d = docs[url] { return d }
        guard let d = CGPDFDocument(url as CFURL) else { return nil }
        docs[url] = d
        return d
    }
}
