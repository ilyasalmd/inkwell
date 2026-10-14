import SwiftUI
import PencilKit

enum ToolKind: String, CaseIterable, Identifiable {
    case pen, fountain, monoline, marker, pencil, watercolor, crayon, eraser, lasso

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "Pen"
        case .fountain: return "Fountain"
        case .monoline: return "Fine liner"
        case .marker: return "Highlighter"
        case .pencil: return "Pencil"
        case .watercolor: return "Watercolour"
        case .crayon: return "Crayon"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .fountain: return "paintbrush.pointed.fill"
        case .monoline: return "pencil.line"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        case .watercolor: return "drop.fill"
        case .crayon: return "paintbrush.fill"
        case .eraser: return "eraser.fill"
        case .lasso: return "lasso"
        }
    }
    var ink: PKInkingTool.InkType? {
        switch self {
        case .pen: return .pen
        case .fountain: return .fountainPen
        case .monoline: return .monoline
        case .marker: return .marker
        case .pencil: return .pencil
        case .watercolor: return .watercolor
        case .crayon: return .crayon
        case .eraser, .lasso: return nil
        }
    }
    var usesColor: Bool { ink != nil }
}

struct ColorPalette: Identifiable {
    let id: String
    let colors: [UInt32]

    static let all: [ColorPalette] = [
        ColorPalette(id: "Ink", colors: [0x1B1B1F, 0x4B5563, 0x1E3A8A, 0x2563EB, 0x0D9488, 0x15803D, 0xDC2626, 0x7C3AED]),
        ColorPalette(id: "Pastel", colors: [0xFFB3C1, 0xFFD6A5, 0xFDFFB6, 0xCAFFBF, 0x9BF6FF, 0xA0C4FF, 0xBDB2FF, 0xFFC6FF]),
        ColorPalette(id: "Vivid", colors: [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x00C7BE, 0x007AFF, 0xAF52DE, 0xFF2D95]),
        ColorPalette(id: "Earth", colors: [0x5C4033, 0x8B5E3C, 0xC08552, 0xA3B18A, 0x588157, 0x3A5A40, 0x6D597A, 0xB56576])
    ]
}

enum EraserMode: String, CaseIterable, Identifiable {
    case pixel, stroke
    var id: String { rawValue }
    var title: String { self == .stroke ? "Stroke" : "Pixel" }
    var detail: String { self == .stroke ? "Removes the whole stroke you touch" : "Rubs out only what you touch" }
    var symbol: String { self == .stroke ? "scribble.variable" : "circle.dotted" }
}

enum EraserSize {
    static let range: ClosedRange<CGFloat> = 8...64
    /// Diameter in points for a 0...1 slider position (pixel eraser).
    static func width(_ t: CGFloat) -> CGFloat { range.lowerBound + (range.upperBound - range.lowerBound) * t }
    static let defaultFraction: CGFloat = 0.3
}

/// A named favourite: pen, colour and thickness in one tap.
struct PenStyle: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var hex: UInt32
    var width: Double
}

/// Everything the canvases need to configure a PencilKit tool. Equatable so views only update on change.
struct ToolSpec: Equatable {
    var kind: ToolKind
    var color: UIColor
    var width: CGFloat          // 0...1 fraction of the ink's valid range
    var eraser: EraserMode = .pixel
    var eraserSize: CGFloat = 0.3   // 0...1, pixel eraser only

    func makeTool() -> PKTool {
        switch kind {
        case .eraser:
            return eraser == .pixel ? PKEraserTool(.fixedWidthBitmap, width: EraserSize.width(eraserSize)) : PKEraserTool(.vector)
        case .lasso:
            return PKLassoTool()
        default:
            let ink = kind.ink ?? .pen
            let range = ink.validWidthRange
            let w = range.lowerBound + (range.upperBound - range.lowerBound) * width
            return PKInkingTool(ink, color: color, width: w)
        }
    }
}

@MainActor @Observable
final class EditorModel {
    var kind: ToolKind = .fountain
    var color: UIColor = UIColor(hex: 0x1E3A8A)
    var width: CGFloat = 0.35
    var paletteIndex = 0
    /// Colours used recently, newest first, kept across launches.
    var recents: [UInt32] = (UserDefaults.standard.array(forKey: "inkwell.recentColors") as? [Int])?.map { UInt32($0) } ?? []
    /// Where the Apple Pencil squeeze palette is showing. (-1, -1) means "centre of the page area".
    var quickPalettePoint: CGPoint?
    @ObservationIgnored var previousKind: ToolKind = .pen
    @ObservationIgnored var haptic: ((CGPoint?) -> Void)?
    @ObservationIgnored weak var activeCanvas: PKCanvasView?
    @ObservationIgnored weak var boardCanvas: PKCanvasView?

