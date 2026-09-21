import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The selected clipping, rendered as itself.
///
/// This is the whole argument of the redesign in one view: a link is a title, a
/// host and a URL with its tracking tinted; a colour is the colour; a
/// screenshot is the screenshot, with the words found inside it boxed. You
/// choose by looking, not by reading a grey line and hoping.
public struct HeroView: View {

    private let hit: ClipHit
    private let words: [String]
    private let look: Bool
    private let store: ClippingStore
    private let links: LinkPreviews
    private let now: Date
    private let onPasteFormat: (PasteFormat) -> Void

    @State private var rich: AttributedString?
    @State private var fileFacts: String?

    private var clipping: Clipping { hit.clipping }

    public init(
        hit: ClipHit,
        words: [String],
        look: Bool,
        store: ClippingStore,
        links: LinkPreviews,
        now: Date = Date(),
        onPasteFormat: @escaping (PasteFormat) -> Void
    ) {
        self.hit = hit
        self.words = words
        self.look = look
        self.store = store
        self.links = links
        self.now = now
        self.onPasteFormat = onPasteFormat
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: clipping.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if clipping.isConcealed {
            concealed
        } else {
            switch clipping.kind {
            case .text: plain
            case .richText: richText
            case .url: link
            case .code: code
            case .json: json
            case .color: colour
            case .image: image
            case .file: file
            }
        }
    }

    // MARK: - Text

    private var preview: String {
        clipping.previewText(limit: look ? 16_384 : 4_096)
    }

    private var plain: some View {
        Text(MarkedText.highlighted(preview, ranges: MarkedText.ranges(of: words, in: preview)))
            .font(look ? Theme.Font.heroTextLook : Theme.Font.heroText)
            .lineSpacing(look ? 5 : 4)
            .foregroundStyle(Theme.ink)
            .lineLimit(look ? 14 : 4)
            .multilineTextAlignment(.leading)
            .textSelection(.disabled)
    }

    @ViewBuilder
    private var richText: some View {
        if let rich {
            Text(rich)
                .lineSpacing(look ? 5 : 4)
                .foregroundStyle(Theme.ink)
                .lineLimit(look ? 14 : 4)
        } else {
            plain
        }
    }

    // MARK: - Link

