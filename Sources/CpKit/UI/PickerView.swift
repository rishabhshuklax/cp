import AppKit
import SwiftUI

/// The quick picker: list on the left, live preview on the right, search on top.
///
/// Centred on screen rather than anchored to the menu bar. That one choice is what
/// makes the rest possible — decoupling from the menu-bar item removes the
/// pressure to stay narrow, and the width is what buys the preview pane that a
/// popover can only fake with a hover-delayed sub-popover.
public struct PickerView: View {

    @Bindable private var model: PickerModel
    private let archive: ClippingArchive?
    private let onChoose: (Clipping, Bool) -> Void
    private let onTransform: (Clipping, Transform) -> Void
    private let onTogglePin: (UUID) -> Void
    private let onDelete: (UUID) -> Void
    private let onDismiss: () -> Void

    public init(
        model: PickerModel,
        archive: ClippingArchive?,
        onChoose: @escaping (Clipping, Bool) -> Void,
        onTransform: @escaping (Clipping, Transform) -> Void,
        onTogglePin: @escaping (UUID) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self._model = Bindable(model)
        self.archive = archive
        self.onChoose = onChoose
        self.onTransform = onTransform
        self.onTogglePin = onTogglePin
        self.onDelete = onDelete
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            SearchBar(
                text: $model.searchText,
                committedFilters: $model.committedFilters,
                resultCount: model.results.count
            )
            Divider().overlay(Theme.separator)

            HStack(spacing: 0) {
                listColumn
                    .frame(width: Theme.Metric.panelWidth * Theme.Metric.listFraction)
                Divider().overlay(Theme.separator)
                PreviewPane(
                    clipping: model.selected,
                    archive: archive,
                    resolvedTitle: model.selected.flatMap { model.title(for: $0) },
                    onTransform: { transform in
                        guard let clipping = model.selected else { return }
                        onTransform(clipping, transform)
                    }
                )
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .frame(width: Theme.Metric.panelWidth, height: Theme.Metric.panelHeight)
        // Glass on the container. Deliberately not behind the list — see Theme.
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
        .onKeyPress(.return) { chooseSelected(plainText: false); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.home) { model.selectFirst(); return .handled }
        .onKeyPress(.end) { model.selectLast(); return .handled }
        .onKeyPress(.pageDown) { model.moveSelection(by: 8); return .handled }
        .onKeyPress(.pageUp) { model.moveSelection(by: -8); return .handled }
        .background { shortcutButtons }
    }

    // MARK: - List

    @ViewBuilder
    private var listColumn: some View {
        Group {
            if model.results.isEmpty {
                emptyState
            } else if model.shouldUseGrid {
                ImageGrid(
                    results: model.results,
                    selectedID: model.selectedID,
                    archive: archive,
                    onSelect: { model.selectedID = $0 },
                    onChoose: { id in
                        guard let clipping = model.results.first(where: { $0.id == id })?.clipping else { return }
                        onChoose(clipping, false)
                    }
                )
            } else {
                list
            }
        }
        // Opaque behind rows: material here would put a moving desktop underneath
        // dense text, which is the legibility trap most "glass" redesigns fall into.
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.bucket) { section in
                        Section {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, scored in
                                ClippingRow(
                                    scored: scored,
                                    isSelected: scored.id == model.selectedID,
                                    shortcutIndex: shortcutIndex(for: scored),
                                    archive: archive,
                                    resolvedTitle: model.title(for: scored.clipping),
                                    favicon: model.favicon(for: scored.clipping)
                                )
                                .id(scored.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onChoose(scored.clipping, false) }
                                .contextMenu { contextMenu(for: scored.clipping) }
                                .onHover { hovering in
                                    // Hover moves the selection, which keeps the
                                    // preview in sync without a second mechanism.
                                    if hovering { model.selectedID = scored.id }
                                }
                            }
                        } header: {
                            if showHeaders {
                                sectionHeader(section.bucket)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Metric.rowInsetHorizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Theme.Motion.selection) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
                model.resolveLinkIfNeeded()
            }
        }
    }

    /// Computed once per render rather than per section: `sections()` walks the
    /// whole result set, and calling it inside the `ForEach` ran it again for every
    /// header.
    private var sections: [(bucket: TimeBucket, items: [ScoredClipping])] {
        model.sections()
    }

    /// Date sections only make sense on an unfiltered list. Once you are searching,
    /// relevance order is the point, and chopping it into buckets hides the best
    /// match under a header.
    private var showHeaders: Bool {
        model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sectionHeader(_ bucket: TimeBucket) -> some View {
        Text(bucket.title.uppercased())
            .font(Theme.Font.sectionHeader)
            .foregroundStyle(.tertiary)
            .kerning(0.5)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.results.isEmpty && !model.searchText.isEmpty ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "Nothing copied yet" : "No matches")
                .font(Theme.Font.rowBody)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↩", "Paste")
            hint("⌘↩", "Paste plain")
            hint("⌥1–9", "Jump")
            hint("⌘P", "Pin")
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metric.footerHeight)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(Theme.Font.badge)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.separator, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            Text(label)
                .font(Theme.Font.metadata)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Commands

    /// Hidden buttons carrying the keyboard shortcuts SwiftUI can't express through
    /// `onKeyPress` — modifier combinations and the ⌥1–9 jumps.
    private var shortcutButtons: some View {
        Group {
            Button("") { chooseSelected(plainText: true) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("") {
                guard let id = model.selectedID else { return }
                onTogglePin(id)
            }
            .keyboardShortcut("p", modifiers: .command)
            Button("") {
                guard let id = model.selectedID else { return }
                onDelete(id)
                model.refresh()
            }
            .keyboardShortcut(.delete, modifiers: .command)

            ForEach(1...9, id: \.self) { index in
                Button("") {
                    guard let clipping = model.clipping(atShortcut: index) else { return }
                    onChoose(clipping, false)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .option)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    @ViewBuilder
    private func contextMenu(for clipping: Clipping) -> some View {
        Button(clipping.isPinned ? "Unpin" : "Pin") { onTogglePin(clipping.id) }
        Button("Paste as plain text") { onChoose(clipping, true) }
        Divider()
        ForEach(Transform.available(for: clipping.kind)) { transform in
            Button(transform.title) { onTransform(clipping, transform) }
        }
        Divider()
        Button("Delete", role: .destructive) { onDelete(clipping.id) }
    }

    private func chooseSelected(plainText: Bool) {
        guard let clipping = model.selected else { return }
        onChoose(clipping, plainText)
    }

    /// ⌥1–9 map to the first nine rows of the *ranked* list, not of each section,
    /// so the badge on a row always matches the key that reaches it.
    private func shortcutIndex(for scored: ScoredClipping) -> Int? {
        guard let index = model.results.firstIndex(where: { $0.id == scored.id }), index < 9 else { return nil }
        return index + 1
    }
}
