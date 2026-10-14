import SwiftUI
import UIKit
import PencilKit

/// Watches every touch that reaches a scroll view (without taking any of them) and decides when fingers should be
/// ignored: while a palm is resting (a large contact), while the Pencil is touching or hovering near the glass, and
/// for a moment after it lifts. While blocked, the scroll view's own pan and pinch are switched off, so a resting hand
/// can't scroll or zoom the page.
final class PalmGuard: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// Contacts wider than this (in points) are treated as a palm or the side of a hand. Fingertips are well under it.
    static let palmRadius: CGFloat = 28

    var isActive = true { didSet { if !isActive { setBlocked(false) } } }
    /// Recognisers to switch off while blocked (a scroll view's pan and pinch).
    var targets: [UIGestureRecognizer] = []
    var onBlockedChange: ((Bool) -> Void)?
    var onPencil: (() -> Void)?

    private var ignored = Set<ObjectIdentifier>()
    private var pencilTouching = 0
    private var pencilNearUntil = Date.distantPast
    private var settle: Timer?
    private(set) var blocked = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    /// Hover from Apple Pencil (iPad models that support it) counts as "about to write".
    func attachHover(to view: UIView) {
        #if !targetEnvironment(macCatalyst)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.delegate = self
        view.addGestureRecognizer(hover)
        #endif
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard isActive, g.zOffset > 0 else { return }   // zOffset is only above 0 for the Pencil, not a pointer
        pencilNearUntil = Date().addingTimeInterval(0.8)
        refresh()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else { return }
        for t in touches {
            if t.type == .pencil {
                pencilTouching += 1
                onPencil?()
            } else if t.majorRadius > Self.palmRadius || pencilActive {
                ignored.insert(ObjectIdentifier(t))
            }
        }
        refresh()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isActive else { return }
        // A palm often lands as a small contact and spreads out as the hand settles.
        for t in touches where t.type != .pencil && t.majorRadius > Self.palmRadius {
            ignored.insert(ObjectIdentifier(t))
        }
        refresh()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent) {
        for t in touches {
            if t.type == .pencil {
                pencilTouching = max(0, pencilTouching - 1)
                pencilNearUntil = Date().addingTimeInterval(1.0)
            }
            ignored.remove(ObjectIdentifier(t))
        }
        refresh()
        // Leave the gesture cycle cleanly once nothing is touching, so the next touch starts fresh.
        if (event.allTouches ?? []).allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        ignored.removeAll()
        pencilTouching = 0
        refresh()
    }

    private var pencilActive: Bool { pencilTouching > 0 || Date() < pencilNearUntil }

    private func refresh() {
        guard isActive else { return }
        setBlocked(!ignored.isEmpty || pencilActive)
        // Re-check when the "Pencil was just here" window runs out.
        settle?.invalidate()
        let wait = pencilNearUntil.timeIntervalSinceNow
        if wait > 0 {
            settle = Timer.scheduledTimer(withTimeInterval: wait + 0.05, repeats: false) { [weak self] _ in self?.refresh() }
        }
    }

    private func setBlocked(_ value: Bool) {
        guard value != blocked else { return }
        blocked = value
        for g in targets { g.isEnabled = !value }
        onBlockedChange?(value)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
    let palm = PalmGuard()

    func attach(_ sv: UIScrollView, model: EditorModel, active: Bool, onPencil: @escaping () -> Void) {
        palm.isActive = active
        palm.onPencil = onPencil
        guard scrollView !== sv else { return }
        scrollView = sv
        palm.targets = [sv.panGestureRecognizer] + (sv.pinchGestureRecognizer.map { [$0] } ?? [])
        palm.onBlockedChange = { [weak model] blocked in model?.touchBlocked = blocked }
        sv.addGestureRecognizer(palm)
        palm.attachHover(to: sv)
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
