import SwiftUI

/// Logical page size. Everything on a page (template + ink) lives in these coordinates and is scaled for display.
enum PageMetrics {
    static let width: CGFloat = 1000
    static let height: CGFloat = 1414
    static let size = CGSize(width: width, height: height)
}

/// Draws a page template in logical coordinates.
struct TemplateBackground: View {
    let template: PageTemplate
    let paper: PaperColor

    var body: some View {
        Canvas { ctx, size in
            let line = paper.lineColor
            let accent = paper.accentLineColor
            let w = size.width, h = size.height

            func hLine(_ y: CGFloat, from x0: CGFloat = 0, to x1: CGFloat? = nil, color: Color = line, width: CGFloat = 1.5) {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x1 ?? w, y: y))
                ctx.stroke(p, with: .color(color), lineWidth: width)
            }
            func vLine(_ x: CGFloat, from y0: CGFloat = 0, to y1: CGFloat? = nil, color: Color = line, width: CGFloat = 1.5) {
                var p = Path()
                p.move(to: CGPoint(x: x, y: y0))
                p.addLine(to: CGPoint(x: x, y: y1 ?? h))
                ctx.stroke(p, with: .color(color), lineWidth: width)
            }
            func lined(in rect: CGRect, spacing: CGFloat = 46) {
                var y = rect.minY + spacing
                while y < rect.maxY - 2 {
                    hLine(y, from: rect.minX, to: rect.maxX)
                    y += spacing
                }
            }
            func grid(in rect: CGRect, spacing: CGFloat = 40) {
                var x = rect.minX
                while x <= rect.maxX + 0.5 { vLine(x, from: rect.minY, to: rect.maxY, width: 1.2); x += spacing }
                var y = rect.minY
                while y <= rect.maxY + 0.5 { hLine(y, from: rect.minX, to: rect.maxX, width: 1.2); y += spacing }
            }
            func dots(in rect: CGRect, spacing: CGFloat = 40) {
                var y = rect.minY + spacing
                while y < rect.maxY {
                    var x = rect.minX + spacing
                    while x < rect.maxX {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4)),
                                 with: .color(line.opacity(1.6)))
                        x += spacing
                    }
                    y += spacing
                }
            }

            switch template {
            case .blank:
                break
            case .lined:
                lined(in: CGRect(x: 0, y: 70, width: w, height: h - 70))
                vLine(110, color: accent)
            case .squared:
                grid(in: CGRect(x: 20, y: 20, width: w - 40, height: h - 40))
            case .dotted:
                dots(in: CGRect(x: 0, y: 0, width: w, height: h))
            case .cornell, .cornellGrid:
                let header: CGFloat = 150
                let summary: CGFloat = 250
                let cue: CGFloat = 280
                let bodyTop = header
                let bodyBottom = h - summary
                // title area
                hLine(header, color: accent, width: 2)
                // summary area
                hLine(bodyBottom, color: accent, width: 2)
                // cue column
                vLine(cue, from: bodyTop, to: bodyBottom, color: accent, width: 2)
                if template == .cornell {
                    lined(in: CGRect(x: cue, y: bodyTop, width: w - cue, height: bodyBottom - bodyTop))
                    lined(in: CGRect(x: 0, y: bodyBottom, width: w, height: summary), spacing: 46)
                } else {
                    grid(in: CGRect(x: cue, y: bodyTop, width: w - cue, height: bodyBottom - bodyTop))
                }
            }
        }
        .background(paper.color)
    }
}

/// Lays out content at logical page size and scales it to `width`.
struct ScaledPage<Content: View>: View {
    let width: CGFloat
    var aspect: CGFloat = PageMetrics.height / PageMetrics.width
    @ViewBuilder var content: () -> Content

    var body: some View {
        let scale = width / PageMetrics.width
        let logicalHeight = PageMetrics.width * aspect
        content()
            .frame(width: PageMetrics.width, height: logicalHeight)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: width, height: logicalHeight * scale, alignment: .topLeading)
    }
}

struct TemplateThumbnail: View {
    let template: PageTemplate
    let paper: PaperColor
    var width: CGFloat = 90

    var body: some View {
        ScaledPage(width: width) {
            TemplateBackground(template: template, paper: paper)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

/// Selectable grid of templates plus paper colours.
struct TemplatePicker: View {
    @Binding var template: PageTemplate
    @Binding var paper: PaperColor
    var templates: [PageTemplate] = PageTemplate.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 14)], spacing: 14) {
                ForEach(templates) { t in
                    Button { template = t } label: {
                        VStack(spacing: 6) {
                            TemplateThumbnail(template: t, paper: paper, width: 92)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.accentColor, lineWidth: template == t ? 3 : 0)
                                )
                            Text(t.title)
                                .font(.caption)
                                .foregroundStyle(template == t ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                ForEach(PaperColor.allCases) { p in
                    Button { paper = p } label: {
                        Circle()
                            .fill(p.color)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: paper == p ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.title)
                }
            }
        }
    }
}

/// Goodnotes-style "add page" panel: every template as a live thumbnail, plus paper colour.
struct AddPagePanel: View {
    var startPaper: PaperColor
    var onAdd: (PageTemplate?, PaperColor) -> Void
    @State private var paper: PaperColor
    @AppStorage("inkwell.recentTemplates") private var recentRaw = ""
    @Environment(\.dismiss) private var dismiss

    private var recentTemplates: [PageTemplate] {
        recentRaw.split(separator: ",").compactMap { PageTemplate(rawValue: String($0)) }
    }

    private func choose(_ t: PageTemplate) {
        let list = ([t.rawValue] + recentRaw.split(separator: ",").map(String.init).filter { $0 != t.rawValue }).prefix(3)
        recentRaw = list.joined(separator: ",")
        onAdd(t, paper)
        dismiss()
    }

    init(startPaper: PaperColor, onAdd: @escaping (PageTemplate?, PaperColor) -> Void) {
        self.startPaper = startPaper
        self.onAdd = onAdd
        _paper = State(initialValue: startPaper)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a page").font(.headline)
            if !recentTemplates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        ForEach(recentTemplates) { t in
                            Button { choose(t) } label: {
                                VStack(spacing: 6) {
                                    TemplateThumbnail(template: t, paper: paper, width: 96)
                                    Text(t.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add recent \(t.title) page")
                        }
                    }
                }
                Divider()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 14), count: 3), spacing: 16) {
                ForEach(PageTemplate.allCases) { t in
                    Button { choose(t) } label: {
                        VStack(spacing: 6) {
                            TemplateThumbnail(template: t, paper: paper, width: 96)
                            Text(t.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(t.title) page")
                }
            }
            HStack(spacing: 12) {
                ForEach(PaperColor.allCases) { p in
                    Button { paper = p } label: {
                        Circle().fill(p.color).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: paper == p ? 3 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.title)
                }
            }
            Button {
                onAdd(nil, startPaper)
                dismiss()
            } label: {
                Label("Same as this page", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 340)
    }
}
