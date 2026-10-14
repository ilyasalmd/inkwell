import SwiftUI

/// Design a notebook cover (or a folder's colour and badge). Used while creating and from "Customise…".
struct CoverDesignerView: View {
    @Binding var design: CoverDesign
    var title: String
    var forFolder = false
    var showPreview = true

    @Environment(\.inkTheme) private var theme
    @State private var sketching = false
    @State private var arranging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if showPreview { preview }
            section("Colour") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                    ForEach(Array(CoverDesign.presets.enumerated()), id: \.offset) { _, p in
                        Button {
                            withAnimation(.snappy) { design.primary = p.primary; design.secondary = p.secondary }
                        } label: {
                            ZStack {
                                Circle().fill(Color(hex: p.primary))
                                Circle().fill(Color(hex: p.secondary)).frame(width: 16, height: 16).offset(x: 9, y: 9)
                                    .clipShape(Circle())
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: design.primary == p.primary ? 3 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(p.name)
                    }
                }
                HStack(spacing: 20) {
                    ColorPicker("Cover", selection: hexBinding(\.primary), supportsOpacity: false)
                    ColorPicker(forFolder ? "Badge" : "Details", selection: hexBinding(\.secondary), supportsOpacity: false)
                }
                .font(.callout)
            }

            if !forFolder {
                section("Pattern") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(CoverPattern.allCases) { pat in
                            Button {
                                withAnimation(.snappy) { design.pattern = pat }
                            } label: {
                                CoverArtwork(design: patternSample(pat), title: "", width: 60)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: design.pattern == pat ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(pat.title)
                        }
                    }
                }
            }

            section(forFolder ? "Badge" : "Emblem") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 8)], spacing: 8) {
                    Button { withAnimation(.snappy) { design.symbol = nil } } label: {
                        Image(systemName: "nosign").frame(width: 42, height: 42)
                            .background(design.symbol == nil ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    ForEach(CoverDesign.symbols, id: \.self) { sym in
                        Button { withAnimation(.snappy) { design.symbol = sym } } label: {
                            Image(systemName: sym).frame(width: 42, height: 42)
                                .background(design.symbol == sym ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(design.symbol == sym ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !forFolder {
                section("Stickers, icons & photos") {
                    Button { arranging = true } label: {
                        Label((design.items ?? []).isEmpty ? "Decorate the cover" : "Arrange \((design.items ?? []).count) items",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Add stickers, icons, emoji, text and your own photos. Drag, pinch and rotate them into place.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                section("Draw your own") {
                    HStack(spacing: 12) {
                        Button { sketching = true } label: {
                            Label(design.drawing == nil ? "Draw on the cover" : "Edit drawing", systemImage: "pencil.tip.crop.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        if design.drawing != nil {
                            Button("Remove drawing", role: .destructive) { withAnimation(.snappy) { design.drawing = nil } }
                                .buttonStyle(.bordered)
                        }
                    }
                    Text("Sketch, letter or doodle straight onto the cover with your Pencil.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                section("Finish") {
                    Picker("Title style", selection: $design.titleStyle) {
                        ForEach(CoverTitleStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Label", selection: $design.label) {
                        ForEach(CoverLabel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Material", selection: $design.material) {
                        ForEach(CoverMaterial.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Ribbon bookmark", isOn: $design.ribbon)
                }
            }
        }
        .fullScreenCover(isPresented: $sketching) {
            CoverSketchView(design: $design, title: title)
        }
        .fullScreenCover(isPresented: $arranging) {
            CoverArrangeView(design: $design, title: title)
        }
    }

    private var preview: some View {
        HStack {
            Spacer()
            ZStack {
                if forFolder {
                    FolderGlyph(color: design.primaryColor, symbol: design.symbol, size: 190)
                } else {
                    CoverArtwork(design: design, title: title, width: 190)
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        var next = forFolder ? design : CoverDesign.random()
                        if forFolder {
                            let p = CoverDesign.presets.randomElement()!
                            next.primary = p.primary; next.secondary = p.secondary
                            next.symbol = CoverDesign.symbols.randomElement()
                        }
                        next.drawing = design.drawing
                        next.items = design.items
                        design = next
                    }
                } label: {
                    Label("Surprise me", systemImage: "dice.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .offset(x: 56, y: -4)
                .accessibilityLabel("Surprise me")
            }
            Spacer()
        }
    }

    private func patternSample(_ pat: CoverPattern) -> CoverDesign {
        var d = design
        d.pattern = pat
        d.symbol = nil
        d.label = .printed
        d.ribbon = false
        d.drawing = nil
        d.items = nil
        return d
    }

    private func hexBinding(_ key: WritableKeyPath<CoverDesign, UInt32>) -> Binding<Color> {
        Binding(
            get: { Color(hex: design[keyPath: key]) },
            set: { new in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(new).getRed(&r, green: &g, blue: &b, alpha: &a)
                design[keyPath: key] = (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
            }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// Sheet to restyle an existing notebook or folder.
struct CustomiseSheet: View {
    let nodeID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var design = CoverDesign()
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                if let node = store.node(nodeID) {
                    VStack(alignment: .leading, spacing: 20) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        CoverDesignerView(design: $design, title: name, forFolder: node.isFolder)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(store.node(nodeID)?.isFolder == true ? "Customise folder" : "Design cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.setCover(nodeID, design)
                        if name != store.node(nodeID)?.name { store.rename(nodeID, to: name) }
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let n = store.node(nodeID) { design = n.coverDesign; name = n.name }
            }
        }
        .presentationSizing(.page)
    }
}
