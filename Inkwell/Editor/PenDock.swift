import SwiftUI
import UIKit

// MARK: - Drawn pen

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct Chisel: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 2, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 5, y: r.minY + 7))
        p.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 1, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A pen standing tip-up. The tip carries the current ink colour.
struct PenGlyph: View {
    let kind: ToolKind
    let ink: Color

    private let tipH: CGFloat = 20
    private let bodyH: CGFloat = 46
    private let w: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            tip.frame(width: w, height: tipH)
            barrel.frame(width: w, height: bodyH)
        }
        .frame(width: w, height: tipH + bodyH)
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var tip: some View {
        switch kind {
        case .pen, .monoline:
            Triangle().fill(ink)
        case .fountain:
            ZStack {
                Triangle().fill(ink)
                Rectangle().fill(.black.opacity(0.35)).frame(width: 1.5, height: 10).offset(y: 4)
            }
        case .marker:
            Chisel().fill(ink.opacity(0.92))
        case .pencil:
            ZStack(alignment: .bottom) {
                Triangle().fill(Color(hex: 0xE6C79A))
                Triangle().fill(ink).frame(width: 8, height: 8)
            }
        case .watercolor:
            Capsule().fill(ink).frame(width: 14, height: tipH).frame(maxWidth: .infinity)
        case .crayon:
            RoundedRectangle(cornerRadius: 5).fill(ink).frame(width: 16, height: 16).frame(maxHeight: .infinity, alignment: .bottom)
        case .eraser:
            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF3A6B2)).frame(width: 20, height: 14).frame(maxHeight: .infinity, alignment: .bottom)
        case .lasso:
            Image(systemName: "lasso").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
        }
    }

    @ViewBuilder
    private var barrel: some View {
        switch kind {
        case .pen:
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(hex: 0x3A3A40), Color(hex: 0x17171B)], startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xC8A24A)).frame(height: 4) }
        case .fountain:
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(hex: 0x1F5C4A), Color(hex: 0x0E3329)], startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xD9B45B)).frame(height: 5) }
        case .monoline:
            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF4F1EA))
                .overlay(alignment: .top) { Rectangle().fill(ink).frame(height: 5) }
        case .marker:
            RoundedRectangle(cornerRadius: 4).fill(ink.mix(with: .white, by: 0.12))
                .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.18)).frame(height: 5) }
        case .pencil:
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xF2C14E))
                .overlay { HStack(spacing: 5) { ForEach(0..<2, id: \.self) { _ in Rectangle().fill(.black.opacity(0.12)).frame(width: 1.5) } } }
        case .watercolor:
            RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(hex: 0x9C6B3F), Color(hex: 0x6E4727)], startPoint: .leading, endPoint: .trailing))
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xB9BDC4)).frame(height: 8) }
        case .crayon:
            RoundedRectangle(cornerRadius: 3).fill(ink.mix(with: .white, by: 0.25))
                .overlay { VStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(.white.opacity(0.4)).frame(height: 2) } } }
        case .eraser:
            RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF4F1EA))
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0x4C7BD9)).frame(height: 8) }
        case .lasso:
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.35))
        }
    }
}

// MARK: - Dock

/// The pen tray. It can shrink to a pill, move between the top and bottom edge, and keeps colour and
/// thickness in a popover so nothing permanent sits over the writing area.
struct PenDock: View {
    @Bindable var model: EditorModel
    @Environment(AppSettings.self) private var settings
    @State private var showStyle = false
    @State private var dragY: CGFloat = 0

