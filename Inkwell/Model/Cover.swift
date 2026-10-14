import SwiftUI
import PencilKit

// MARK: - Cover model

enum CoverPattern: String, Codable, CaseIterable, Identifiable {
    case plain, stripes, grid, dots, waves, arches, checker, topo, confetti, diagonal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CoverTitleStyle: String, Codable, CaseIterable, Identifiable {
    case serif, rounded, mono, sans
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    func font(size: CGFloat) -> Font {
        switch self {
        case .serif: return .system(size: size, weight: .bold, design: .serif)
        case .rounded: return .system(size: size, weight: .heavy, design: .rounded)
        case .mono: return .system(size: size * 0.85, weight: .semibold, design: .monospaced)
        case .sans: return .system(size: size, weight: .black, design: .default)
        }
    }
}

enum CoverLabel: String, Codable, CaseIterable, Identifiable {
    case plate, band, printed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plate: return "Plate"
        case .band: return "Band"
        case .printed: return "Printed"
        }
    }
}

enum CoverMaterial: String, Codable, CaseIterable, Identifiable {
    case cloth, leather, gloss, matte
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CoverDesign: Codable, Hashable {
    var primary: UInt32 = 0xD6452B
    var secondary: UInt32 = 0xF7D7A8
    var pattern: CoverPattern = .plain
    var symbol: String?
    var titleStyle: CoverTitleStyle = .serif
    var label: CoverLabel = .plate
    var material: CoverMaterial = .cloth
    var ribbon = true
    /// Hand-drawn layer (PKDrawing data in the 300 × 400 cover space), drawn over the artwork.
    var drawing: Data?

    var primaryColor: Color { Color(hex: primary) }
    var secondaryColor: Color { Color(hex: secondary) }

    static func from(tint: NodeTint) -> CoverDesign {
        CoverDesign(primary: tint.hex, secondary: 0xF7EFDD)
    }

    static let presets: [(name: String, primary: UInt32, secondary: UInt32)] = [
        ("Poppy", 0xD6452B, 0xF7D7A8), ("Marigold", 0xF2A93B, 0x6B3410), ("Ink", 0x1F2A44, 0xE8C26B),
        ("Sage", 0x6F9468, 0xF4EFDF), ("Sky", 0x4C8FD6, 0xFFF3C4), ("Plum", 0x6E3A63, 0xF0B7C8),
        ("Teal", 0x0F766E, 0xFDE68A), ("Cocoa", 0x5A3E36, 0xF2D5B1), ("Rose", 0xE58CA0, 0xFFF1E0),
        ("Slate", 0x3E4A59, 0x9FD3C7), ("Lemon", 0xF5D547, 0x2B2B2B), ("Graphite", 0x2B2B2B, 0xF2F2F0)
    ]

    static let symbols: [String] = [
        "graduationcap.fill", "function", "atom", "flask.fill", "book.fill", "pencil.and.ruler.fill",
        "paintpalette.fill", "music.note", "leaf.fill", "globe.europe.africa.fill", "brain.head.profile", "heart.fill",
        "star.fill", "bolt.fill", "moon.stars.fill", "sun.max.fill", "flame.fill", "camera.fill",
        "cart.fill", "airplane", "chart.line.uptrend.xyaxis", "lightbulb.fill", "laptopcomputer", "hammer.fill"
    ]

    static func random() -> CoverDesign {
        let p = presets.randomElement()!
        return CoverDesign(primary: p.primary, secondary: p.secondary,
                           pattern: CoverPattern.allCases.randomElement()!,
                           symbol: symbols.randomElement(),
                           titleStyle: CoverTitleStyle.allCases.randomElement()!,
                           label: CoverLabel.allCases.randomElement()!,
                           material: CoverMaterial.allCases.randomElement()!,
                           ribbon: Bool.random(), drawing: nil)
    }
}

extension Node {
    var coverDesign: CoverDesign { cover ?? CoverDesign.from(tint: tint) }
    var displayColor: Color { cover?.primaryColor ?? tint.color }
}

// MARK: - Artwork

private struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

/// A notebook cover drawn at a logical 300 × 400 and scaled to `width`.
struct CoverArtwork: View {
    let design: CoverDesign
    let title: String
    var width: CGFloat = 150

