import AppKit
import SwiftUI

/// The picker: a search capsule, and a panel with the selected clipping at the
/// top and the rest of history under it.
///
/// Preview first is the whole point. The old build put a list on the left and a
/// preview on the right, which meant every row was half a row wide and the
/// preview was the part you were not looking at. Here the thing you are about
/// to paste is the biggest thing on screen.
public struct PickerView: View {

    @Bindable private var model: PickerModel
    @FocusState private var searchFocused: Bool
    @State private var now = Date()

    public init(model: PickerModel) {
        self._model = Bindable(model)
    }

    public var body: some View {
        CpGlassContainer(spacing: Theme.Metric.searchGap) {
            VStack(spacing: Theme.Metric.searchGap) {
                searchCapsule
                results
            }
        }
        .frame(width: Theme.Metric.pickerWidth, height: Theme.Metric.pickerHeight)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Search

    private var searchCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink2)

            ForEach(Array(model.tokens.enumerated()), id: \.offset) { index, token in
                TokenChip(filter: token) { model.removeToken(at: index) }
            }

            TextField("Search clipboard", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.search)
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .frame(minWidth: 60)

            ScopeControl(scope: model.scope) { model.setScope($0) }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(width: Theme.Metric.pickerWidth, height: Theme.Metric.searchHeight)
        .cpGlass(in: Capsule())
    }

    // MARK: - Results

    private var results: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metric.resultsCorner, style: .continuous)
        return VStack(spacing: 0) {
            hero
            if !model.isLookOpen {
                if let suggestion = model.suggestion {
                    SuggestionCapsule(filter: suggestion) { model.acceptSuggestion() }
                }
                if model.hits.isEmpty {
                    emptyState
                } else {
                    list
                }
                if !model.stack.isEmpty {
                    StackTray(model: model)
                }
            }
        }
        .frame(width: Theme.Metric.pickerWidth, height: Theme.Metric.resultsHeight)
        .overlay(alignment: .topTrailing) {
            if model.isActionsOpen {
                ActionsView(model: model)
                    .padding(.top, Theme.Metric.actionsTop)
                    .padding(.trailing, 16)
            }
        }
        .clipShape(shape)
        .cpGlass(in: shape)
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let hit = model.selectedHit {
            VStack(alignment: .leading, spacing: 12) {
                HeroView(
                    hit: hit,
                    words: model.queryWords,
                    look: model.isLookOpen,
                    store: model.store,
                    links: model.links,
                    now: now,
                    onPasteFormat: { model.paste(hit.clipping, as: $0) }
                )
                heroFooter(for: hit.clipping)
            }
            .padding(EdgeInsets(top: 18, leading: 22, bottom: 14, trailing: 18))
            .frame(height: model.isLookOpen ? Theme.Metric.resultsHeight : Theme.Metric.heroHeight)
            .background(Theme.wash)
            .overlay(alignment: .bottom) {
                if !model.isLookOpen {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
    }

    private func heroFooter(for clipping: Clipping) -> some View {
        HStack(spacing: 10) {
            SourceLine(clipping: clipping, now: now)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let action = model.heroAction {
                    CapsuleButton(action.label) { model.run(action) }
                }
                if model.needsPastePermission {
                    CapsuleButton("Allow pasting…") { model.host?.requestPastePermission() }
                }
                CapsuleButton("More", key: "⌘K") { model.toggleActions() }
                CapsuleButton(model.canPaste ? "Paste" : "Copy", key: "↩", prominent: true) {
                    model.pasteSelected()
                }
            }
        }
        .frame(height: Theme.Metric.heroFooterHeight)
    }

    // MARK: - List

    private var list: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { item in
                            switch item {
                            case .section(let day):
                                Text(day.rawValue)
                                    .font(Theme.Font.section)
                                    .foregroundStyle(Theme.ink3)
                                    .padding(.horizontal, 12)
                                    .frame(height: Theme.Metric.sectionHeight, alignment: .bottomLeading)
                            case .hit(let hit):
                                row(for: hit)
                            }
                        }
                    }
                    .padding(.top, Theme.Metric.listTopPadding)
                    .padding(.bottom, Theme.Metric.listBottomPadding)
                    .padding(.horizontal, Theme.Metric.listHorizontalPadding)
                    .background {
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: ListOffsetKey.self,
                                value: -inner.frame(in: .named("cp.list")).minY
                            )
                        }
                    }
                }
                .coordinateSpace(name: "cp.list")
                .scrollIndicators(.hidden)
                .onPreferenceChange(ListOffsetKey.self) { top in
                    model.viewportChanged(top: top, height: outer.size.height)
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target.id, anchor: target.anchor == .top ? .top : .bottom)
                }
            }
        }
    }

    private func row(for hit: ClipHit) -> some View {
        ClipRow(
            hit: hit,
            index: model.index(of: hit.id) ?? 0,
            isSelected: hit.id == model.selectedID,
            showsKeycap: model.isCommandHeld,
            stackPosition: model.stack.position(of: hit.id),
            store: model.store,
            links: model.links,
            now: now
        )
        .id(hit.id)
        // A click pastes, the way a menu item does. Selecting with one click and
        // pasting with a second is a step nobody asked for.
        .onTapGesture { model.paste(hit.clipping) }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            model.pointerMoved(to: NSEvent.mouseLocation, over: hit.id)
        }
    }

    private var emptyState: some View {
        Text(emptyMessage)
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if model.scope == .pinned, model.query.isEmpty, model.tokens.isEmpty {
            return "Nothing pinned yet. ⌘P pins the selected clip."
        }
        let typed = model.query.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? "Nothing copied yet" : "Nothing matches “\(typed)”"
    }
}

