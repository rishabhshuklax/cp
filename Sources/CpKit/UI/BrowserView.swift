import SwiftUI

/// The second surface: a real window for when you are *hunting* rather than
/// pasting.
///
/// Splitting this off is what lets the picker stay ruthless. One surface trying to
/// be both a 200ms keyboard flow and a place to browse a month of history ends up
/// serving neither, which is how the popover model gets stuck with a hover-delayed
/// preview and a scroll view you can't resize.
public struct BrowserView: View {

    @Bindable private var model: PickerModel
    private let archive: ClippingArchive?
    private let onTogglePin: (UUID) -> Void
    private let onDelete: (UUID) -> Void
    private let onCopy: (Clipping) -> Void

    @State private var sidebarSelection: SidebarItem? = .all

    public init(
        model: PickerModel,
        archive: ClippingArchive?,
        onTogglePin: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onCopy: @escaping (Clipping) -> Void
    ) {
        self._model = Bindable(model)
        self.archive = archive
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onCopy = onCopy
    }

    enum SidebarItem: Hashable {
        case all
        case pinned
        case kind(ClippingKind)

        var title: String {
            switch self {
            case .all: return "All"
            case .pinned: return "Pinned"
            case .kind(let kind): return kind.token.capitalized
            }
        }

        var symbolName: String {
            switch self {
            case .all: return "tray.full"
            case .pinned: return "pin.fill"
            case .kind(let kind): return kind.symbolName
            }
        }

        var filter: SearchQuery.Filter? {
            switch self {
            case .all: return nil
            case .pinned: return .pinnedOnly
            case .kind(let kind): return .kind(kind)
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        [.all, .pinned] + ClippingKind.allCases.map { SidebarItem.kind($0) }
    }

    public var body: some View {
        NavigationSplitView {
            List(sidebarItems, id: \.self, selection: $sidebarSelection) { item in
                Label(item.title, systemImage: item.symbolName)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            HStack(spacing: 0) {
                listColumn
                    .frame(minWidth: 280, idealWidth: 340)
                Divider().overlay(Theme.separator)
                PreviewPane(
                    clipping: model.selected,
                    archive: archive,
                    resolvedTitle: model.selected.flatMap { model.title(for: $0) },
                    onTransform: { _ in }
                )
                .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        .searchable(text: $model.searchText, prompt: "Search your clipboard")
        .onChange(of: sidebarSelection) { _, newValue in
            model.committedFilters = (newValue?.filter).map { [$0] } ?? []
        }
        .navigationTitle("Clipboard")
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(model.results) { scored in
                    ClippingRow(
                        scored: scored,
                        isSelected: scored.id == model.selectedID,
                        archive: archive,
                        resolvedTitle: model.title(for: scored.clipping),
                        favicon: model.favicon(for: scored.clipping)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedID = scored.id }
                    .contextMenu {
                        Button(scored.clipping.isPinned ? "Unpin" : "Pin") {
                            onTogglePin(scored.id)
                            model.refresh()
                        }
                        Button("Copy") { onCopy(scored.clipping) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            onDelete(scored.id)
                            model.refresh()
                        }
                    }
                }
            }
            .padding(10)
        }
        .onChange(of: model.selectedID) { _, _ in
            model.resolveLinkIfNeeded()
        }
    }
}
