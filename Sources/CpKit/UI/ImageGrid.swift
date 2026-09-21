import SwiftUI

/// Thumbnail grid, shown instead of the list when the filtered set is mostly
/// images. A list row gives an image 40pt and wastes the one property images have
/// that text doesn't — you can recognise one without reading it.
public struct ImageGrid: View {

    private let results: [ClipHit]
    private let selectedID: UUID?
    private let archive: ClippingArchive?
    private let onSelect: (UUID) -> Void
    private let onChoose: (UUID) -> Void

    public init(
        results: [ClipHit],
        selectedID: UUID?,
        archive: ClippingArchive?,
        onSelect: @escaping (UUID) -> Void,
        onChoose: @escaping (UUID) -> Void
    ) {
        self.results = results
        self.selectedID = selectedID
        self.archive = archive
        self.onSelect = onSelect
        self.onChoose = onChoose
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.Metric.gridItemSize), spacing: 8)]
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { scored in
                        cell(for: scored)
                            .id(scored.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(Theme.Motion.selection) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func cell(for scored: ClipHit) -> some View {
        let clipping = scored.clipping
        let isSelected = clipping.id == selectedID

        return VStack(spacing: 4) {
            Group {
                if let filename = clipping.assetFilename,
                   let thumbnail = ThumbnailProvider.shared.thumbnail(
                       filename: filename, archive: archive, size: Theme.Metric.gridItemSize
                   ) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: Theme.Metric.gridItemSize - 20)
            .frame(maxWidth: .infinity)

            Text(TimeBucket.relativeStamp(for: clipping.lastCopiedAt))
                .font(Theme.Font.metadata)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
        .background(isSelected ? Theme.selectedSurface : Theme.rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.selectedBorder : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onChoose(clipping.id) }
        .onTapGesture { onSelect(clipping.id) }
        .animation(Theme.Motion.selection, value: isSelected)
    }
}
