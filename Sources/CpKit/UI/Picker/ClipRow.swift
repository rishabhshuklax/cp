import AppKit
import SwiftUI

/// One line of history.
///
/// Deliberately one line, 38pt: a thumbnail, what the clipping says, and when.
/// The first build gave every row three lines, a kind label, a word count and
/// an ⌥ badge — nine rows on screen, none of them scannable. What a row needs
/// is the one string you would recognise it by, and everything else on the row
/// you have selected, in the hero.
public struct ClipRow: View {

    private let hit: ClipHit
    private let index: Int
    private let isSelected: Bool
    private let showsKeycap: Bool
    private let stackPosition: Int?
    private let store: ClippingStore
    private let links: LinkPreviews
    private let now: Date

    private var clipping: Clipping { hit.clipping }

    public init(
        hit: ClipHit,
        index: Int,
        isSelected: Bool,
        showsKeycap: Bool,
        stackPosition: Int?,
        store: ClippingStore,
        links: LinkPreviews,
        now: Date = Date()
    ) {
        self.hit = hit
        self.index = index
        self.isSelected = isSelected
        self.showsKeycap = showsKeycap
        self.stackPosition = stackPosition
        self.store = store
        self.links = links
        self.now = now
    }

    public var body: some View {
        HStack(spacing: 11) {
            ClipThumb(clipping: clipping, store: store, links: links, stackPosition: stackPosition)
            title
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if clipping.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.ink3)
            }
            trailing
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(height: Theme.Metric.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous)
                .fill(isSelected ? Theme.selection : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metric.rowCorner, style: .continuous)
                        .strokeBorder(isSelected ? Theme.selectionEdge : .clear, lineWidth: 1)
                }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Title

    @ViewBuilder
    private var title: some View {
        if clipping.isConcealed {
            HStack(spacing: 0) {
                Text("Password ")
                Text(secretCountdown).foregroundStyle(Theme.ink3)
            }
            .font(Theme.Font.row)
            .foregroundStyle(Theme.ink)
        } else {
            switch clipping.kind {
            case .url:
                HStack(spacing: 6) {
                    Text(MarkedText.highlighted(clipping.displayTitle, ranges: hit.titleRanges))
                    if let host = clipping.host, clipping.displayTitle != clipping.payload {
                        Text("— \(host)").foregroundStyle(Theme.ink3)
                    }
                }
                .font(Theme.Font.row)
                .foregroundStyle(Theme.ink)
            case .image:
                imageTitle
            case .file:
                HStack(spacing: 6) {
                    Text(MarkedText.highlighted(clipping.displayTitle, ranges: hit.titleRanges))
                    Text(folder).foregroundStyle(Theme.ink3)
                }
                .font(Theme.Font.row)
                .foregroundStyle(Theme.ink)
            case .color, .code, .json:
                bodyOrTitle.font(Theme.Font.rowMono).foregroundStyle(Theme.ink)
            case .text, .richText:
                bodyOrTitle.font(Theme.Font.row).foregroundStyle(Theme.ink)
            }
        }
    }

    /// When the match was in the body rather than the title, the row shows the
    /// line that matched — otherwise a search finds a row that does not visibly
    /// contain what you typed.
    @ViewBuilder
    private var bodyOrTitle: some View {
        if let snippet = hit.snippet, hit.field == .body {
            Text(MarkedText.highlighted(snippet, ranges: hit.snippetRanges))
        } else {
            Text(MarkedText.highlighted(clipping.displayTitle, ranges: hit.titleRanges))
        }
    }

    @ViewBuilder
    private var imageTitle: some View {
        if hit.field == .imageText, let snippet = hit.snippet {
            HStack(spacing: 6) {
                Text("Text in image")
                    .font(Theme.Font.rowTime)
                    .foregroundStyle(Theme.ink3)
                Text(MarkedText.highlighted(snippet, ranges: hit.snippetRanges))
                    .font(Theme.Font.row)
                    .foregroundStyle(Theme.ink)
            }
        } else {
            HStack(spacing: 6) {
                Text(clipping.displayTitle)
                if let size = pixelSize {
                    Text(size).foregroundStyle(Theme.ink3)
                }
            }
            .font(Theme.Font.row)
            .foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        if showsKeycap, index < 9 {
            Keycap("⌘\(index + 1)")
        } else {
            Text(RelativeTime.short(clipping.lastCopiedAt, now: now))
                .font(Theme.Font.rowTime)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
        }
    }

    // MARK: - Strings

    private var pixelSize: String? {
        guard let width = clipping.pixelWidth, let height = clipping.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    private var folder: String {
        let first = String(clipping.payload.split(separator: "\n").first ?? "")
        return (first as NSString).deletingLastPathComponent
    }

    private var secretCountdown: String {
        guard let expiry = clipping.expiresAt else { return "· not saved" }
        return "· forgets in \(RelativeTime.secondsLeft(until: expiry, now: now))s"
    }

    private var accessibilityLabel: String {
        let source = clipping.sourceAppName ?? "an unknown app"
        if clipping.isConcealed { return "Password from \(source), not saved" }
        return "\(clipping.displayTitle), from \(source), \(RelativeTime.short(clipping.lastCopiedAt, now: now))"
    }
}