/// How far the list has been scrolled, reported back so the model can decide
/// whether the selection is still on screen.
struct ListOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A committed filter, with the × that takes it off again.
struct TokenChip: View {
    let filter: ClipFilter
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(filter.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Theme.selection, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.selectionEdge, lineWidth: 1) }
        .fixedSize()
    }
}

/// Recent | Pinned.
struct ScopeControl: View {
    let scope: ClipScope
    let select: (ClipScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("Recent", .recent)
            button("Pinned", .pinned)
        }
        .padding(3)
        .background(Theme.wash, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
        .fixedSize()
    }

    private func button(_ title: String, _ value: ClipScope) -> some View {
        let isOn = scope == value
        return Button { select(value) } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isOn ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(isOn ? Theme.hover : .clear, in: Capsule())
                .overlay { isOn ? Capsule().strokeBorder(Theme.line, lineWidth: 1) : nil }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// "Links ⇥" — the filter the last word you typed could become. Offered, never
/// applied on its own: someone searching for "json" may mean the word.
struct SuggestionCapsule: View {
    let filter: ClipFilter
    let accept: () -> Void

    var body: some View {
        HStack {
            Button(action: accept) {
                HStack(spacing: 8) {
                    Image(systemName: filter.symbolName).font(.system(size: 11))
                    Text(filter.label).font(.system(size: 12.5, weight: .medium))
                    Text("⇥").font(Theme.Font.capsuleKey).foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.wash, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

/// The stack, while it has anything in it.
struct StackTray: View {
    let model: PickerModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -6) {
                ForEach(model.stack.clippings.prefix(4), id: \.id) { clipping in
                    ClipThumb(clipping: clipping, store: model.store, links: model.links)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                }
            }
            HStack(spacing: 4) {
                Text("\(model.stack.count) in the stack")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("· each ⌘V pastes the next")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 0)
            CapsuleButton("Clear") { model.stack.clear() }
            CapsuleButton("Paste \(model.stack.count) in order", key: "⌘↩", prominent: true) {
                model.host?.pasteStackInOrder()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: Theme.Metric.trayHeight)
        .background(Theme.scrim, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
