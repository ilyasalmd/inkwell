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

/// Everything the canvases need to configure a PencilKit tool. Equatable so views only update on change.
struct ToolSpec: Equatable {
    var kind: ToolKind
    var color: UIColor
    var width: CGFloat          // 0...1 fraction of the ink's valid range

    func makeTool() -> PKTool {
        switch kind {
        case .eraser:
            return PKEraserTool(.vector)
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
    /// Where the Apple Pencil squeeze palette is showing. (-1, -1) means "centre of the page area".
    var quickPalettePoint: CGPoint?
    @ObservationIgnored var previousKind: ToolKind = .pen
    @ObservationIgnored var haptic: ((CGPoint?) -> Void)?
    @ObservationIgnored weak var activeCanvas: PKCanvasView?
    @ObservationIgnored weak var boardCanvas: PKCanvasView?

    var spec: ToolSpec { ToolSpec(kind: kind, color: color, width: width) }

    func select(_ k: ToolKind) {
        guard k != kind else { return }
        previousKind = kind
        kind = k
        haptic?(nil)
    }

    func pick(_ c: UIColor) {
        color = c
        haptic?(nil)
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
