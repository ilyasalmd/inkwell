import SwiftUI
import PhotosUI

/// Full-screen editor for the things placed on a cover: pick something from the library below,
/// then drag, pinch and rotate it on the cover, or fine-tune it with the sliders.
struct CoverArrangeView: View {
    @Binding var design: CoverDesign
    var title: String

    private enum Source: String, CaseIterable, Identifiable {
        case stickers = "Stickers", icons = "Icons", emoji = "Emoji", photo = "Photo", text = "Text"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var source: Source = .stickers
    @State private var addColor: UInt32 = 0xFFD93D
    @State private var newText = ""
    @State private var photoPick: PhotosPickerItem?
    @State private var snapshot: CoverItem?

    private let maxPhotos = 4

    private var items: [CoverItem] { design.items ?? [] }
    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }
    private var photoCount: Int { items.filter { $0.kind == .photo }.count }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let coverW = max(180, min(geo.size.width - 48, (geo.size.height * 0.56) * 0.75, 420))
                VStack(spacing: 0) {
                    cover(width: coverW)
                        .padding(.top, 16).padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                    Divider()
                    ScrollView {
                        if let id = selected, index(id) != nil {
                            editor(for: id).padding(20)
                        } else {
                            library.padding(20)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Decorate cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !items.isEmpty {
                        Button("Clear all", role: .destructive) { withAnimation(.snappy) { design.items = nil; selected = nil } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: photoPick) { _, new in
                guard let new else { return }
                Task {
                    if let data = try? await new.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data),
                       let packed = CoverImageCache.compress(ui) {
                        add(CoverItem(kind: .photo, photo: packed.data, aspect: packed.aspect))
                    }
                    photoPick = nil
                }
            }
        }
        .presentationSizing(.page)
    }

    // MARK: Cover with handles

    private func cover(width: CGFloat) -> some View {
        let s = width / 300
        return ZStack(alignment: .topLeading) {
            CoverArtwork(design: design, title: title, width: width)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                .onTapGesture { withAnimation(.snappy) { selected = nil } }
            ForEach(items) { item in handle(for: item, scale: s) }
        }
        .frame(width: width, height: 400 * s, alignment: .topLeading)
    }

    private func handle(for item: CoverItem, scale s: CGFloat) -> some View {
        let w = item.box.width * item.scale * s, h = item.box.height * item.scale * s
        let isSelected = selected == item.id
        return RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Color.clear)
            .frame(width: max(w, 28), height: max(h, 28))
            .contentShape(Rectangle())
            .rotationEffect(.degrees(item.rotation))
            .position(x: item.x * s, y: item.y * s)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        begin(item.id)
                        guard let snap = snapshot, let i = index(item.id) else { return }
                        design.items?[i].x = max(0, min(300, snap.x + v.translation.width / s))
                        design.items?[i].y = max(0, min(400, snap.y + v.translation.height / s))
                    }
                    .onEnded { _ in snapshot = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        begin(item.id)
                        guard let snap = snapshot, let i = index(item.id) else { return }
                        design.items?[i].scale = max(0.25, min(3.5, snap.scale * v.magnification))
                    }
                    .onEnded { _ in snapshot = nil }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { v in
                        begin(item.id)
                        guard let snap = snapshot, let i = index(item.id) else { return }
                        design.items?[i].rotation = snap.rotation + v.rotation.degrees
                    }
                    .onEnded { _ in snapshot = nil }
            )
            .accessibilityLabel("Cover item")
    }

    private func begin(_ id: UUID) {
        if selected != id { selected = id }
        if snapshot?.id != id, let i = index(id) { snapshot = items[i] }
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Add", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if source == .stickers || source == .icons || source == .text {
                colourRow(selection: $addColor)
            }

            switch source {
            case .stickers:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                    ForEach(StickerKind.allCases) { k in
                        Button { add(CoverItem(kind: .sticker, value: k.rawValue, color: addColor)) } label: {
                            StickerArt(kind: k, color: Color(hex: addColor)).frame(width: 64, height: 64)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(k.title) sticker")
                    }
                }
            case .icons:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 8)], spacing: 8) {
                    ForEach(CoverLibrary.icons, id: \.self) { sym in
                        Button { add(CoverItem(kind: .icon, value: sym, color: addColor)) } label: {
                            Image(systemName: sym).font(.system(size: 22))
                                .foregroundStyle(Color(hex: addColor).isLight ? Color.black.opacity(0.75) : Color(hex: addColor))
                                .frame(width: 46, height: 46)
                                .background(Color(hex: addColor).isLight ? Color.black.opacity(0.06) : Color(.systemBackground).opacity(0.7),
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .emoji:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 8)], spacing: 8) {
                    ForEach(CoverLibrary.emoji, id: \.self) { e in
                        Button { add(CoverItem(kind: .emoji, value: e)) } label: {
                            Text(e).font(.system(size: 30)).frame(width: 46, height: 46)
                                .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Emoji \(e)")
                    }
                }
            case .photo:
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $photoPick, matching: .images) {
                        Label("Choose a photo", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(photoCount >= maxPhotos)
                    Text(photoCount >= maxPhotos ? "A cover can hold up to \(maxPhotos) photos. Remove one to add another."
                                                 : "Photos are shrunk to keep your library small. Pick a frame after you add one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .text:
                HStack {
                    TextField("A word or two", text: $newText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit(addText)
                    Button("Add", action: addText)
                        .buttonStyle(.borderedProminent)
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addText() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        add(CoverItem(kind: .text, value: t, color: addColor == 0xFFD93D ? 0xFFFFFF : addColor))
        newText = ""
    }

    private func add(_ proto: CoverItem) {
        var item = proto
        item.x = 150 + Double.random(in: -26...26)
        item.y = 190 + Double.random(in: -30...30)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            design.items = (design.items ?? []) + [item]
            selected = item.id
        }
    }

    // MARK: Editing the selected item

    private func editor(for id: UUID) -> some View {
        let kind = items[index(id) ?? 0].kind
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { withAnimation(.snappy) { selected = nil } } label: {
                    Label("Add more", systemImage: "plus.circle")
                }
                Spacer()
                Button { duplicate(id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button { toFront(id) } label: { Label("Bring to front", systemImage: "square.3.layers.3d.top.filled") }
                    .labelStyle(.iconOnly)
                Button(role: .destructive) { remove(id) } label: { Label("Delete", systemImage: "trash") }
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)

            slider("Size", value: binding(id, \.scale, 1), range: 0.25...3.5, symbolSmall: "minus.magnifyingglass", symbolBig: "plus.magnifyingglass")
            slider("Rotation", value: binding(id, \.rotation, 0), range: -180...180, symbolSmall: "rotate.left", symbolBig: "rotate.right")

            switch kind {
            case .sticker, .icon:
                colourRow(selection: binding(id, \.color, 0xFFFFFF))
            case .text:
                TextField("Text", text: binding(id, \.value, ""))
                    .textFieldStyle(.roundedBorder)
                colourRow(selection: binding(id, \.color, 0xFFFFFF))
            case .photo:
                Picker("Frame", selection: binding(id, \.photoStyle, 0)) {
                    ForEach(CoverPhotoStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            case .emoji:
                EmptyView()
            }
        }
    }

    private func slider(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, symbolSmall: String, symbolBig: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: symbolSmall).foregroundStyle(.secondary)
                Slider(value: value, in: range)
                Image(systemName: symbolBig).foregroundStyle(.secondary)
            }
        }
    }

    private func colourRow(selection: Binding<UInt32>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(CoverLibrary.stickerColors, id: \.self) { hex in
                    Button { selection.wrappedValue = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.primary.opacity(0.22), lineWidth: 1))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: selection.wrappedValue == hex ? 3 : 0).padding(-4))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(String(hex, radix: 16))")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<CoverItem, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { index(id).map { design.items![$0][keyPath: keyPath] } ?? fallback },
            set: { new in if let i = index(id) { design.items?[i][keyPath: keyPath] = new } }
        )
    }

    private func duplicate(_ id: UUID) {
        guard let i = index(id) else { return }
        if items[i].kind == .photo, photoCount >= maxPhotos { return }
        var copy = items[i]
        copy.id = UUID()
        copy.x = min(300, copy.x + 18)
        copy.y = min(400, copy.y + 18)
        withAnimation(.snappy) {
            design.items?.append(copy)
            selected = copy.id
        }
    }

    private func toFront(_ id: UUID) {
        guard let i = index(id), i != items.count - 1 else { return }
        withAnimation(.snappy) {
            let item = design.items!.remove(at: i)
            design.items!.append(item)
        }
    }

    private func remove(_ id: UUID) {
        withAnimation(.snappy) {
            design.items?.removeAll { $0.id == id }
            if design.items?.isEmpty == true { design.items = nil }
            selected = nil
        }
    }
}
