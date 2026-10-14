import SwiftUI
import UIKit

// MARK: - Placed items

/// Something placed on a notebook cover: an icon, a sticker, an emoji, a line of text or a photo.
/// Positions are in the 300 × 400 cover space and measured from the item's centre.
struct CoverItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case icon, sticker, emoji, photo, text }

    var id = UUID()
    var kind: Kind
    var value: String = ""
    var photo: Data?
    var aspect: Double = 1          // photo width / height
    var photoStyle: Int = 0         // 0 rounded, 1 circle, 2 polaroid
    var color: UInt32 = 0xFFFFFF
    var x: Double = 150
    var y: Double = 200
    var scale: Double = 1
    var rotation: Double = 0        // degrees

    /// Size at scale 1, in cover space.
    var box: CGSize {
        switch kind {
        case .photo:
            return aspect >= 1 ? CGSize(width: 130, height: 130 / aspect) : CGSize(width: 130 * aspect, height: 130)
        case .text:
            return CGSize(width: 170, height: 44)
        default:
            return CGSize(width: 72, height: 72)
        }
    }
}

enum CoverPhotoStyle: Int, CaseIterable, Identifiable {
    case rounded, circle, polaroid
    var id: Int { rawValue }
    var title: String { ["Rounded", "Circle", "Polaroid"][rawValue] }
}

enum StickerKind: String, CaseIterable, Identifiable {
    case star, heart, sparkle, bolt, cloud, flower, blob, sun, moon, smile, rainbow, tag, tape
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CoverLibrary {
    static let stickerColors: [UInt32] = [0xFF6B6B, 0xFFB84D, 0xFFD93D, 0x6BCB77, 0x4D96FF, 0x9B6BFF, 0xFF7EB6, 0xFFFFFF, 0x2B2B2B, 0x8D6E63]

    static let icons: [String] = CoverDesign.symbols + [
        "figure.run", "bicycle", "car.fill", "tram.fill", "fork.knife", "cup.and.saucer.fill",
        "gamecontroller.fill", "headphones", "guitars.fill", "theatermasks.fill", "film.fill", "puzzlepiece.fill",
        "stethoscope", "cross.case.fill", "pills.fill", "scalemass.fill", "building.columns.fill", "banknote.fill",
        "map.fill", "mountain.2.fill", "tree.fill", "pawprint.fill", "fish.fill", "ladybug.fill",
        "checkmark.seal.fill", "flag.fill", "bell.fill", "key.fill", "crown.fill", "gift.fill"
    ]

    static let emoji: [String] = [
        "📚", "✏️", "📝", "🎓", "🧪", "🧬", "🔭", "🌍", "💡", "🎨", "🎵", "⚽️",
        "🌱", "🌸", "🍀", "☀️", "🌙", "⭐️", "🔥", "💧", "🍎", "☕️", "🍕", "🎧",
        "💻", "📌", "🧠", "❤️", "😎", "🤓", "🦊", "🐱", "🐶", "🦋", "🚀", "🏆"
    ]
}

// MARK: - Rendering

struct CoverItemView: View {
    let item: CoverItem

    var body: some View {
        content
            .scaleEffect(item.scale)
            .rotationEffect(.degrees(item.rotation))
            .position(x: item.x, y: item.y)
    }

    @ViewBuilder
    private var content: some View {
        let tint = Color(hex: item.color)
        switch item.kind {
        case .icon:
            Image(systemName: item.value)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                .frame(width: 72, height: 72)
        case .sticker:
            StickerArt(kind: StickerKind(rawValue: item.value) ?? .star, color: tint)
                .frame(width: 72, height: 72)
        case .emoji:
            Text(item.value)
                .font(.system(size: 56))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                .frame(width: 72, height: 72)
        case .text:
            Text(item.value.isEmpty ? "Text" : item.value)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .frame(width: 170, height: 44)
        case .photo:
            photo
        }
    }

    @ViewBuilder
    private var photo: some View {
        let b = item.box
        if let data = item.photo, let ui = CoverImageCache.image(for: data) {
            switch CoverPhotoStyle(rawValue: item.photoStyle) ?? .rounded {
            case .rounded:
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: b.width, height: b.height).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 4))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
            case .circle:
                let d = min(b.width, b.height)
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: d, height: d).clipped()
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
            case .polaroid:
                Image(uiImage: ui).resizable().scaledToFill()
                    .frame(width: b.width, height: b.height).clipped()
                    .padding(.horizontal, 7).padding(.top, 7).padding(.bottom, 24)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
            }
        } else {
            RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.4)).frame(width: b.width, height: b.height)
        }
    }
}

