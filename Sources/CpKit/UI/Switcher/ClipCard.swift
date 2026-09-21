import AppKit
import SwiftUI

/// A clipping at card size: small enough that eight fit across the screen,
/// large enough to recognise without reading.
///
/// One card view, two homes — the quick-switch HUD and the Library's tiles —
/// because "the one I copied after lunch" is recognised the same way in both.
public struct ClipCard: View {

    public enum Style {
        /// 148pt in the HUD, and a tile in the Library.
        case card
        /// The bigger one in the Library's inspector.
        case inspector
    }

    private let clipping: Clipping
    private let style: Style
    private let store: ClippingStore
    private let links: LinkPreviews

    public init(clipping: Clipping, style: Style = .card, store: ClippingStore, links: LinkPreviews) {
        self.clipping = clipping
        self.style = style
        self.store = store
        self.links = links
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card)
            .foregroundStyle(Theme.cardInk)
    }

    private var textSize: CGFloat { style == .card ? 12.5 : 14 }
    private var monoSize: CGFloat { style == .card ? 10.5 : 11.5 }
    private var textLines: Int { style == .card ? 6 : 8 }

    @ViewBuilder
    private var content: some View {
        if clipping.isConcealed {
            secret
        } else {
            switch clipping.kind {
            case .text, .richText:
                Text(clipping.previewText(limit: 1_200))
                    .font(.system(size: textSize))
                    .lineSpacing(2)
                    .lineLimit(textLines)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
            case .url:
                link
            case .code, .json:
                code
            case .color:
                colour
            case .image:
                image
            case .file:
                file
            }
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = clipping.host, let favicon = links.favicon(forHost: host) {
                Image(nsImage: favicon).resizable().frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                LetterMark(clipping.host ?? "?", size: 20)
            }
            Text(clipping.displayTitle)
                .font(.system(size: style == .card ? 13.5 : 15, weight: .semibold))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(clipping.host ?? "")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private var code: some View {
        Text(
            clipping.kind == .json
                ? CodeHighlighter.json(prettyJSON, font: .system(size: monoSize, design: .monospaced))
                : CodeHighlighter.attributed(clipping.previewText(limit: 1_200).firstLines(10),
                                             language: clipping.language,
                                             font: .system(size: monoSize, design: .monospaced))
        )
        .lineSpacing(2.5)
        .lineLimit(10)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .mask {
            LinearGradient(
                stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    private var prettyJSON: String {
        let source = clipping.byteCount <= 32_000 ? clipping.payload : clipping.previewText(limit: 2_000)
        return (JSONFormatter.pretty(source) ?? source).firstLines(10)
    }

    private var colour: some View {
        ZStack(alignment: .bottomLeading) {
            (ColorParser.color(from: clipping.payload) ?? Theme.ink4)
            Text(clipping.displayTitle)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(ColorParser.ink(on: clipping.payload))
                .padding(.leading, 12)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var image: some View {
        if let file = clipping.assetFilename,
           let thumbnail = ThumbnailStore.shared.thumbnail(
               filename: file, url: store.assetURL(file), maxPixel: style == .card ? 420 : 700
           ) {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 22))
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var file: some View {
        VStack(spacing: 10) {
            Image(nsImage: FileIconProvider.shared.icon(forPath: firstPath))
                .resizable()
                .frame(width: 52, height: 52)
            Text(clipping.displayTitle)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var secret: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink2)
            Text("••••••••")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var firstPath: String {
        String(clipping.payload.split(separator: "\n").first ?? "")
    }
}
