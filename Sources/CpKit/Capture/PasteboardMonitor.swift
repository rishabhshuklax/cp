import AppKit
import Foundation

/// Watches `NSPasteboard.general` and turns each change into a typed `Clipping`.
///
/// Polling `changeCount` is the only way to do this on macOS — there is no
/// pasteboard-changed notification, and there never has been. 250 ms is the usual
/// compromise: fast enough that the picker never shows stale history, slow enough
/// to be invisible in Activity Monitor, because the poll is a single integer read
/// and only a *change* costs a pasteboard read.
@MainActor
public final class PasteboardMonitor {

    public typealias CaptureHandler = (Clipping) -> Void

    private let pasteboard: NSPasteboard
    private let settings: Settings
    private let archive: ClippingArchive?
    private var timer: Timer?
    private var lastChangeCount: Int

    /// Set when we write to the pasteboard ourselves, so choosing an item doesn't
    /// immediately re-capture it and shuffle the history under the user.
    private var suppressedChangeCount: Int?

    public var onCapture: CaptureHandler?

    public init(
        pasteboard: NSPasteboard = .general,
        settings: Settings,
        archive: ClippingArchive?
    ) {
        self.pasteboard = pasteboard
        self.settings = settings
        self.archive = archive
        self.lastChangeCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.25) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // .common so the poll keeps running while a menu is open or a window is
        // being resized — otherwise copies made mid-drag land late or not at all.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call immediately after writing to the pasteboard on the app's own behalf.
    public func suppressNextChange() {
        suppressedChangeCount = pasteboard.changeCount + 1
    }

    // MARK: - Polling

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let suppressed = suppressedChangeCount, suppressed == changeCount {
            suppressedChangeCount = nil
            return
        }

        guard let clipping = readCurrentItem() else { return }
        onCapture?(clipping)
    }

    private func readCurrentItem() -> Clipping? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let text = pasteboard.string(forType: .string)

        let decision = PrivacyFilter.decide(
            pasteboard: pasteboard,
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            text: text,
            ignoredBundleIDs: settings.ignoredBundleIDs
        )

        switch decision {
        case .ignore:
            return nil
        case .conceal(let reason):
            return Clipping(
                kind: .text,
                payload: "",
                sourceBundleID: frontmost?.bundleIdentifier,
                sourceAppName: frontmost?.localizedName,
                isConcealed: true,
                byteCount: text?.utf8.count ?? 0,
                detail: reason
            )
        case .capture:
            break
        }

        // Read richest-first. A copy from Finder carries both a file URL and a
        // string; the file URL is the one worth keeping, because it is the one that
        // can render an icon and reveal itself later.
        if let clipping = readFileURL(frontmost: frontmost) { return clipping }
        if let clipping = readImage(frontmost: frontmost) { return clipping }
        if let clipping = readRichText(frontmost: frontmost, plainText: text) { return clipping }

        guard let text, !text.isEmpty else { return nil }
        let classified = Classifier.classify(text)
        return Clipping(
            kind: classified.kind,
            payload: text,
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            byteCount: text.utf8.count,
            detail: classified.detail
        )
    }

    private func readFileURL(frontmost: NSRunningApplication?) -> Clipping? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let first = urls.first else { return nil }

        let payload = urls.map(\.path).joined(separator: "\n")
        let detail: String
        if urls.count > 1 {
            detail = "\(urls.count) files"
        } else {
            detail = (first.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }

        return Clipping(
            kind: .file,
            payload: payload,
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            byteCount: payload.utf8.count,
            detail: detail
        )
    }

    private func readImage(frontmost: NSRunningApplication?) -> Clipping? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard let type = imageTypes.first(where: { pasteboard.data(forType: $0) != nil }),
              let data = pasteboard.data(forType: type),
              let image = NSImage(data: data) else { return nil }

        // Normalise to PNG so the assets directory holds one format and thumbnails
        // are cheap to decode.
        let pngData: Data
        if type == .png {
            pngData = data
        } else if let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let converted = rep.representation(using: .png, properties: [:]) {
            pngData = converted
        } else {
            return nil
        }

        let filename = "\(UUID().uuidString).png"
        guard archive?.storeAsset(pngData, filename: filename) == true else { return nil }

        let size = image.size
        return Clipping(
            kind: .image,
            payload: "Image \(Int(size.width))×\(Int(size.height))",
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            assetFilename: filename,
            byteCount: pngData.count,
            detail: "\(Int(size.width))×\(Int(size.height)) · \(ByteFormat.short(pngData.count))"
        )
    }

    private func readRichText(frontmost: NSRunningApplication?, plainText: String?) -> Clipping? {
        guard let data = pasteboard.data(forType: .rtf),
              let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }

        let plain = plainText ?? attributed.string
        guard !plain.isEmpty else { return nil }

        // Rich text that carries no actual formatting is just text, and typing it as
        // `.richText` would only cost it a better-fitting row.
        var hasAttributes = false
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attrs, _, stop in
            if attrs[.link] != nil || attrs[.font] != nil || attrs[.foregroundColor] != nil {
                hasAttributes = true
                stop.pointee = true
            }
        }
        guard hasAttributes else { return nil }

        let classified = Classifier.classify(plain)
        // A URL or colour keeps its own type even when it arrives wrapped in RTF.
        guard classified.kind == .text else {
            return Clipping(
                kind: classified.kind,
                payload: plain,
                sourceBundleID: frontmost?.bundleIdentifier,
                sourceAppName: frontmost?.localizedName,
                byteCount: plain.utf8.count,
                detail: classified.detail
            )
        }

        return Clipping(
            kind: .richText,
            payload: plain,
            sourceBundleID: frontmost?.bundleIdentifier,
            sourceAppName: frontmost?.localizedName,
            byteCount: data.count,
            detail: "styled · \(ByteFormat.short(data.count))"
        )
    }
}