/// Decoded photos for covers, kept so shelves of covers do not re-decode JPEGs on every redraw.
enum CoverImageCache {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Shrinks a picked photo so a cover stays small in the library file.
    static func compress(_ image: UIImage, maxSide: CGFloat = 640) -> (data: Data, aspect: Double)? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let k = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = img.jpegData(compressionQuality: 0.75) else { return nil }
        return (jpeg, Double(target.width / target.height))
    }
}

// MARK: - Sticker art

/// Vector stickers: a flat colour with a white die-cut border, like a printed sticker.
struct StickerArt: View {
    let kind: StickerKind
    let color: Color

    var body: some View {
        Group {
            switch kind {
            case .star: sticker(StarShape())
            case .heart: sticker(HeartShape())
            case .sparkle: sticker(SparkleShape())
            case .bolt: sticker(BoltShape())
            case .cloud: sticker(CloudShape())
            case .blob: sticker(BlobShape())
            case .moon: sticker(MoonShape())
            case .tag: tag
            case .flower: flower
            case .sun: sun
            case .smile: smile
            case .rainbow: rainbow
            case .tape: tape
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 2.5, y: 2)
        .padding(6)
    }

    private func sticker<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.stroke(.white, style: StrokeStyle(lineWidth: 9, lineJoin: .round))
            shape.fill(color)
        }
    }

    private var tag: some View {
        ZStack {
            TagShape().stroke(.white, style: StrokeStyle(lineWidth: 9, lineJoin: .round))
            TagShape().fill(color, style: FillStyle(eoFill: true))
        }
    }

    private var flower: some View {
        ZStack {
            FlowerShape().stroke(.white, style: StrokeStyle(lineWidth: 9, lineJoin: .round))
            FlowerShape().fill(color)
            Circle().fill(Color(hex: 0xFFD93D)).frame(width: 20, height: 20)
        }
    }

    private var sun: some View {
        ZStack {
            SunRays().stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            SunRays().stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().stroke(.white, lineWidth: 8).frame(width: 34, height: 34)
            Circle().fill(color).frame(width: 34, height: 34)
        }
    }

    private var smile: some View {
        ZStack {
            Circle().stroke(.white, lineWidth: 9)
            Circle().fill(color)
            HStack(spacing: 14) {
                Circle().fill(.black.opacity(0.8)).frame(width: 7, height: 9)
                Circle().fill(.black.opacity(0.8)).frame(width: 7, height: 9)
            }
            .offset(y: -8)
            SmileMouth().stroke(.black.opacity(0.8), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .frame(width: 30, height: 14).offset(y: 12)
        }
    }

    private var rainbow: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let r = 30 - CGFloat(i) * 9
                Arc(radius: r).stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            }
            ForEach(Array([0xFF6B6B, 0xFFD93D, 0x4D96FF].enumerated()), id: \.offset) { i, hex in
                let r = 30 - CGFloat(i) * 9
                Arc(radius: r).stroke(Color(hex: UInt32(hex)), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
            }
        }
        .offset(y: 10)
    }

    private var tape: some View {
        let shape = TapeShape()
        return ZStack {
            shape.fill(color.opacity(0.88))
            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width {
                    var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 5)
                    x += 12
                }
            }
            .mask(shape)
        }
        .frame(height: 28)
        .rotationEffect(.degrees(-12))
    }
}

private struct StarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY + r.height * 0.03), big = min(r.width, r.height) / 2
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let rad = i % 2 == 0 ? big : big * 0.46
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

private struct HeartShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        var p = Path()
        p.move(to: pt(0.5, 0.98))
        p.addCurve(to: pt(0.02, 0.36), control1: pt(0.2, 0.84), control2: pt(0.0, 0.6))
        p.addCurve(to: pt(0.5, 0.26), control1: pt(0.02, 0.06), control2: pt(0.44, 0.04))
        p.addCurve(to: pt(0.98, 0.36), control1: pt(0.56, 0.04), control2: pt(0.98, 0.06))
        p.addCurve(to: pt(0.5, 0.98), control1: pt(1.0, 0.6), control2: pt(0.8, 0.84))
        p.closeSubpath()
        return p
    }
}