    private var link: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let host = clipping.host, let favicon = links.favicon(forHost: host) {
                    Image(nsImage: favicon).resizable().frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    LetterMark(clipping.host ?? "?", size: 18)
                }
                Text(clipping.host ?? "")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.ink2)
            }
            Text(MarkedText.highlighted(clipping.displayTitle, ranges: hit.titleRanges))
                .font(look ? Theme.Font.heroTitleLook : Theme.Font.heroTitle)
                .foregroundStyle(Theme.ink)
                .lineLimit(look ? 4 : 2)
            Text(MarkedText.url(url, trackingRanges: URLTracking.trackingRanges(in: url)))
                .font(Theme.Font.heroURL)
                .foregroundStyle(Theme.ink3)
                .lineLimit(look ? 4 : 1)
                .truncationMode(.tail)
        }
    }

    private var url: String {
        clipping.payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Code and JSON

    private var code: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical) {
                Text(CodeHighlighter.attributed(
                    codeLines, language: clipping.language,
                    font: look ? Theme.Font.heroMonoLook : Theme.Font.heroMono
                ))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Code does not wrap: one snippet's shape is how you tell it
                // from another, and wrapping destroys exactly that.
                .fixedSize(horizontal: !look, vertical: true)
            }
            .scrollDisabled(!look)
            .scrollIndicators(.hidden)
            .mask { fade }
            if let language = clipping.language, language != "code" {
                Text(language.uppercased())
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    private var codeLines: String {
        preview.firstLines(look ? 24 : 7)
    }

    private var json: some View {
        ScrollView(.vertical) {
            Text(CodeHighlighter.json(
                prettyJSON, font: look ? Theme.Font.heroMonoLook : Theme.Font.heroMono
            ))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: !look, vertical: true)
        }
        .scrollDisabled(!look)
        .scrollIndicators(.hidden)
        .mask { fade }
    }

    private var prettyJSON: String {
        let source = clipping.byteCount <= 64_000 ? clipping.payload : preview
        return (JSONFormatter.pretty(source) ?? source).firstLines(look ? 24 : 7)
    }

    /// The right edge fades instead of cutting, so a long line reads as
    /// continuing rather than as ending.
    @ViewBuilder
    private var fade: some View {
        if look {
            Color.black
        } else {
            LinearGradient(
                stops: [.init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    // MARK: - Colour

    private var colour: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ColorParser.color(from: clipping.payload) ?? Theme.ink4)
                .frame(width: 128)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notations, id: \.notation) { row in
                    Button {
                        onPasteFormat(.color(row.notation))
                    } label: {
                        HStack(spacing: 12) {
                            Text(row.value).font(.system(size: 14, design: .monospaced))
                            Spacer(minLength: 8)
                            Text(row.label).font(Theme.Font.label).foregroundStyle(Theme.ink3)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var notations: [(notation: ColorNotation, label: String, value: String)] {
        let strings = ColorFormats.strings(for: clipping.payload)
        return ColorNotation.allCases.compactMap { notation in
            guard let value = strings[notation] else { return nil }
            return (notation, PasteFormat.color(notation).chipLabel(for: clipping), value)
        }
    }

    // MARK: - Image

    private var image: some View {
        let layout = look ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                          : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
        return layout {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                Text(clipping.displayTitle)
                    .font(Theme.Font.heroName)
                    .foregroundStyle(Theme.ink)
                Text(imageFacts)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.ink2)
                if let text = clipping.ocrText, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TEXT IN IMAGE")
                            .font(Theme.Font.label)
                            .foregroundStyle(Theme.ink3)
                        Text(MarkedText.highlighted(text, ranges: MarkedText.ranges(of: words, in: text)))
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(look ? 6 : 3)
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        let width: CGFloat? = look ? nil : 216
        let height: CGFloat = look ? 330 : 136
        return Group {
            if let file = clipping.assetFilename,
               let image = ThumbnailStore.shared.thumbnail(
                   filename: file, url: store.assetURL(file), maxPixel: look ? 900 : 480
               ) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .overlay { ocrBoxes }
            } else {
                Rectangle().fill(Theme.ink4)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: look ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
        }
    }

    /// The lines of text inside the picture that match what was typed. Without
    /// this, finding a screenshot by its words leaves you hunting for them.
    @ViewBuilder
    private var ocrBoxes: some View {
        if !words.isEmpty, let lines = clipping.ocrLines, !lines.isEmpty,
           let pixelWidth = clipping.pixelWidth, let pixelHeight = clipping.pixelHeight {
            GeometryReader { geometry in
                let matching = lines.filter { line in
                    let folded = line.text.lowercased()
                    return words.contains { folded.contains($0) }
                }
                ForEach(Array(matching.enumerated()), id: \.offset) { _, line in
                    let box = Self.fillRect(
                        for: line.box,
                        imageSize: CGSize(width: pixelWidth, height: pixelHeight),
                        in: geometry.size
                    )
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.mark)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Theme.markEdge, lineWidth: 1.5)
                        }
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
            }
        }
    }

    /// Where a normalized OCR box lands once the image has been scaled to fill
    /// and centre-cropped.
    static func fillRect(for box: CGRect, imageSize: CGSize, in frame: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (frame.width - drawn.width) / 2, y: (frame.height - drawn.height) / 2)
        return CGRect(
            x: origin.x + box.minX * drawn.width,
            y: origin.y + box.minY * drawn.height,
            width: box.width * drawn.width,
            height: box.height * drawn.height
        )
    }

    private var imageFacts: String {
        var parts: [String] = []
        if let width = clipping.pixelWidth, let height = clipping.pixelHeight {
            parts.append("\(width) × \(height)")
        }
        if clipping.byteCount > 0 { parts.append(ByteFormat.short(clipping.byteCount)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - File

    private var file: some View {
        HStack(spacing: 18) {
            Image(nsImage: FileIconProvider.shared.icon(forPath: firstPath))
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(MarkedText.highlighted(clipping.displayTitle, ranges: hit.titleRanges))
                    .font(Theme.Font.heroFileName)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text((firstPath as NSString).deletingLastPathComponent)
                    .font(Theme.Font.heroURL)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let fileFacts {
                    Text(fileFacts)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private var firstPath: String {
        String(clipping.payload.split(separator: "\n").first ?? "")
    }

    // MARK: - Concealed

    private var concealed: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Theme.ink4, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: remaining(at: context.date))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ink2)
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 8) {
                    Text("••••••••••••")
                        .font(Theme.Font.heroDots)
                        .foregroundStyle(Theme.ink)
                    Text(forgetLine(at: context.date))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func remaining(at date: Date) -> Double {
        guard let expiry = clipping.expiresAt else { return 0 }
        let total = max(1, expiry.timeIntervalSince(clipping.createdAt))
        return min(1, max(0, expiry.timeIntervalSince(date) / total))
    }

    private func forgetLine(at date: Date) -> String {
        guard let expiry = clipping.expiresAt else { return "Not saved" }
        return "Forgets in \(RelativeTime.secondsLeft(until: expiry, now: date))s · not saved"
    }

    // MARK: - Loading

    private func load() async {
        rich = nil
        fileFacts = nil
        if clipping.kind == .richText, let name = clipping.richAssetFilename, let url = store.assetURL(name) {
            let size = look ? 19.0 : 18.0
            let attributed: AttributedString? = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return await MainActor.run { RichPreview.attributed(rtf: data, size: size) }
            }.value
            rich = attributed
        }
        if clipping.kind == .file {
            let path = firstPath
            fileFacts = await Task.detached(priority: .utility) { Self.facts(forPath: path) }.value
        }
    }

    /// "Markdown · 18 KB", read off the file when it is still there.
    nonisolated static func facts(forPath path: String) -> String {
        var parts: [String] = []
        if let type = UTType(filenameExtension: (path as NSString).pathExtension),
           let description = type.localizedDescription {
            parts.append(description.capitalizedFirst)
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int {
            parts.append(ByteFormat.short(size))
        }
        return parts.joined(separator: " · ")
    }
}

extension String {
    /// The first `count` lines, for a preview that must not grow past its box.
    public func firstLines(_ count: Int) -> String {
        var result = ""
        var lines = 0
        for character in self {
            if character == "\n" {
                lines += 1
                if lines >= count { break }
            }
            result.append(character)
        }
        return result
    }

    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
