import PencilKit
import UIKit

/// Shape snapping: draw a line or a shape, keep the Pencil still at the end for a moment, and it turns into a clean
/// straight line, circle, ellipse, triangle, rectangle or polygon in the same pen, colour and thickness.
enum ShapeSnapper {
    /// How long the Pencil has to rest at the end of the stroke.
    static let holdTime: TimeInterval = 0.4
    /// How far it may wobble while resting.
    static let holdRadius: CGFloat = 8

    enum Shape {
        case polyline([CGPoint])                 // a straight line is a polyline with two points
        case polygon([CGPoint])
        case ellipse(center: CGPoint, a: CGFloat, b: CGFloat, angle: CGFloat)
    }

    /// The clean version of `stroke` if it ended with a hold and looks like a shape; otherwise nil.
    static func snap(_ stroke: PKStroke, liftedAt lift: Date) -> PKStroke? {
        let samples = Array(stroke.path.interpolatedPoints(by: .distance(2)))
        guard samples.count > 6, let last = samples.last else { return nil }
        // Walk back over the part where the Pencil stayed put. Its first point is when the motion stopped.
        var i = samples.count - 1
        while i > 0, dist(samples[i - 1].location, last.location) <= holdRadius { i -= 1 }
        let stopped = stroke.path.creationDate.addingTimeInterval(samples[i].timeOffset)
        guard lift.timeIntervalSince(stopped) >= holdTime else { return nil }
        guard let shape = recognise(samples[0...i].map(\.location)) else { return nil }
        return makeStroke(shape, like: stroke, samples: samples)
    }

    // MARK: Recognising

    static func recognise(_ raw: [CGPoint]) -> Shape? {
        let pts = resample(raw, spacing: 4)
        guard pts.count >= 4, let a = pts.first, let b = pts.last else { return nil }
        let length = polylineLength(pts)
        let box = bounds(pts)
        let diag = hypot(box.width, box.height)
        guard length >= 24, diag >= 16 else { return nil }

        // A straight line: nothing strays far from the line between the ends.
        let chord = dist(a, b)
        let deviation = pts.map { distToSegment($0, a, b) }.max() ?? 0
        if chord > 20, deviation <= max(5, chord * 0.06) {
            let (p, q) = straighten(a, b)
            return .polyline([p, q])
        }

        let closed = chord <= max(24, diag * 0.2) && length > diag * 1.6
        if closed {
            let ellipse = fitEllipse(pts)
            let corners = simplify(closedCorners(pts, epsilon: diag * 0.07))
            let polyError = corners.count >= 3 ? meanDistance(pts, toPolygon: corners) : .infinity
            let ellipseError = ellipse.error
            let tolerance = diag * 0.045
            let polygonWins: Bool
            switch corners.count {
            case 3...4: polygonWins = polyError < ellipseError
            case 5...6: polygonWins = polyError < ellipseError * 0.5
            default: polygonWins = false
            }
            if polygonWins, polyError <= tolerance {
                return .polygon(corners.count == 4 ? rectangle(corners, pts) ?? corners : corners)
            }
            if ellipseError <= tolerance {
                return .ellipse(center: ellipse.center, a: ellipse.a, b: ellipse.b, angle: ellipse.angle)
            }
            return nil
        }

        // Open shapes with one or two bends (an angle, a tick, a zig-zag, an L), each part straight.
        let corners = simplify(rdp(pts, epsilon: diag * 0.07), closed: false)
        if (3...4).contains(corners.count), meanDistance(pts, toPolyline: corners) <= diag * 0.035 {
            return .polyline(corners)
        }
        return nil
    }

    /// Nearly horizontal or vertical lines become exactly so.
    private static func straighten(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let snapTo = (angle / (.pi / 2)).rounded() * (.pi / 2)
        guard abs(angle - snapTo) < 5 * .pi / 180 else { return (a, b) }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let half = dist(a, b) / 2
        let d = CGPoint(x: cos(snapTo) * half, y: sin(snapTo) * half)
        return (CGPoint(x: mid.x - d.x, y: mid.y - d.y), CGPoint(x: mid.x + d.x, y: mid.y + d.y))
    }