    private static let logical = CGSize(width: 300, height: 400)

    var body: some View {
        let scale = width / Self.logical.width
        ZStack {
            artwork
        }
        .frame(width: Self.logical.width, height: Self.logical.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: width, height: Self.logical.height * scale, alignment: .topLeading)
    }

    private var artwork: some View {
        let primary = design.primaryColor
        let secondary = design.secondaryColor
        return ZStack(alignment: .topLeading) {
            // base
            LinearGradient(colors: [primary, primary.mix(with: .black, by: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            // pattern
            Canvas { ctx, size in drawPattern(ctx: ctx, size: size, color: secondary) }

            // material
            materialOverlay

            // content
            content(primary: primary, secondary: secondary)

            // hand-drawn layer
            if let img = CoverDrawingCache.image(for: design.drawing) {
                Image(uiImage: img).resizable().frame(width: 300, height: 400)
            }

            // ribbon bookmark
            if design.ribbon {
                RibbonShape()
                    .fill(LinearGradient(colors: [secondary, secondary.mix(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26, height: 70)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 1, y: 2)
                    .offset(x: 218, y: 330)
            }

            // spine
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.08)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 34)
                Rectangle().fill(.white.opacity(0.18)).frame(width: 2)
                Spacer()
            }
            // right page edge
            HStack(spacing: 0) {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 10)
            }
        }
        .frame(width: 300, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func content(primary: Color, secondary: Color) -> some View {
        let ink = Color(hex: design.secondary).isLight ? Color.black.opacity(0.82) : Color.white
        let plateText = design.secondary == 0 ? Color.black : Color(hex: 0x1D1A16)
        switch design.label {
        case .plate:
            VStack(spacing: 0) {
                Spacer().frame(height: 120)
                if let sym = design.symbol {
                    Image(systemName: sym)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(secondary)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.leading, 34)
                    Spacer().frame(height: 22)
                } else {
                    Spacer().frame(height: 40)
                }
                Text(title.isEmpty ? "Untitled" : title)
                    .font(design.titleStyle.font(size: 26))
                    .foregroundStyle(plateText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .frame(width: 214)
                    .background(Color(hex: 0xFBF6E9), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 3)
                    .padding(.leading, 34)
                Spacer()
            }
        case .band:
            VStack(spacing: 0) {
                Spacer().frame(height: 70)
                if let sym = design.symbol {
                    Image(systemName: sym)
                        .font(.system(size: 62, weight: .semibold))
                        .foregroundStyle(secondary)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                        .frame(maxWidth: .infinity).padding(.leading, 34)
                }
                Spacer()
                Text(title.isEmpty ? "Untitled" : title)
                    .font(design.titleStyle.font(size: 30))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .minimumScaleFactor(0.55)
                    .padding(.leading, 52).padding(.trailing, 20).padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(secondary)
                    .padding(.bottom, 54)
            }
        case .printed:
            VStack(alignment: .leading, spacing: 14) {
                if let sym = design.symbol {
                    Image(systemName: sym)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(secondary)
                }
                Text(title.isEmpty ? "Untitled" : title)
                    .font(design.titleStyle.font(size: 36))
                    .foregroundStyle(secondary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.5)
                Spacer()
            }
            .padding(.leading, 56).padding(.trailing, 22).padding(.top, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var materialOverlay: some View {
        switch design.material {
        case .cloth:
            Canvas { ctx, size in
                var y: CGFloat = 0
                while y < size.height {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(.black.opacity(0.05)), lineWidth: 1)
                    y += 3
                }
                var x: CGFloat = 0
                while x < size.width {
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 1)
                    x += 3
                }
            }
        case .leather:
            ZStack {
                RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 80, endRadius: 280)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(design.secondaryColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.6, dash: [6, 5]))
                    .padding(EdgeInsets(top: 14, leading: 46, bottom: 14, trailing: 14))
            }
        case .gloss:
            LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.0), .white.opacity(0.0), .white.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        case .matte:
            Color.clear
        }
    }

    private func drawPattern(ctx: GraphicsContext, size: CGSize, color: Color) {
        let w = size.width, h = size.height
        switch design.pattern {
        case .plain:
            break
        case .stripes:
            var x: CGFloat = 34
            while x < w {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 12, height: h)), with: .color(color.opacity(0.18)))
                x += 28
            }
        case .grid:
            var x: CGFloat = 34
            while x < w { var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)); ctx.stroke(p, with: .color(color.opacity(0.22)), lineWidth: 1.4); x += 28 }
            var y: CGFloat = 0
            while y < h { var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)); ctx.stroke(p, with: .color(color.opacity(0.22)), lineWidth: 1.4); y += 28 }
        case .dots:
            var y: CGFloat = 20
            while y < h {
                var x: CGFloat = 50
                while x < w { ctx.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(color.opacity(0.35))); x += 26 }
                y += 26
            }
        case .waves:
            var y: CGFloat = 20
            while y < h {
                var p = Path()
                p.move(to: CGPoint(x: 34, y: y))
                var x: CGFloat = 34
                while x < w { p.addQuadCurve(to: CGPoint(x: x + 30, y: y), control: CGPoint(x: x + 15, y: y - 14)); x += 30; p.addQuadCurve(to: CGPoint(x: x + 30, y: y), control: CGPoint(x: x + 15, y: y + 14)); x += 30 }
                ctx.stroke(p, with: .color(color.opacity(0.3)), lineWidth: 2)
                y += 26
            }
        case .arches:
            var row: CGFloat = 0
            var y: CGFloat = h
            while y > -40 {
                var x: CGFloat = row.truncatingRemainder(dividingBy: 2) == 0 ? 34 : 34 - 30
                while x < w + 30 {
                    var p = Path()
                    p.addArc(center: CGPoint(x: x + 30, y: y), radius: 30, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                    ctx.stroke(p, with: .color(color.opacity(0.3)), lineWidth: 2)
                    x += 60
                }
                y -= 22; row += 1
            }
        case .checker:
            var row = 0
            var y: CGFloat = 0
            while y < h {
                var col = 0
                var x: CGFloat = 34
                while x < w {
                    if (row + col) % 2 == 0 { ctx.fill(Path(CGRect(x: x, y: y, width: 33, height: 33)), with: .color(color.opacity(0.16))) }
                    x += 33; col += 1
                }
                y += 33; row += 1
            }
        case .topo:
            for i in 1...14 {
                let r = CGFloat(i) * 22
                let rect = CGRect(x: w * 0.7 - r * 1.2, y: h * 0.28 - r, width: r * 2.4, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.24)), lineWidth: 1.6)
            }
        case .confetti:
            var rng = SeededRandom(state: UInt64(design.primary) &* 31 &+ UInt64(design.secondary))
            for _ in 0..<46 {
                let x = 40 + rng.next() * (w - 60), y = rng.next() * h
                let s = 8 + rng.next() * 12
                let rot = Angle.degrees(rng.next() * 180)
                var c = ctx
                c.translateBy(x: x, y: y)
                c.rotate(by: rot)
                let rect = CGRect(x: -s / 2, y: -s / 4, width: s, height: s / 2)
                c.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.35)))
            }
        case .diagonal:
            var x: CGFloat = -h
            while x < w {
                var p = Path(); p.move(to: CGPoint(x: x, y: h)); p.addLine(to: CGPoint(x: x + h, y: 0))
                ctx.stroke(p, with: .color(color.opacity(0.22)), lineWidth: 8)
                x += 38
            }
        }
    }
}

struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.55))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension Color {
    func mix(with other: Color, by amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let t = CGFloat(amount)
        return Color(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t)
    }

    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62
    }
}

// MARK: - Folder icon

struct FolderGlyph: View {
    let color: Color
    var symbol: String?
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .resizable().scaledToFit()
                .foregroundStyle(color.gradient)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundStyle(color.isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.9))
                    .offset(y: size * 0.05)
            }
        }
        .frame(width: size, height: size * 0.82)
    }
}


/// Renders stored cover sketches once and keeps the bitmap, so grids of covers stay cheap.
enum CoverDrawingCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data?) -> UIImage? {
        guard let data, let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else { return nil }
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        let img = drawing.image(from: CGRect(x: 0, y: 0, width: 300, height: 400), scale: 3)
        cache.setObject(img, forKey: key)
        return img
    }
}
