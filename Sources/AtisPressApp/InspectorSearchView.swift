import SwiftUI

struct InspectorSearchView: View {
    @ObservedObject var model: Workspace
    @FocusState private var searchFocused: Bool
    @State private var favoritesExpanded = true

    var body: some View {
        let results = InspectorSearchEntry.matches(model.ui.search).filter { $0.canOpen(in: model) }
        let searching = !model.ui.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Ayar ara", text: Binding(get: { model.ui.search }, set: { model.ui.search = $0 }))
                    .focused($searchFocused)
                    .accessibilityIdentifier("sidebar.search")
                    .onSubmit { if let first = results.first { open(first) } }
                if !model.ui.search.isEmpty {
                    Button { model.ui.search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Aramayı temizle")
                }
            }
            if searching {
                if results.isEmpty {
                    Text("Bu işte eşleşen ayar yok.").foregroundStyle(.secondary)
                } else {
                    rows(results, limit: 6)
                }
            } else {
                DisclosureGroup("Favoriler", isExpanded: $favoritesExpanded) {
                    let entries = model.ui.inspectorFavorites.compactMap { InspectorSearchEntry.byID[$0] }
                    if entries.isEmpty {
                        Text("Bir ayarı arayıp yıldız ile ekleyin.").foregroundStyle(.secondary).padding(.top, 4)
                    } else {
                        rows(entries, limit: 3)
                    }
                }
                .accessibilityIdentifier("sidebar.favorites")
            }
        }
        .font(.system(size: 12)).controlSize(.small)
        .onChange(of: model.ui.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private func rows(_ entries: [InspectorSearchEntry], limit: Int) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Button { open(entry) } label: {
                            HStack(spacing: 6) {
                                Text(entry.title).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(entry.panel.title).foregroundStyle(.secondary).lineLimit(1)
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.canOpen(in: model))
                        .help(entry.panel.title + " › " + entry.group.title)
                        .accessibilityIdentifier("sidebar.result." + entry.id)
                        let saved = model.ui.inspectorFavorites.contains(entry.id)
                        Button { model.ui.toggleInspectorFavorite(entry.id) } label: {
                            Image(systemName: saved ? "star.fill" : "star").frame(width: 20, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(saved ? "Favorilerden çıkar" : "Favorilere ekle")
                        .accessibilityLabel((saved ? "Favorilerden çıkar: " : "Favorilere ekle: ") + entry.title)
                    }
                    .frame(height: 24)
                }
            }.padding(.trailing, 4)
        }
        .frame(height: CGFloat(min(entries.count, limit) * 26))
    }

    private func open(_ entry: InspectorSearchEntry) {
        if model.openInspectorControl(entry) { searchFocused = false }
    }
}

struct InspectorTargetContext {
    let request: UsabilitySettings.GroupRequest?
}

private struct InspectorTargetContextKey: EnvironmentKey {
    static let defaultValue: InspectorTargetContext? = nil
}

extension EnvironmentValues {
    var inspectorTargetContext: InspectorTargetContext? {
        get { self[InspectorTargetContextKey.self] }
        set { self[InspectorTargetContextKey.self] = newValue }
    }
}

private struct InspectorTarget: ViewModifier {
    let id: String?
    var onFocus: ((Bool) -> Void)?
    @Environment(\.inspectorTargetContext) private var context
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if let context {
            let target = id != nil && context.request?.controlID == id ? context.request : nil
            anchored(content)
                .focused($focused)
                .onChange(of: focused) { _, value in onFocus?(value) }
                .task(id: target) {
                    guard target != nil, enabled else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    focused = true
                }
        } else {
            content
        }
    }

    @ViewBuilder private func anchored(_ content: Content) -> some View {
        if let id { content.id(id) }
        else { content }
    }
}

extension View {
    @ViewBuilder func inspectorTarget(_ id: String?, onFocus: ((Bool) -> Void)? = nil) -> some View {
        if id != nil || onFocus != nil { modifier(InspectorTarget(id: id, onFocus: onFocus)) }
        else { self }
    }
}

extension Workspace {
    @discardableResult func openInspectorControl(_ entry: InspectorSearchEntry) -> Bool {
        guard entry.canOpen(in: self) else { return false }
        if [.serialContent, .serialRange, .serialAppearance, .serialPosition].contains(entry.group),
           let field = InspectorSearchEntry.serialField(in: self), selectedSerialID != field.id {
            selectedSerialID = field.id
        }
        ui.search = ""
        ui.jump(entry.panel, opening: entry.group, controlID: entry.id)
        return true
    }
}
