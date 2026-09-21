import SwiftUI

/// The search field, with committed filters rendered as chips.
///
/// The query language is invisible until you trip over it: type `app:xcode` and a
/// space, and the token leaves the text field and becomes a chip; type anything
/// else and it stays plain search text. Nothing to learn, nothing to discover, no
/// syntax error state — an unrecognised `foo:bar` just searches for `foo:bar`.
public struct SearchBar: View {

    @Binding private var text: String
    @Binding private var committedFilters: [ClipFilter]
    private let resultCount: Int
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        committedFilters: Binding<[ClipFilter]>,
        resultCount: Int
    ) {
        self._text = text
        self._committedFilters = committedFilters
        self.resultCount = resultCount
    }

    public var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(Array(committedFilters.enumerated()), id: \.offset) { index, filter in
                chip(filter, at: index)
            }

            TextField("Search your clipboard", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.search)
                .focused($isFocused)
                .onKeyPress(.delete) {
                    // Backspace on an empty field pops the last chip, the way every
                    // token field on the platform behaves.
                    guard text.isEmpty, !committedFilters.isEmpty else { return .ignored }
                    committedFilters.removeLast()
                    return .handled
                }

            if resultCount > 0 {
                Text("\(resultCount)")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metric.searchBarHeight)
        .onAppear { isFocused = true }
    }

    private func chip(_ filter: ClipFilter, at index: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: filter.symbolName)
                .font(.system(size: 9))
            Text(filter.label)
                .font(Theme.Font.badge)
            Button {
                committedFilters.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.selectedSurface, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.separator, lineWidth: 1) }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}
