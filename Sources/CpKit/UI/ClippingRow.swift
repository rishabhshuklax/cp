import AppKit
import SwiftUI

/// The row. Everything the redesign is actually about lives here.
///
///     ▍ ⌘ Xcode                              2m   ⌥1
///     ▍ struct PullRequestView: View {
///     ▍   @State private var isExpanded = false
///     ▍ swift · 47 lines · 1.2 KB
///
/// Three things a one-line truncated string can never do, and this can:
///
/// - **The accent bar** types the row at a glance, before you read a word.
/// - **The source app rides in the header**, not in a hover tooltip. It is the
///   strongest retrieval cue there is and it costs 15pt of width.
/// - **The body gets up to three lines for code**, because indentation is the only
///   thing distinguishing two snippets and one truncated line of leading
///   whitespace distinguishes nothing.
public struct ClippingRow: View {

    private let scored: ScoredClipping
    private let isSelected: Bool
    private let shortcutIndex: Int?
    private let archive: ClippingArchive?
    private let resolvedTitle: String?
    private let favicon: NSImage?

    private var clipping: Clipping { scored.clipping }

    public init(
        scored: ScoredClipping,
        isSelected: Bool,
        shortcutIndex: Int? = nil,
        archive: ClippingArchive? = nil,
        resolvedTitle: String? = nil,
        favicon: NSImage? = nil
    ) {
        self.scored = scored
        self.isSelected = isSelected
        self.shortcutIndex = shortcutIndex
        self.archive = archive
        self.resolvedTitle = resolvedTitle
        self.favicon = favicon
    }

    public var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.accent(for: clipping.kind))
                .frame(width: Theme.Metric.accentBarWidth)

            HStack(alignment: .top, spacing: 9) {
                leadingAccessory
                VStack(alignment: .leading, spacing: 2) {
                    header
                    bodyPreview(for: clipping)
                    metadata
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Metric.rowHeight, alignment: .top)
        .background(isSelected ? Theme.selectedSurface : Theme.rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.rowCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Metric.rowCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.selectedBorder : .clear, lineWidth: 1)
        }
        .animation(Theme.Motion.selection, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Theme.Metric.appIconSize, height: Theme.Metric.appIconSize)
            } else {
                Image(systemName: clipping.kind.symbolName)
                    .font(.system(size: 11))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent(for: clipping.kind))
                    .frame(width: Theme.Metric.appIconSize, height: Theme.Metric.appIconSize)
            }

            Text(clipping.sourceAppName ?? "Unknown")
                .font(Theme.Font.rowTitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if clipping.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            Text(TimeBucket.relativeStamp(for: clipping.lastCopiedAt))
                .font(Theme.Font.metadata)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if let shortcutIndex {
                Text("⌥\(shortcutIndex)")
                    .font(Theme.Font.badge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Theme.separator, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }

    // MARK: - Leading accessory

    /// Only the kinds that have something to *show* get one. A text row with a
    /// placeholder glyph in the gutter is just a narrower text row.
    @ViewBuilder
    private var leadingAccessory: some View {
        switch clipping.kind {
        case .image:
            if let filename = clipping.assetFilename,
               let thumbnail = ThumbnailProvider.shared.thumbnail(
                   filename: filename, archive: archive, size: Theme.Metric.thumbnailSize
               ) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Theme.Metric.thumbnailSize, height: Theme.Metric.thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    }
            }
        case .color:
            if let color = ColorParser.color(from: clipping.payload) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    }
            }
        case .url:
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
            }
        case .file:
            Image(nsImage: NSWorkspace.shared.icon(forFile: firstPath))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        default:
            EmptyView()
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func bodyPreview(for clipping: Clipping) -> some View {
        if clipping.isConcealed {
            concealedBody
        } else {
            switch clipping.kind {
            case .code, .json:
                Text(codePreview)
                    .font(Theme.Font.rowBodyMono)
                    .foregroundStyle(.primary)
                    .lineLimit(clipping.kind.previewLineLimit)
                    .fixedSize(horizontal: false, vertical: true)

            case .url:
                HighlightedText(
                    resolvedTitle ?? clipping.titleLine,
                    highlights: resolvedTitle == nil ? scored.highlights : [],
                    font: Theme.Font.rowBody
                )
                .foregroundStyle(.primary)
                .lineLimit(1)

            case .file:
                Text(fileName)
                    .font(Theme.Font.rowBody.weight(.medium))
                    .lineLimit(1)

            case .image:
                Text(clipping.detail ?? "Image")
                    .font(Theme.Font.rowBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

            case .color:
                Text(clipping.payload)
                    .font(Theme.Font.rowBodyMono)
                    .lineLimit(1)

            case .text, .richText:
                HighlightedText(
                    textPreview,
                    highlights: scored.highlights,
                    font: Theme.Font.rowBody
                )
                .foregroundStyle(.primary)
                .lineLimit(clipping.kind.previewLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A concealed clipping renders as a visibly locked row rather than silently
    /// vanishing. The privacy behaviour is a thing you can *see*, which is worth
    /// more than the same promise buried in a settings pane.
    private var concealedBody: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Concealed")
                .font(Theme.Font.rowBody.weight(.medium))
                .foregroundStyle(.secondary)
            Text("· never saved to disk")
                .font(Theme.Font.metadata)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        HStack(spacing: 4) {
            Text(clipping.kind.token)
                .font(Theme.Font.badge)
                .foregroundStyle(Theme.accent(for: clipping.kind))

            if let detail = clipping.detail, !detail.isEmpty {
                Text("·").foregroundStyle(.quaternary)
                Text(detail)
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if clipping.kind == .code || clipping.kind == .text {
                Text("·").foregroundStyle(.quaternary)
                Text(sizeSummary)
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.tertiary)
            }

            if clipping.copyCount > 1 {
                Text("·").foregroundStyle(.quaternary)
                Text("×\(clipping.copyCount)")
                    .font(Theme.Font.metadata)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(Theme.Font.metadata)
    }

    // MARK: - Derived values

    private var codePreview: String {
        let lines = clipping.payload.split(separator: "\n", omittingEmptySubsequences: false)
        // Drop leading blank lines so the preview starts on something.
        let meaningful = Array(lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }))
        return meaningful.prefix(clipping.kind.previewLineLimit).joined(separator: "\n")
    }

    private var textPreview: String {
        clipping.payload
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(clipping.kind.previewLineLimit)
            .joined(separator: "\n")
    }

    private var firstPath: String {
        String(clipping.payload.split(separator: "\n").first ?? "")
    }

    private var fileName: String {
        (firstPath as NSString).lastPathComponent
    }

    private var sizeSummary: String {
        if clipping.kind == .code {
            return "\(clipping.lineCount) lines · \(ByteFormat.short(clipping.byteCount))"
        }
        return "\(clipping.wordCount) words"
    }

    private var accessibilityLabel: String {
        if clipping.isConcealed { return "Concealed clipping from \(clipping.sourceAppName ?? "unknown app")" }
        let source = clipping.sourceAppName ?? "unknown app"
        return "\(clipping.kind.token) from \(source): \(clipping.titleLine)"
    }
}
