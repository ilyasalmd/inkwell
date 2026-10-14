import SwiftUI

/// Notebooks that are open as tabs next to the back button.
@MainActor @Observable
final class NotebookTabs {
    var open: [UUID] = []
    func add(_ id: UUID) { if !open.contains(id) { open.append(id) } }
}

struct TabStrip: View {
    let currentID: UUID
    var select: (UUID) -> Void
    var close: (UUID) -> Void
    var openPicker: () -> Void
    @Environment(NotebookTabs.self) private var tabs
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs.open.compactMap { store.node($0) }) { node in
                    tab(node)
                }
                Button(action: openPicker) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open another notebook")
            }
            .padding(.horizontal, 4)
        }
    }

    private func tab(_ node: Node) -> some View {
        let current = node.id == currentID
        return HStack(spacing: 6) {
            Image(systemName: node.isWhiteboard ? "rectangle.and.pencil.and.ellipsis" : "book.closed.fill")
                .font(.system(size: 12))
                .foregroundStyle(node.displayColor)
            Text(node.name)
                .font(.footnote.weight(current ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            if tabs.open.count > 1 || !current {
                Button { close(node.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(node.name)")
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 30)
        .background(current ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(current ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { if !current { select(node.id) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

/// Choose another notebook to open as a tab.
struct OpenNotebookSheet: View {
    var pick: (UUID) -> Void
    @Environment(LibraryStore.self) private var store
    @Environment(NotebookTabs.self) private var tabs
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [Node] {
        store.nodes.values
            .filter { !$0.isFolder && !tabs.open.contains($0.id) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        NavigationStack {
            List(items) { node in
                Button { pick(node.id); dismiss() } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(node.name)
                            Text(store.path(to: node.parentID).map(\.name).joined(separator: " › ").ifEmpty("All Notes"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: node.isWhiteboard ? "rectangle.and.pencil.and.ellipsis" : "book.closed.fill")
                            .foregroundStyle(node.displayColor)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay { if items.isEmpty { ContentUnavailableView("No other notebooks", systemImage: "books.vertical") } }
            .searchable(text: $query, prompt: "Search notebooks")
            .navigationTitle("Open notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