    /// Four corners with roughly right angles become a true rectangle (squared to the page if nearly level).
    private static func rectangle(_ c: [CGPoint], _ pts: [CGPoint]) -> [CGPoint]? {
        for i in 0..<4 {
            let p = c[(i + 3) % 4], q = c[i], r = c[(i + 1) % 4]
            let v1 = CGPoint(x: p.x - q.x, y: p.y - q.y), v2 = CGPoint(x: r.x - q.x, y: r.y - q.y)
            let cosine = (v1.x * v2.x + v1.y * v2.y) / max(hypot(v1.x, v1.y) * hypot(v2.x, v2.y), 0.001)
            if abs(cosine) > 0.31 { return nil }    // more than ~18° away from a right angle
        }
        // Orientation from the longest side, snapped to level when close.
        var best = 0
        for i in 0..<4 where dist(c[i], c[(i + 1) % 4]) > dist(c[best], c[(best + 1) % 4]) { best = i }
        var angle = atan2(c[(best + 1) % 4].y - c[best].y, c[(best + 1) % 4].x - c[best].x)
        angle = angle.truncatingRemainder(dividingBy: .pi / 2)
        if abs(angle) < 6 * .pi / 180 || abs(abs(angle) - .pi / 2) < 6 * .pi / 180 { angle = 0 }
        let cosA = cos(-angle), sinA = sin(-angle)
        let rotated = pts.map { CGPoint(x: $0.x * cosA - $0.y * sinA, y: $0.x * sinA + $0.y * cosA) }
        let box = bounds(rotated)
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let back = corners.map { CGPoint(x: $0.x * cos(angle) - $0.y * sin(angle), y: $0.x * sin(angle) + $0.y * cos(angle)) }
        // Start from the corner nearest where the pen started, so the stroke keeps its direction of travel.
        let start = back.indices.min { dist(back[$0], pts[0]) < dist(back[$1], pts[0]) } ?? 0
        return (0..<4).map { back[(start + $0) % 4] }
    }

    private struct EllipseFit { var center: CGPoint; var a: CGFloat; var b: CGFloat; var angle: CGFloat; var error: CGFloat }