    var body: some View {
        Group {
            if settings.dockCollapsed { collapsed } else { expanded }
        }
        .padding(.vertical, 8)
        .offset(y: dragY)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: settings.dockCollapsed)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: settings.dockAtTop)
    }

    // MARK: Moving between edges

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { dragY = $0.translation.height * 0.6 }
            .onEnded { value in
                let dy = value.translation.height
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    if dy < -60 { settings.dockAtTop = true }
                    if dy > 60 { settings.dockAtTop = false }
                    dragY = 0
                }
            }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        HStack(spacing: 10) {
            Image(systemName: model.kind.symbol)
                .font(.system(size: 18, weight: .semibold))
            if model.kind.usesColor {
                Circle().fill(Color(model.color)).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
            }
            Image(systemName: settings.dockAtTop ? "chevron.down" : "chevron.up")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).frame(height: 46)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .contentShape(Capsule())
        .onTapGesture { settings.dockCollapsed = false }
        .gesture(moveGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show pens")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Expanded

    private var expanded: some View {
        HStack(alignment: .bottom, spacing: 8) {
            handle
            pens
            if model.kind.usesColor { styleButton }
            collapseButton
        }
        .padding(.horizontal, 12)
    }

    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: 34, height: 46)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(Circle())
            .gesture(moveGesture)
            .accessibilityLabel("Move pen tray")
            .accessibilityHint("Drag up or down to dock at the top or bottom")
    }

    private var collapseButton: some View {
        Button { settings.dockCollapsed = true } label: {
            Image(systemName: settings.dockAtTop ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide pens")
    }

    private var styleButton: some View {
        Button { showStyle.toggle() } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(model.color)).frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                Capsule().fill(Color(model.color))
                    .frame(width: 26, height: 3 + model.width * 12)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour and thickness")
        .popover(isPresented: $showStyle, arrowEdge: settings.dockAtTop ? .top : .bottom) {
            InkStylePanel(model: model)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var pens: some View {
        let inkColor = model.kind.usesColor ? Color(model.color) : Color.secondary
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(ToolKind.allCases) { k in
                    let selected = model.kind == k
                    Button {
                        if selected && k.usesColor {
                            showStyle.toggle()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { model.select(k) }
                        }
                    } label: {
                        PenGlyph(kind: k, ink: k == model.kind || k.usesColor ? Color(model.color) : inkColor)
                            .frame(width: 34, height: 76, alignment: .bottom)
                            .offset(y: selected ? 2 : 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(k.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 22)
            .frame(height: 76, alignment: .bottom)
            .clipped()
        }
        .scrollClipDisabled()
        .background(alignment: .bottom) {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .frame(height: 56)
                .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        }
        .frame(maxWidth: 560)
        .frame(height: 76)
    }
}

/// Colour and thickness for the current pen, opened from the dock.
struct InkStylePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Palette", selection: $model.paletteIndex) {
                ForEach(Array(ColorPalette.all.enumerated()), id: \.offset) { i, p in Text(p.id).tag(i) }
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 12), count: 5), spacing: 12) {
                ForEach(ColorPalette.all[model.paletteIndex].colors, id: \.self) { hex in
                    let c = UIColor(hex: hex)
                    Button { withAnimation(.snappy) { model.pick(c) } } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.primary.opacity(0.22), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: model.color == c ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(String(hex, radix: 16))")
                }
                ColorPicker("Custom colour", selection: Binding(
                    get: { Color(model.color) },
                    set: { model.pick(UIColor($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thickness").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                    Slider(value: $model.width, in: 0...1)
                    Circle().fill(.secondary).frame(width: 16, height: 16)
                }
                Capsule().fill(Color(model.color))
                    .frame(height: 2 + model.width * 16)
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: model.width)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Apple Pencil squeeze palette

struct QuickPalette: View {
    @Bindable var model: EditorModel
    let container: CGSize

    var body: some View {
        let p = model.quickPalettePoint ?? .zero
        let centred = p.x < 0
        let x = centred ? container.width / 2 : min(max(p.x, 190), container.width - 190)
        let y = centred ? container.height * 0.55 : min(max(p.y - 70, 120), container.height - 140)

        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy) { model.quickPalettePoint = nil } }

            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(ToolKind.allCases) { k in
                        Button {
                            model.select(k)
                        } label: {
                            Image(systemName: k.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 38, height: 38)
                                .background(model.kind == k ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(model.kind == k ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if model.kind.usesColor {
                    HStack(spacing: 10) {
                        ForEach(ColorPalette.all[model.paletteIndex].colors, id: \.self) { hex in
                            let c = UIColor(hex: hex)
                            Button { model.pick(c) } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: model.color == c ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
            .position(x: x, y: y)
            .transition(.scale(scale: 0.85, anchor: .center).combined(with: .opacity))
        }
    }
}

// MARK: - Pencil interaction

/// Receives Apple Pencil Pro squeeze and Pencil double-tap events for the editor.
struct PencilInteractionLayer: UIViewRepresentable {
    let model: EditorModel
    let settings: AppSettings

    func makeCoordinator() -> Coordinator { Coordinator(model: model, settings: settings) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        view.addInteraction(interaction)
        #if !targetEnvironment(macCatalyst)
        let feedback = UICanvasFeedbackGenerator(view: view)
        context.coordinator.feedback = feedback
        let model = self.model
        model.haptic = { [weak view] point in
            guard let view else { return }
            feedback.pathCompleted(at: point ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.settings = settings
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let model: EditorModel
        var settings: AppSettings
        var feedback: AnyObject?

        init(model: EditorModel, settings: AppSettings) {
            self.model = model
            self.settings = settings
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            let point = squeeze.hoverPose?.location
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.handle(settings.squeezeAction, at: point)
                }
            }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            let point = tap.hoverPose?.location
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    model.handle(settings.doubleTapAction, at: point)
                }
            }
        }
    }
}