    var eraserMode: EraserMode = EraserMode(rawValue: UserDefaults.standard.string(forKey: "inkwell.eraserMode") ?? "") ?? .pixel {
        didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: "inkwell.eraserMode") }
    }
    var eraserSize: CGFloat = UserDefaults.standard.object(forKey: "inkwell.eraserSize") as? CGFloat ?? EraserSize.defaultFraction {
        didSet { UserDefaults.standard.set(eraserSize, forKey: "inkwell.eraserSize") }
    }
    var savedStyles: [PenStyle] = (UserDefaults.standard.data(forKey: "inkwell.penStyles")).flatMap { try? JSONDecoder().decode([PenStyle].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(savedStyles), forKey: "inkwell.penStyles") }
    }

    /// Scribble back and forth over ink to erase it.
    var scribbleErase: Bool = UserDefaults.standard.object(forKey: "inkwell.scribbleErase") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scribbleErase, forKey: "inkwell.scribbleErase") }
    }
    /// True while the Pencil is on the page and for a moment after, so a resting palm can't scroll, zoom or tap things.
    var pencilDown = false
    @ObservationIgnored private var pencilSettle: Task<Void, Never>?

    func pencilBegan() {
        pencilSettle?.cancel()
        pencilDown = true
    }

    func pencilEnded() {
        pencilSettle?.cancel()
        pencilSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { self?.pencilDown = false }
        }
    }

    var spec: ToolSpec { ToolSpec(kind: kind, color: color, width: width, eraser: eraserMode, eraserSize: eraserSize) }

    func saveCurrentStyle() {
        guard kind.usesColor else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        let hex = UInt32(r * 255 + 0.5) << 16 | UInt32(g * 255 + 0.5) << 8 | UInt32(b * 255 + 0.5)
        let style = PenStyle(kind: kind.rawValue, hex: hex, width: Double(width))
        guard !savedStyles.contains(where: { $0.kind == style.kind && $0.hex == hex && abs($0.width - style.width) < 0.01 }) else { return }
        savedStyles = Array((savedStyles + [style]).suffix(8))
        haptic?(nil)
    }

    func apply(_ style: PenStyle) {
        if let k = ToolKind(rawValue: style.kind) { select(k) }
        color = UIColor(hex: style.hex)
        width = CGFloat(style.width)
        haptic?(nil)
    }

    func select(_ k: ToolKind) {
        guard k != kind else { return }
        previousKind = kind
        kind = k
        haptic?(nil)
    }

    func pick(_ c: UIColor, remember: Bool = true) {
        color = c
        haptic?(nil)
        if remember { noteRecent(c) }
    }

    /// Puts a colour at the front of the recent row (no duplicates, at most 8).
    func noteRecent(_ c: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        let hex = UInt32(r * 255 + 0.5) << 16 | UInt32(g * 255 + 0.5) << 8 | UInt32(b * 255 + 0.5)
        recents.removeAll { $0 == hex }
        recents.insert(hex, at: 0)
        recents = Array(recents.prefix(8))
        UserDefaults.standard.set(recents.map { Int($0) }, forKey: "inkwell.recentColors")
    }

    /// Zooms the whiteboard to show everything drawn, or back to 100% around the centre when it is empty.
    func fitBoard() {
        guard let v = boardCanvas else { return }
        let ink = v.drawing.strokes.isEmpty ? nil : v.drawing.bounds.insetBy(dx: -120, dy: -120)
        if let ink {
            v.zoom(to: ink, animated: true)
        } else {
            v.setZoomScale(1, animated: true)
            let c = BoardCanvas.extent / 2
            v.setContentOffset(CGPoint(x: c - v.bounds.width / 2, y: c - v.bounds.height / 2), animated: true)
        }
    }

    func undo() { activeCanvas?.undoManager?.undo() }
    func redo() { activeCanvas?.undoManager?.redo() }

    func handle(_ action: PencilAction, at point: CGPoint?) {
        switch action {
        case .quickPalette:
            quickPalettePoint = quickPalettePoint == nil ? (point ?? CGPoint(x: -1, y: -1)) : nil
        case .toggleEraser:
            select(kind == .eraser ? previousKind : .eraser)
        case .previousTool:
            select(previousKind)
        case .undo:
            undo()
        case .off:
            break
        }
    }
}