    /// Ellipse aligned with the points' main direction; circles when the two radii are close.
    private static func fitEllipse(_ pts: [CGPoint]) -> EllipseFit {
        let n = CGFloat(pts.count)
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in pts { sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my); sxy += (p.x - mx) * (p.y - my) }
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        func extents(_ angle: CGFloat) -> (center: CGPoint, a: CGFloat, b: CGFloat) {
            let c = cos(-angle), s = sin(-angle)
            let r = pts.map { CGPoint(x: ($0.x - mx) * c - ($0.y - my) * s, y: ($0.x - mx) * s + ($0.y - my) * c) }
            let box = bounds(r)
            let local = CGPoint(x: box.midX, y: box.midY)
            let center = CGPoint(x: mx + local.x * cos(angle) - local.y * sin(angle),
                                 y: my + local.x * sin(angle) + local.y * cos(angle))
            return (center, box.width / 2, box.height / 2)
        }
        var (center, a, b) = extents(angle)
        if abs(a - b) / max(a, b, 0.001) < 0.15 {
            let r = (a + b) / 2
            a = r; b = r; angle = 0
        } else if abs(angle) < 7 * .pi / 180 || abs(abs(angle) - .pi / 2) < 7 * .pi / 180 {
            angle = 0
            (center, a, b) = extents(0)
        }
        // Mean distance from each point to the ellipse, measured along the line to its centre.
        let c = cos(-angle), s = sin(-angle)
        var total: CGFloat = 0
        for p in pts {
            let dx = p.x - center.x, dy = p.y - center.y
            let x = dx * c - dy * s, y = dx * s + dy * c
            let r = sqrt((x / max(a, 0.001)) * (x / max(a, 0.001)) + (y / max(b, 0.001)) * (y / max(b, 0.001)))
            total += abs(1 - 1 / max(r, 0.001)) * hypot(dx, dy)
        }
        return EllipseFit(center: center, a: a, b: b, angle: angle, error: total / n)
    }

    // MARK: Building the clean stroke

    private static func makeStroke(_ shape: Shape, like stroke: PKStroke, samples: [PKStrokePoint]) -> PKStroke {
        var outline: [CGPoint] = []
        func edge(_ p: CGPoint, _ q: CGPoint) {
            let steps = max(1, Int(dist(p, q) / 3))
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps)
                outline.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
            }
        }
        func corner(_ p: CGPoint) { outline.append(contentsOf: [p, p, p]) }   // repeated points keep corners sharp

        switch shape {
        case .polyline(let c):
            for k in 0..<(c.count - 1) {
                if k > 0 { corner(c[k]) }
                edge(c[k], c[k + 1])
            }
            outline.append(c[c.count - 1])
        case .polygon(let c):
            for k in 0..<c.count {
                corner(c[k])
                edge(c[k], c[(k + 1) % c.count])
            }
            corner(c[0])
        case .ellipse(let center, let a, let b, let angle):
            let start = samples.first.map { atan2($0.location.y - center.y, $0.location.x - center.x) - angle } ?? 0
            let perimeter = .pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
            let count = max(48, Int(perimeter / 3))
            for k in 0...(count + 2) {     // a little overlap so the ends meet without a gap
                let t = start + 2 * .pi * CGFloat(k) / CGFloat(count)
                let x = a * cos(t), y = b * sin(t)
                outline.append(CGPoint(x: center.x + x * cos(angle) - y * sin(angle),
                                       y: center.y + x * sin(angle) + y * cos(angle)))
            }
        }

        // Keep the look of the pen: typical width, pressure, opacity and tilt from the middle of what was drawn.
        func median(_ values: [CGFloat]) -> CGFloat {
            let v = values.sorted()
            return v.isEmpty ? 1 : v[v.count / 2]
        }
        let middle = samples.count > 10 ? Array(samples[(samples.count / 5)...(samples.count * 4 / 5)]) : samples
        let size = CGSize(width: median(middle.map(\.size.width)), height: median(middle.map(\.size.height)))
        let force = median(middle.map(\.force)), opacity = median(middle.map(\.opacity))
        let azimuth = median(middle.map(\.azimuth)), altitude = median(middle.map(\.altitude))
        let points = outline.enumerated().map { k, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(k) * 0.004, size: size, opacity: opacity,
                          force: force, azimuth: azimuth, altitude: altitude)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
    }

    // MARK: Geometry helpers

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func polylineLength(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
    }

    /// Evenly spaced points along the polyline.
    private static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var prev = pts.first else { return [] }
        var out = [prev]
        var carry: CGFloat = 0
        for p in pts.dropFirst() {
            var d = dist(prev, p)
            var from = prev
            while carry + d >= spacing {
                let t = (spacing - carry) / d
                let q = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
                out.append(q)
                d = dist(q, p); from = q; carry = 0
            }
            carry += d
            prev = p
        }
        if let last = pts.last, dist(out[out.count - 1], last) > spacing / 2 { out.append(last) }
        return out
    }

    /// Ramer–Douglas–Peucker: the few points that keep the shape within `epsilon`.
    private static func rdp(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        var index = 0, far: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let d = distToSegment(pts[i], a, b)
            if d > far { far = d; index = i }
        }
        guard far > epsilon else { return [a, b] }
        let left = rdp(Array(pts[0...index]), epsilon: epsilon)
        let right = rdp(Array(pts[index...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    /// Corners of a closed loop: split at the point farthest from the start, simplify both halves.
    private static func closedCorners(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard let start = pts.first else { return [] }
        let far = pts.indices.max { dist(pts[$0], start) < dist(pts[$1], start) } ?? 0
        guard far > 0, far < pts.count - 1 else { return [] }
        let first = rdp(Array(pts[0...far]), epsilon: epsilon)
        let second = rdp(Array(pts[far...]) + [start], epsilon: epsilon)
        return Array(first.dropLast() + second.dropLast())
    }

    /// Drops corners that are almost on top of each other or that barely bend.
    private static func simplify(_ corners: [CGPoint], closed: Bool = true) -> [CGPoint] {
        var c = corners
        var changed = true
        while changed, c.count > (closed ? 3 : 2) {
            changed = false
            let range = closed ? Array(c.indices) : Array(c.indices.dropFirst().dropLast())
            for i in range {
                let p = c[(i + c.count - 1) % c.count], q = c[i], r = c[(i + 1) % c.count]
                let v1 = CGPoint(x: p.x - q.x, y: p.y - q.y), v2 = CGPoint(x: r.x - q.x, y: r.y - q.y)
                let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
                let cosine = (v1.x * v2.x + v1.y * v2.y) / max(l1 * l2, 0.001)
                if min(l1, l2) < 10 || cosine < -0.94 {       // under 10 pt apart, or straighter than ~160°
                    c.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return c
    }

    private static func meanDistance(_ pts: [CGPoint], toPolygon c: [CGPoint]) -> CGFloat {
        meanDistance(pts, toPolyline: c + [c[0]])
    }

    private static func meanDistance(_ pts: [CGPoint], toPolyline c: [CGPoint]) -> CGFloat {
        guard c.count >= 2 else { return .infinity }
        let total = pts.reduce(CGFloat(0)) { sum, p in
            sum + zip(c, c.dropFirst()).map { distToSegment(p, $0.0, $0.1) }.min()!
        }
        return total / CGFloat(pts.count)
    }
}

/// Watches one canvas for strokes that end with a hold and swaps them for the clean shape, with undo support.
@MainActor
final class ShapeSnapWatcher {
    private var lastCount: Int
    private var applying = false

    init(drawing: PKDrawing) { lastCount = drawing.strokes.count }

    /// Returns true when it is about to replace the newest stroke (the replacement saves itself).
    func didChange(_ canvas: PKCanvasView, enabled: Bool, haptic: (() -> Void)?, save: @escaping (PKDrawing) -> Void) -> Bool {
        let drawing = canvas.drawing
        let added = drawing.strokes.count == lastCount + 1
        lastCount = drawing.strokes.count
        guard enabled, !applying, added, canvas.tool is PKInkingTool,
              let um = canvas.undoManager, !um.isUndoing, !um.isRedoing,
              let last = drawing.strokes.last, let clean = ShapeSnapper.snap(last, liftedAt: Date()) else { return false }
        var snapped = drawing
        snapped.strokes[snapped.strokes.count - 1] = clean
        DispatchQueue.main.async { [weak self, weak canvas] in
            guard let self, let canvas else { return }
            self.replace(canvas, from: drawing, to: snapped, save: save)
            haptic?()
        }
        return true
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
