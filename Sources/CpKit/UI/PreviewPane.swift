import AppKit
import SwiftUI

/// The right-hand pane. Tracks the *selection*, not the mouse.
///
/// This is the single biggest usability change from the popover model. A preview
/// that appears on hover after a delay is unreachable from the keyboard, so the
/// keyboard-first path — the one 95% of uses take — never gets to see the full
/// content it is choosing between. Binding it to selection instead means arrowing
/// down updates the preview instantly, and the hover delay disappears because
/// there is no hover.
public struct PreviewPane: View {

    private let clipping: Clipping?
    private let archive: ClippingArchive?
    private let resolvedTitle: String?
    private let onTransform: (PasteFormat) -> Void

    public init(
        clipping: Clipping?,
        archive: ClippingArchive?,
        resolvedTitle: String? = nil,
        onTransform: @escaping (PasteFormat) -> Void
    ) {
        self.clipping = clipping
        self.archive = archive
        self.resolvedTitle = resolvedTitle
        self.onTransform = onTransform
    }

    public var body: some View {
        Group {
            if let clipping {
                content(for: clipping)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text("Nothing to preview")
                .font(Theme.Font.rowBody)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for clipping: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(for: clipping)
            Divider().overlay(Theme.separator)

            ScrollView {
                payloadView(for: clipping)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let formats = Array(PasteFormats.menu(for: clipping).dropFirst())
            if !formats.isEmpty {
                Divider().overlay(Theme.separator)
                transformBar(formats, for: clipping)
            }
        }
    }

    // MARK: - Heading

    private func heading(for clipping: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: clipping.kind.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent(for: clipping.kind))
                Text(resolvedTitle ?? headingTitle(for: clipping))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
            }

            HStack(spacing: 5) {
                if let name = clipping.sourceAppName {
                    Label(name, systemImage: "app.badge")
                        .labelStyle(.titleAndIcon)
                }
                Text("·").foregroundStyle(.quaternary)
                Text(fullTimestamp(clipping.lastCopiedAt))
                if clipping.copyCount > 1 {
                    Text("·").foregroundStyle(.quaternary)
                    Text("copied \(clipping.copyCount)×")
                }
                if clipping.byteCount > 0 {
                    Text("·").foregroundStyle(.quaternary)
                    Text(ByteFormat.short(clipping.byteCount))
                }
            }
            .font(Theme.Font.metadata)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingTitle(for clipping: Clipping) -> String {
        switch clipping.kind {
        case .file: return (String(clipping.payload.split(separator: "\n").first ?? "") as NSString).lastPathComponent
        case .image: return clipping.detail ?? "Image"
        default: return clipping.titleLine
        }
    }

    // MARK: - Payload

    @ViewBuilder
    private func payloadView(for clipping: Clipping) -> some View {
        if clipping.isConcealed {
            concealedNotice(reason: clipping.detail)
        } else {
            switch clipping.kind {
            case .image:
                imagePreview(for: clipping)
            case .color:
                colorPreview(for: clipping)
            case .code, .json:
                Text(clipping.payload)
                    .font(Theme.Font.previewMono)
                    .textSelection(.enabled)
            case .file:
                filePreview(for: clipping)
            default:
                Text(clipping.payload)
                    .font(Theme.Font.previewBody)
                    .textSelection(.enabled)
            }
        }
    }

    private func concealedNotice(reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Concealed", systemImage: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("This clipping was marked private by \(reason ?? "its source app"), so its contents were never stored — not in memory beyond this session, and not on disk.")
                .font(Theme.Font.rowBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func imagePreview(for clipping: Clipping) -> some View {
        if let filename = clipping.assetFilename,
           let archive,
           let data = try? Data(contentsOf: archive.assetURL(for: filename)),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Text("Image unavailable")
                .font(Theme.Font.rowBody)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func colorPreview(for clipping: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let color = ColorParser.color(from: clipping.payload) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(height: 110)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    }
            }
            Text(clipping.payload)
                .font(Theme.Font.previewMono)
                .textSelection(.enabled)
        }
    }

    private func filePreview(for clipping: Clipping) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(clipping.payload.split(separator: "\n").enumerated()), id: \.offset) { _, path in
                HStack(spacing: 7) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: String(path)))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(String(path))
                        .font(Theme.Font.previewMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Transforms

    private func transformBar(_ formats: [PasteFormat], for clipping: Clipping) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(formats, id: \.self) { format in
                    Button {
                        onTransform(format)
                    } label: {
                        Label(format.menuLabel(for: clipping), systemImage: format.symbolName)
                            .font(Theme.Font.metadata)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func fullTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
