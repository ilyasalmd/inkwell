import SwiftUI
import PencilKit

/// Draw straight onto a notebook cover. The canvas is 600 × 800 and is stored at the cover's 300 × 400 scale.
struct CoverSketchView: View {
    @Binding var design: CoverDesign
    var title: String

    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var loaded = false

    private static let editSize = CGSize(width: 600, height: 800)
    private static let factor: CGFloat = 2

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let fit = min(1, (geo.size.width - 32) / Self.editSize.width, (geo.size.height - 32) / Self.editSize.height)
                ZStack {
                    CoverArtwork(design: base, title: title, width: Self.editSize.width)
                    SketchCanvas(canvas: canvas)
                        .frame(width: Self.editSize.width, height: Self.editSize.height)
                }
                .frame(width: Self.editSize.width, height: Self.editSize.height)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                .scaleEffect(fit)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Draw on cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { canvas.drawing = PKDrawing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let data = design.drawing, let d = try? PKDrawing(data: data) {
                    canvas.drawing = d.transformed(using: CGAffineTransform(scaleX: Self.factor, y: Self.factor))
                }
            }
        }
    }

    private var base: CoverDesign {
        var d = design
        d.drawing = nil
        return d
    }

    private func save() {
        let d = canvas.drawing.transformed(using: CGAffineTransform(scaleX: 1 / Self.factor, y: 1 / Self.factor))
        design.drawing = d.strokes.isEmpty ? nil : d.dataRepresentation()
    }
}

private struct SketchCanvas: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: UIColor(hex: 0xFBF6E9), width: 6)
        let picker = context.coordinator.picker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { let picker = PKToolPicker() }
}
