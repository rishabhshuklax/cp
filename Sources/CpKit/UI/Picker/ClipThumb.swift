import AppKit
import SwiftUI

/// The 22pt square at the head of a row: whatever identifies the clipping
/// fastest.
///
/// A favicon for a link, the colour itself for a colour, the picture for an
/// image, Finder's icon for a file, a lock for a password — and for everything
/// made of words, the icon of the app it came from, which is the strongest
/// retrieval cue there is.
public struct ClipThumb: View {

    private let clipping: Clipping
    private let size: CGFloat
    private let store: ClippingStore
    private let links: LinkPreviews
    private let stackPosition: Int?

    public init(
        clipping: Clipping,
        size: CGFloat = Theme.Metric.thumbSize,
        store: ClippingStore,
        links: LinkPreviews,
        stackPosition: Int? = nil
    ) {
        self.clipping = clipping
        self.size = size
        self.store = store
        self.links = links
        self.stackPosition = stackPosition
    }

    public var body: some View {
        content
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let stackPosition {
                    Text("\(stackPosition)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.accent, in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if clipping.isConcealed {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Theme.ink4)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(Theme.ink2)
                }
        } else {
            switch clipping.kind {
            case .url:
                if let host = clipping.host, let favicon = links.favicon(forHost: host) {
                    Image(nsImage: favicon).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                } else {
                    LetterMark(clipping.host ?? "?", size: size)
                }
            case .color:
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(ColorParser.color(from: clipping.payload) ?? Theme.ink4)
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
            case .image:
                imageThumb
            case .file:
                Image(nsImage: FileIconProvider.shared.icon(forPath: firstPath))
                    .resizable().aspectRatio(contentMode: .fit)
            case .text, .code, .json, .richText:
                appIcon
            }
        }
    }

    @ViewBuilder
    private var imageThumb: some View {
        let file = clipping.assetFilename
        if let file, let image = ThumbnailStore.shared.thumbnail(
            filename: file, url: store.assetURL(file), maxPixel: size * 3
        ) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Theme.ink4)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(Theme.ink3)
                }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Theme.ink4)
                .overlay {
                    Image(systemName: clipping.kind.symbolName)
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(Theme.ink2)
                }
        }
    }

    private var firstPath: String {
        String(clipping.payload.split(separator: "\n").first ?? "")
    }
}

/// App icon and name, the line under everything: "Figma · 4 min ago".
public struct SourceLine: View {

    private let clipping: Clipping
    private let iconSize: CGFloat
    private let now: Date

    public init(clipping: Clipping, iconSize: CGFloat = 16, now: Date = Date()) {
        self.clipping = clipping
        self.iconSize = iconSize
        self.now = now
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
            }
            Text(clipping.sourceAppName ?? "Unknown app")
            Text("·").foregroundStyle(Theme.ink4)
            Text(RelativeTime.long(clipping.lastCopiedAt, now: now))
            if clipping.copyCount > 1 {
                Text("·").foregroundStyle(Theme.ink4)
                Text("copied \(clipping.copyCount)×")
            }
        }
        .font(Theme.Font.meta)
        .foregroundStyle(Theme.ink2)
        .lineLimit(1)
    }
}
