import SwiftUI
import UIKit
import PencilKit

/// One per app, attached to the window, so it sees every touch: on the page, the pen tray, the toolbar and the page
/// list. It decides when a touch is a hand rather than a finger, and swallows it:
/// - a wide contact (a palm, the side of the hand, a forearm), or three or more fingers down at once;
/// - any finger touch while the Pencil is writing, hovering just above the glass, or has just lifted (Pencil-only mode).
/// Swallowed touches are cancelled before buttons act on them, and scroll views stop scrolling or zooming. If a palm
/// landed first and nudged the page before the Pencil touched down, the page is put back where it was.
/// The Pencil's own touches are never taken, so writing is never interrupted.
final class PalmGuard: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static let shared = PalmGuard()

    /// Contacts wider than this (in points) are treated as a palm or the side of a hand. Fingertips are well under it.
    static let palmRadius: CGFloat = 30
    /// After the Pencil lifts, finger touches that start within this window are treated as the hand settling.
    static let afterPencil: TimeInterval = 0.5
    /// A palm that lands this soon before the Pencil (and is still down) has its scroll undone.
    static let revertWindow: TimeInterval = 0.9

    /// Editors switch the guard on while they're on screen (and palm rejection is on in Settings).
    var isActive = false { didSet { if !isActive { clear() } } }
    /// Only the Pencil draws, so any finger touch near Pencil use can safely be ignored.
    var pencilOnly = true
    var onPencil: (() -> Void)?

    private let scrollViews = NSHashTable<UIScrollView>.weakObjects()
    private var listeners: [ObjectIdentifier: (Bool) -> Void] = [:]
    private var fingers = Set<ObjectIdentifier>()
    private var palms = Set<ObjectIdentifier>()
    private var firstFingerAt = Date.distantPast
    private var savedOffsets: [(UIScrollView, CGPoint)] = []
    private var pencilTouching = false
    private var pencilHotUntil = Date.distantPast
    private var settle: Timer?
    private(set) var blocked = false
    private weak var hover: UIHoverGestureRecognizer?

    private init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = true      // once a touch is judged a hand, buttons under it never fire
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
        window.addGestureRecognizer(h)
        hover = h
        #endif
    }

    /// Scroll views whose pan and pinch are switched off while a hand is down or the Pencil is in use.
    func register(_ sv: UIScrollView) {
        scrollViews.add(sv)
        install(in: sv.window)
        if blocked { setScroll(sv, enabled: false) }
    }

    /// Called with true/false whenever finger input starts or stops being ignored.
    func listen(_ owner: AnyObject, _ change: @escaping (Bool) -> Void) {
        listeners[ObjectIdentifier(owner)] = change
    }

    func stopListening(_ owner: AnyObject) { listeners[ObjectIdentifier(owner)] = nil }

    /// The canvases report when drawing starts and stops (the Pencil, or a finger when finger drawing is on).
    func pencilBegan() {
        guard isActive else { return }
        pencilTouching = true
        refresh()
    }

    func pencilEnded() {
        pencilTouching = false
        pencilHotUntil = Date().addingTimeInterval(Self.afterPencil)
        refresh()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        // zOffset is only above 0 for the Pencil, not a trackpad pointer.
        guard isActive, g.zOffset > 0 else { return }
        pencilHotUntil = max(pencilHotUntil, Date().addingTimeInterval(0.6))
        refresh()
    }

    // MARK: Touches

    private var pencilHot: Bool { pencilTouching || Date() < pencilHotUntil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else {
            touches.forEach { ignore($0, for: event) }
            return
        }
        for t in touches {
            if t.type == .pencil {
                // Never take the Pencil's touch; just note that it's here.
                pencilHotUntil = max(pencilHotUntil, Date().addingTimeInterval(Self.afterPencil))
                onPencil?()
                ignore(t, for: event)
                continue
            }
            let id = ObjectIdentifier(t)
            if fingers.isEmpty {
                firstFingerAt = Date()
                savedOffsets = scrollViews.allObjects.map { ($0, $0.contentOffset) }
            }
            fingers.insert(id)
            if t.majorRadius > Self.palmRadius || (pencilOnly && pencilHot) { palms.insert(id) }
        }
        if fingers.count >= 3 { palms.formUnion(fingers) }
        evaluate()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else { return }
        // A palm often lands as a small contact and spreads out as the hand settles.
        for t in touches where t.type != .pencil && t.majorRadius > Self.palmRadius {
            palms.insert(ObjectIdentifier(t))
        }
        evaluate()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

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
        refresh()
    }

    private func evaluate() {
        if !palms.isEmpty, state == .possible {
            state = .began        // cancels these touches in views and stops buttons and scrolling acting on them
        } else if state == .began || state == .changed {
            state = .changed
        }
        refresh()
    }

    override func reset() {
        super.reset()
        fingers.removeAll()
        palms.removeAll()
        refresh()
    }

    private func clear() {
        fingers.removeAll()
        palms.removeAll()
        pencilTouching = false
        pencilHotUntil = .distantPast
        settle?.invalidate()
        setBlocked(false)
    }

    // MARK: Blocking

    private func refresh() {
        guard isActive else { return }
        setBlocked(!palms.isEmpty || pencilHot)
        // Re-check when the "Pencil was just here" window runs out.
        settle?.invalidate()
        let wait = pencilHotUntil.timeIntervalSinceNow
        if wait > 0 {
            settle = Timer.scheduledTimer(withTimeInterval: wait + 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func setBlocked(_ value: Bool) {
        guard value != blocked else { return }
        blocked = value
        if value, !fingers.isEmpty, Date().timeIntervalSince(firstFingerAt) < Self.revertWindow {
            // The hand landed first and dragged the page a little before we knew: put it back.
            for (sv, offset) in savedOffsets where sv.window != nil {
                sv.setContentOffset(offset, animated: false)
            }
        }
        for sv in scrollViews.allObjects { setScroll(sv, enabled: !value) }
        for l in listeners.values { l(value) }
    }

    private func setScroll(_ sv: UIScrollView, enabled: Bool) {
        sv.panGestureRecognizer.isEnabled = enabled
        sv.pinchGestureRecognizer?.isEnabled = enabled
    }

    // MARK: Who can be stopped

    /// Stops buttons, menus, scrolling and zooming. Never PencilKit's own drawing.
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
        if other is UIHoverGestureRecognizer { return false }
        if let sv = other.view as? UIScrollView, other === sv.panGestureRecognizer || other === sv.pinchGestureRecognizer {
            return true
        }
        return !Self.isInsideCanvas(other.view)
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

    /// After the pages change from `oldPage` to `newPage` points wide, scrolls so the point that was under `anchor`
    /// (in the scroll view's visible area) stays under the fingers. `top` is the unscaled padding above the first page.
    /// Middle of the visible page area, in the same space SwiftUI gestures report.
    var visibleCentre: CGPoint {
        guard let sv = scrollView else { return .zero }
        let i = sv.adjustedContentInset
        return CGPoint(x: (sv.bounds.width - i.left - i.right) / 2, y: (sv.bounds.height - i.top - i.bottom) / 2)
    }

    func keepAnchored(oldPage: CGFloat, newPage: CGFloat, anchor: CGPoint, top: CGFloat) {
        guard let sv = scrollView, oldPage > 0, abs(newPage - oldPage) > 0.01 else { return }
        let before = sv.contentOffset
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