private struct SparkleShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let n = CGPoint(x: r.midX, y: r.minY), e = CGPoint(x: r.maxX, y: r.midY)
        let s = CGPoint(x: r.midX, y: r.maxY), w = CGPoint(x: r.minX, y: r.midY)
        var p = Path()
        p.move(to: n)
        p.addQuadCurve(to: e, control: c)
        p.addQuadCurve(to: s, control: c)
        p.addQuadCurve(to: w, control: c)
        p.addQuadCurve(to: n, control: c)
        p.closeSubpath()
        return p
    }
}

private struct BoltShape: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(Double, Double)] = [(0.6, 0.0), (0.18, 0.56), (0.45, 0.56), (0.34, 1.0), (0.84, 0.4), (0.56, 0.4), (0.74, 0.0)]
        var p = Path()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * q.0, y: r.minY + r.height * q.1)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

private struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: r.minX + r.width * x, y: r.minY + r.height * y, width: r.width * w, height: r.height * h)
        }
        var p = Path()
        p.addEllipse(in: box(0.04, 0.42, 0.4, 0.46))
        p.addEllipse(in: box(0.24, 0.16, 0.5, 0.6))
        p.addEllipse(in: box(0.52, 0.36, 0.44, 0.5))
        p.addRoundedRect(in: box(0.2, 0.5, 0.6, 0.38), cornerSize: CGSize(width: 12, height: 12))
        return p
    }
}

private struct FlowerShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        var p = Path()
        for i in 0..<6 {
            let petal = Path(ellipseIn: CGRect(x: c.x - r.width * 0.15, y: c.y - r.height * 0.48, width: r.width * 0.3, height: r.height * 0.42))
            let t = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: Double(i) * .pi / 3))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            p.addPath(petal.applying(t))
        }
        return p
    }
}

private struct BlobShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), big = min(r.width, r.height) / 2
        var p = Path()
        for i in 0...48 {
            let a = Double(i) / 48 * 2 * .pi
            let rad = big * (0.8 + 0.12 * sin(3 * a + 0.6) + 0.06 * cos(5 * a))
            let pt = CGPoint(x: c.x + CGFloat(cos(a) * rad), y: c.y + CGFloat(sin(a) * rad))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

private struct MoonShape: Shape {
    func path(in r: CGRect) -> Path {
        let d = min(r.width, r.height)
        let outer = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
        return Path(ellipseIn: outer).subtracting(Path(ellipseIn: outer.offsetBy(dx: d * 0.3, dy: -d * 0.12).insetBy(dx: d * 0.04, dy: d * 0.04)))
    }
}

private struct TagShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: r.insetBy(dx: r.width * 0.08, dy: r.height * 0.18), cornerSize: CGSize(width: 10, height: 10))
        let hole = CGRect(x: r.minX + r.width * 0.18, y: r.midY - 5, width: 10, height: 10)
        p.addEllipse(in: hole)
        return p
    }
}

private struct SunRays: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), big = min(r.width, r.height) / 2
        var p = Path()
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * big * 0.62, y: c.y + CGFloat(sin(a)) * big * 0.62))
            p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * big * 0.92, y: c.y + CGFloat(sin(a)) * big * 0.92))
        }
        return p
    }
}

private struct SmileMouth: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.5))
        return p
    }
}

private struct Arc: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        return p
    }
}

private struct TapeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let step = r.height / 4
        p.move(to: CGPoint(x: r.minX + 5, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 5, y: r.minY))
        for i in 0..<4 {
            p.addLine(to: CGPoint(x: r.maxX - (i % 2 == 0 ? 0 : 5), y: r.minY + step * (CGFloat(i) + 0.5)))
            p.addLine(to: CGPoint(x: r.maxX - 5, y: r.minY + step * CGFloat(i + 1)))
        }
        p.addLine(to: CGPoint(x: r.minX + 5, y: r.maxY))
        for i in 0..<4 {
            p.addLine(to: CGPoint(x: r.minX + (i % 2 == 0 ? 0 : 5), y: r.maxY - step * (CGFloat(i) + 0.5)))
            p.addLine(to: CGPoint(x: r.minX + 5, y: r.maxY - step * CGFloat(i + 1)))
        }
        p.closeSubpath()
        return p
    }
}
