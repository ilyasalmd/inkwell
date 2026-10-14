import PencilKit
import UIKit

/// "Scribble to erase": zig-zag over ink with the pen and whatever the scribble covers disappears.
enum ScribbleEraser {
    private static func samples(_ stroke: PKStroke, step: CGFloat) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(step)).map { $0.location.applying(stroke.transform) }
    }

    private static func box(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// If the newest stroke is a scribble that covers older ink, returns the drawing without the scribble
    /// and without the strokes it covered. Otherwise nil (the stroke stays as ordinary ink).
    static func erase(scribbleIn drawing: PKDrawing) -> PKDrawing? {
        guard drawing.strokes.count > 1, let last = drawing.strokes.last else { return nil }
        let pts = samples(last, step: 6)
        let bounds = box(pts)
        let diag = hypot(bounds.width, bounds.height)
        guard pts.count >= 14 else { return nil }
        guard diag >= 40 else { return nil }

        var length: CGFloat = 0
        for i in 1..<pts.count { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        guard length / diag >= 2.2 else { return nil }

        // Back-and-forth motion: count reversals along each axis, ignoring wobbles smaller than `swing`.
        func reversals(_ values: [CGFloat], swing: CGFloat) -> Int {
            guard var extreme = values.first else { return 0 }
            var direction = 0   // +1 rising, -1 falling, 0 undecided
            var count = 0
            for v in values.dropFirst() {
                switch direction {
                case 1:
                    if v > extreme { extreme = v } else if extreme - v >= swing { direction = -1; extreme = v; count += 1 }
                case -1:
                    if v < extreme { extreme = v } else if v - extreme >= swing { direction = 1; extreme = v; count += 1 }
                default:
                    if v - extreme >= swing { direction = 1; extreme = v } else if extreme - v >= swing { direction = -1; extreme = v }
                }
            }
            return count
        }
        let swing = max(14, min(bounds.width, bounds.height) * 0.3)
        let turns = max(reversals(pts.map(\.x), swing: swing), reversals(pts.map(\.y), swing: swing))
        guard turns >= 4 else { return nil }

        let radius: CGFloat = 16
        let reach = bounds.insetBy(dx: -radius, dy: -radius)
        let r2 = radius * radius
        var kept: [PKStroke] = []
        var removed = 0
        for s in drawing.strokes.dropLast() {
            let sp = samples(s, step: 6)
            guard !sp.isEmpty, box(sp).intersects(reach) else { kept.append(s); continue }
            var covered = 0
            for p in sp where pts.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) < r2 }) {
                covered += 1
            }
            if Double(covered) / Double(sp.count) >= 0.5 { removed += 1 } else { kept.append(s) }
        }
        guard removed > 0 else { return nil }
        return PKDrawing(strokes: kept)
    }
}

/// Watches one canvas for scribbles and applies them with undo support.
@MainActor
final class ScribbleWatcher {
    private var lastCount: Int
    private var applying = false

    init(drawing: PKDrawing) { lastCount = drawing.strokes.count }

    func didChange(_ canvas: PKCanvasView, enabled: Bool, haptic: (() -> Void)?, save: @escaping (PKDrawing) -> Void) {
        let drawing = canvas.drawing
        let added = drawing.strokes.count == lastCount + 1
        lastCount = drawing.strokes.count
        guard enabled, !applying, added, let um = canvas.undoManager, !um.isUndoing, !um.isRedoing,
              let cleaned = ScribbleEraser.erase(scribbleIn: drawing) else { return }
        DispatchQueue.main.async { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.replace(canvas, from: drawing, to: cleaned, save: save)
            haptic?()
        }
    }

    private func replace(_ canvas: PKCanvasView, from old: PKDrawing, to new: PKDrawing, save: @escaping (PKDrawing) -> Void) {
        applying = true
        canvas.drawing = new
        lastCount = new.strokes.count
        save(new)
        applying = false
        canvas.undoManager?.registerUndo(withTarget: self) { [weak canvas] me in
            guard let canvas else { return }
            me.replace(canvas, from: new, to: old, save: save)
        }
    }
}
