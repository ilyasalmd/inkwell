import SwiftUI
import UIKit
import PencilKit

/// How eagerly finger contacts on the page are treated as a resting hand (like Goodnotes' sensitivity setting).
enum PalmSensitivity: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// One per app, attached to the window. It only looks at touches that start on the pages (never the toolbar, pen tray
/// or buttons) and decides when one is a hand rather than a finger:
/// - a wide contact: a palm, the side of the hand or a forearm;
/// - (Medium and High) a finger landing on your writing-hand side of the Pencil while you write, or just before or
///   after (the Pencil hovering counts), so the hand that holds the Pencil can't scroll the page;
/// - (High) any finger on the page while the Pencil is in use.
/// A hand touch can't scroll, zoom or tap anything on the page, and if it nudged the page before it was recognised the
/// page is put back. Fingers of your other hand, and every touch outside the pages, behave normally.
/// The Pencil's own touches are never taken, so writing is never interrupted.
final class PalmGuard: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let shared = PalmGuard()

    /// iPads report contact size in steps of about 10 points: fingertips read about 21 or 31, palms 52 and up.
    private static let wideContact: CGFloat = 48
    private static let mediumContact: CGFloat = 38
    /// How long after the Pencil touched or hovered the writing-hand area stays guarded.
    private static let penLinger: TimeInterval = 0.4
    /// A hand touch recognised this soon after it landed has any scroll it caused undone.
    private static let revertWindow: TimeInterval = 0.6

    /// Editors switch the guard on while they're on screen (and palm rejection is on in Settings).
    var isActive = false { didSet { if !isActive { clear() } } }
    var sensitivity: PalmSensitivity = .medium
    var leftHanded = false
    var onPencil: (() -> Void)?

    private let scrollViews = NSHashTable<UIScrollView>.weakObjects()
    private var fingers = Set<ObjectIdentifier>()
    private var palms = Set<ObjectIdentifier>()
    private var firstFingerAt = Date.distantPast
    private var savedOffsets: [(UIScrollView, CGPoint)] = []
    private var pencilTouching = false
    private var penSeenAt = Date.distantPast
    private var penPoint: CGPoint?
    private weak var hover: UIHoverGestureRecognizer?

    private init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true      // once a touch is judged a hand, page buttons under it never fire
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    // MARK: Wiring

    /// Moves the guard (and its Pencil-hover watcher) onto `window` if it isn't there already.
    func install(in window: UIWindow?) {
        guard let window, view !== window else { return }
        view?.removeGestureRecognizer(self)
        window.addGestureRecognizer(self)
        #if !targetEnvironment(macCatalyst)
        if let hover { hover.view?.removeGestureRecognizer(hover) }
        let h = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        h.delegate = self
        h.cancelsTouchesInView = false
        window.addGestureRecognizer(h)
        hover = h
        #endif
    }

    /// The scroll views that hold pages. Only touches that start inside one are ever judged.
    func register(_ sv: UIScrollView) {
        scrollViews.add(sv)
        install(in: sv.window)
    }

    /// The canvases report when drawing starts and stops.
    func pencilBegan() {
        pencilTouching = true
        penSeenAt = Date()
    }

    func pencilEnded() {
        pencilTouching = false
        penSeenAt = Date()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        // zOffset is only above 0 for the Pencil, not a trackpad pointer. Hovering never blocks anything by itself;
        // it only tells us where the writing hand is about to land.
        guard isActive, g.zOffset > 0, let window = view else { return }
        penPoint = g.location(in: window)
        penSeenAt = Date()
    }

    // MARK: Touches

    private var penActive: Bool { pencilTouching || Date().timeIntervalSince(penSeenAt) < Self.penLinger }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else {
            touches.forEach { ignore($0, for: event) }
            return
        }
        for t in touches {
            if t.type == .pencil {
                // Never take the Pencil's touch; just note where it is.
                if let window = view { penPoint = t.location(in: window) }
                penSeenAt = Date()
                onPencil?()
                ignore(t, for: event)
                continue
            }
            guard t.type == .direct, isOnPage(t.view) else {
                ignore(t, for: event)       // toolbar, pen tray, sheets: never interfere
                continue
            }
            let id = ObjectIdentifier(t)
            if fingers.isEmpty {
                firstFingerAt = Date()
                savedOffsets = scrollViews.allObjects.map { ($0, $0.contentOffset) }
            }
            fingers.insert(id)
            if isHand(t, landing: true) { palms.insert(id) }
        }
        if penActive, sensitivity != .low, fingers.count >= 3 { palms.formUnion(fingers) }
        guard !fingers.isEmpty else { return }
        evaluate()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else { return }
        // A palm often lands as a small contact and spreads out as the hand settles.
        for t in touches where fingers.contains(ObjectIdentifier(t)) && isHand(t, landing: false) {
            palms.insert(ObjectIdentifier(t))
        }
        evaluate()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    /// Whether this finger contact is part of the writing hand.
    private func isHand(_ t: UITouch, landing: Bool) -> Bool {
        let r = t.majorRadius
        if r >= Self.wideContact { return true }
        guard landing, penActive else { return false }
        switch sensitivity {
        case .low:
            return false
        case .medium:
            return r >= Self.mediumContact || inWritingHandZone(t)
        case .high:
            return true
        }
    }

    /// The area your hand covers while you write: beside and below the Pencil on your writing side.
    private func inWritingHandZone(_ t: UITouch) -> Bool {
        guard let pen = penPoint, let window = view else { return false }
        let p = t.location(in: window)
        let dx = leftHanded ? pen.x - p.x : p.x - pen.x
        let dy = p.y - pen.y
        return dx > -60 && dx < 520 && dy > -220 && dy < 700
    }

    private func finish(_ touches: Set<UITouch>) {
        for t in touches {
            fingers.remove(ObjectIdentifier(t))
            palms.remove(ObjectIdentifier(t))
        }
        if fingers.isEmpty {
            state = (state == .possible) ? .failed : .ended
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    private func evaluate() {
        if !palms.isEmpty, state == .possible {
            if Date().timeIntervalSince(firstFingerAt) < Self.revertWindow {
                // The hand landed and dragged the page a little before we knew: put it back.
                for (sv, offset) in savedOffsets where sv.window != nil && sv.contentOffset != offset {
                    sv.setContentOffset(offset, animated: false)
                }
            }
            state = .began        // cancels the page's scrolling, zooming and taps for these touches
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func reset() {
        super.reset()
        fingers.removeAll()
        palms.removeAll()
    }

    private func clear() {
        fingers.removeAll()
        palms.removeAll()
        pencilTouching = false
        penSeenAt = .distantPast
        penPoint = nil
    }

    private func isOnPage(_ view: UIView?) -> Bool {
        var v = view
        while let current = v {
            if let sv = current as? UIScrollView, scrollViews.contains(sv) { return true }
            if current is PKCanvasView { return true }
            v = current.superview
        }
        return false
    }

    // MARK: Who can be stopped

    /// Only what lives on the pages (scrolling, zooming, page buttons). Never PencilKit's drawing, never the toolbar.
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
        if other is UIHoverGestureRecognizer { return false }
        if let sv = other.view as? UIScrollView, scrollViews.contains(sv),
           other === sv.panGestureRecognizer || other === sv.pinchGestureRecognizer {
            return true
        }
        return isOnPage(other.view) && !Self.isInsideCanvas(other.view)
    }

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g !== self || !canPrevent(other)
    }

    private static func isInsideCanvas(_ view: UIView?) -> Bool {
        var v = view
        while let current = v {
            if current is PKCanvasView { return true }
            v = current.superview
        }
        return false
    }
}

extension PKCanvasView {
    /// PencilKit shows a "Select All / Insert Space" menu when the page is tapped or long-pressed, and a resting palm
    /// counts as both. When only the Pencil draws, its tap and long-press gestures are limited to the Pencil, so fingers
    /// and palms can't open that menu. (Lasso selections still work with the Pencil.)
    func keepMenusForPencil(_ on: Bool) {
        let pencil = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        func walk(_ v: UIView) {
            if String(describing: type(of: v)).contains("Selection") {
                for g in v.gestureRecognizers ?? [] where g is UITapGestureRecognizer || g is UILongPressGestureRecognizer
                    || String(describing: type(of: g)).contains("TapAndAHalf") {
                    if on {
                        g.allowedTouchTypes = pencil
                    }
                }
            }
            v.subviews.forEach(walk)
        }
        walk(self)
    }
}

/// Finds the UIScrollView behind a SwiftUI ScrollView so the editor can guard it and keep zoom anchored to the fingers.
@MainActor
final class PageScrollBridge {
    weak var scrollView: UIScrollView?

    func attach(_ sv: UIScrollView) {
        guard scrollView !== sv || sv.window != nil else { return }
        scrollView = sv
        PalmGuard.shared.register(sv)
    }

    /// The scroll offset right now, read before a zoom change so the anchor maths starts from where the user was.
    var offset: CGPoint { scrollView?.contentOffset ?? .zero }

    /// After the pages change from `oldPage` to `newPage` points wide, scrolls so the point that was under `anchor`
    /// (in the scroll view's visible area) stays under the fingers. `top` is the unscaled padding above the first page.
    /// Middle of the visible page area, in the same space SwiftUI gestures report.
    var visibleCentre: CGPoint {
        guard let sv = scrollView else { return .zero }
        let i = sv.adjustedContentInset
        return CGPoint(x: (sv.bounds.width - i.left - i.right) / 2, y: (sv.bounds.height - i.top - i.bottom) / 2)
    }

    func keepAnchored(from before: CGPoint, oldPage: CGFloat, newPage: CGFloat, anchor: CGPoint, top: CGFloat) {
        guard let sv = scrollView, oldPage > 0, abs(newPage - oldPage) > 0.01 else { return }
        sv.superview?.layoutIfNeeded()
        sv.layoutIfNeeded()
        let ratio = newPage / oldPage
        let viewW = sv.bounds.width, viewH = sv.bounds.height
        let inset = sv.adjustedContentInset
        // SwiftUI measures the fingers from below the toolbar; the scroll view's own space starts under it.
        let anchor = CGPoint(x: anchor.x + inset.left, y: anchor.y + inset.top)

        // Horizontal: pages are centred in content that is at least as wide as the screen.
        let oldLeft = (max(viewW, oldPage) - oldPage) / 2
        let newLeft = (max(viewW, newPage) - newPage) / 2
        let x = newLeft + (before.x + anchor.x - oldLeft) * ratio - anchor.x
        // Vertical: everything below the top padding scales with the zoom.
        let y = top + (before.y + anchor.y - top) * ratio - anchor.y

        let maxX = max(-inset.left, sv.contentSize.width - viewW + inset.right)
        let maxY = max(-inset.top, sv.contentSize.height - viewH + inset.bottom)
        sv.contentOffset = CGPoint(x: min(max(x, -inset.left), maxX), y: min(max(y, -inset.top), maxY))
    }
}

/// Invisible view placed inside the scroll content; hands its enclosing UIScrollView to the bridge.
struct ScrollViewProbe: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.found = found
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: ProbeView, context: Context) {
        v.found = found
        v.report()
    }

    final class ProbeView: UIView {
        var found: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            var v = superview
            while let current = v {
                if let sv = current as? UIScrollView { found?(sv); return }
                v = current.superview
            }
        }
    }
}
