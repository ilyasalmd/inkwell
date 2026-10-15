import SwiftUI

/// The bin in the bottom corner of the library. Drop notebooks or folders on it to throw them away; tap it to
/// see what's inside.
struct TrashCan: View {
    @Environment(LibraryStore.self) private var store
    @State private var targeted = false
    @State private var showTrash = false

    var body: some View {
        let count = store.trashed.count
        Button { showTrash = true } label: {
            Image(systemName: count > 0 ? "trash.fill" : "trash")
                .font(.system(size: 25, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: count)
                .foregroundStyle(targeted ? Color.white : Color.primary)
                .frame(width: 62, height: 62)
                .background {
                    Circle().fill(targeted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial))
                }
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(targeted ? 0.3 : 0.18), radius: targeted ? 14 : 8, y: 4)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 22)
                            .background(Color.red, in: Capsule())
                            .overlay(Capsule().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                            .offset(x: 4, y: -4)
                    }
                }
                .scaleEffect(targeted ? 1.2 : 1)
        }
        .buttonStyle(.plain)
        .dropDestination(for: NodeRef.self) { items, _ in
            items.forEach { store.trash($0.id) }
            return !items.isEmpty
        } isTargeted: { over in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { targeted = over }
        }
        .padding(22)
        .accessibilityLabel(count > 0 ? "Trash, \(count) item\(count == 1 ? "" : "s")" : "Trash, empty")
        .accessibilityHint("Drop notebooks here to delete them. Double-tap to open.")
        .sheet(isPresented: $showTrash) { TrashView() }
    }
}

/// What's in the Trash. Items stay until the Trash is emptied or they're deleted one by one.
struct TrashView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @State private var forever: Node?

    var body: some View {
        NavigationStack {
            Group {
                if store.trashed.isEmpty {
                    ContentUnavailableView("Trash is empty", systemImage: "trash",
                                           description: Text("Drag notebooks or folders onto the bin to delete them."))
                } else {
                    ScrollView {
                        Text("Items stay here until you empty the Trash. Tap one to put it back.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24).padding(.top, 8)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)], spacing: 18) {
                            ForEach(store.trashed) { node in tile(node) }
                        }
                        .padding(20)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: store.trashed.map(\.id))
                    }
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }
                        .tint(.red)
                        .disabled(store.trashed.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Empty the Trash?", isPresented: $confirmEmpty) {
                Button("Empty Trash", role: .destructive) { store.emptyTrash() }
                Button("Cancel", role: .cancel) {}
            } message: {
                let n = store.trashed.count
                Text("\(n) item\(n == 1 ? "" : "s") will be deleted forever. This can’t be undone.")
            }
            .alert("Delete “\(forever?.name ?? "")” forever?", isPresented: Binding(get: { forever != nil }, set: { if !$0 { forever = nil } })) {
                Button("Delete Forever", role: .destructive) { if let n = forever { store.delete(n.id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(forever?.isFolder == true ? "Everything inside it goes too. This can’t be undone." : "This can’t be undone.")
            }
        }
    }

    private func tile(_ node: Node) -> some View {
        Menu {
            Button("Put Back", systemImage: "arrow.uturn.backward") { store.restore(node.id) }
            Button("Delete Forever…", systemImage: "trash.slash", role: .destructive) { forever = node }
        } label: {
            VStack(spacing: 6) {
                NodeIcon(node: node, size: 92).opacity(0.85)
                Text(node.name)
                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                    .multilineTextAlignment(.center).lineLimit(2)
                Text(subtitle(node))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows Put Back and Delete Forever")
    }

    private func subtitle(_ node: Node) -> String {
        let when = node.trashedAt.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        if node.isFolder {
            let inside = store.nodes.values.filter { $0.parentID == node.id }.count
            return "\(inside) item\(inside == 1 ? "" : "s") · \(when)"
        }
        return when
    }
}
