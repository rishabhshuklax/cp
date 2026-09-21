import AppKit
import Foundation
import Observation

/// Watches a pasteboard and turns each change into a typed `Clipping`.
///
/// Polling `changeCount` is the only way to do this on macOS — there is no
/// pasteboard-changed notification, and there never has been. 250 ms is the usual
/// compromise: fast enough that the picker never shows stale history, slow enough
/// to be invisible in Activity Monitor, because the poll is a single integer read
/// and only a *change* costs a pasteboard read.
///
/// The read happens on the main thread and takes only bytes. Everything that
/// costs time — re-encoding a TIFF, hashing a screenshot, parsing RTF,
/// classifying a megabyte of text — runs on a serial queue, and `onCapture`
/// fires back on the main actor in the order the copies were made.
@Observable
@MainActor
public final class PasteboardMonitor {

    /// A capture, and for a concealed one its text, which must never go in the
    /// payload.
    public var onCapture: ((Clipping, _ secret: String?) -> Void)?

    /// When capturing resumes; `.distantFuture` until `resume()`. `nil` while
    /// capturing.
    public private(set) var pausedUntil: Date?

    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let archive: ClippingArchive?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount: Int
    /// Change counts of cp's own writes, as `Paster.write` reported them.
    @ObservationIgnored private var ignoredChangeCounts: Set<Int> = []
    @ObservationIgnored private let processing = DispatchQueue(label: "dev.cp.capture", qos: .userInitiated)

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

    /// Skip the change that produced this count: cp wrote it.
    public func ignore(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
    }

    /// Stop capturing for `duration` seconds, or until `resume()` when `nil`.
    public func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
    }

    public func resume() {
        pausedUntil = nil
    }

    // MARK: - Polling

    func poll() {
        if let until = pausedUntil, until <= Date() { pausedUntil = nil }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if ignoredChangeCounts.remove(changeCount) != nil { return }
        // A count that was never seen (two writes between polls) must not linger
        // and swallow some later copy.
        ignoredChangeCounts = ignoredChangeCounts.filter { $0 > changeCount }
        guard pausedUntil == nil else { return }

        let types = pasteboard.types ?? []
        if types.contains(Paster.ownPasteboardType) { return }
        guard let snapshot = read(types: types) else { return }

        let archive = self.archive
        processing.async { [weak self] in
            guard let capture = Self.capture(snapshot, archive: archive) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onCapture?(capture.clipping, capture.secret)
                }
            }
        }
    }

    /// Everything the capture needs, copied off the pasteboard in one go.
    struct Snapshot: Sendable {
        var createdAt = Date()
        var sourceBundleID: String?
        var sourceAppName: String?
        var sourceURL: String?
        var concealReason: String?
        var string: String?
        var fileURLs: [URL] = []
        var image: Data?
        var imageIsPNG = false
        var rtf: Data?
    }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]
    private static let sourceURLType = NSPasteboard.PasteboardType("org.chromium.source-url")

    private func read(types: [NSPasteboard.PasteboardType]) -> Snapshot? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var snapshot = Snapshot(sourceBundleID: frontmost?.bundleIdentifier, sourceAppName: frontmost?.localizedName)
        snapshot.string = pasteboard.string(forType: .string)

        switch PrivacyFilter.decide(
            types: types,
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            text: snapshot.string,
            ignoredBundleIDs: settings.ignoredBundleIDs
        ) {
        case .ignore:
            return nil
        case .conceal(let reason):
            snapshot.concealReason = reason
            return snapshot
        case .capture:
            break
        }

        snapshot.sourceURL = pasteboard.string(forType: Self.sourceURLType)

        // Read richest-first. A copy from Finder carries both a file URL and a
        // string; the file URL is the one worth keeping.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            snapshot.fileURLs = urls
            return snapshot
        }

        // Numbers, Excel and Pages put a picture of the cells next to the cells
        // themselves. Next to RTF or HTML and real text, an image is a rendering
        // of the document, and the document is what was copied.
        let isDocument = (types.contains(.rtf) || types.contains(.html)) && !(snapshot.string ?? "").isEmpty
        if !isDocument, let type = Self.imageTypes.first(where: types.contains), let data = pasteboard.data(forType: type) {
            snapshot.image = data
            snapshot.imageIsPNG = type == .png
            return snapshot
        }

        if types.contains(.rtf) {
            snapshot.rtf = pasteboard.data(forType: .rtf)
        }
        guard snapshot.rtf != nil || !(snapshot.string ?? "").isEmpty else { return nil }
        return snapshot
    }

    // MARK: - Off the main thread

    /// Builds the clipping. Runs on the capture queue: nothing here may touch
    /// the pasteboard or the main actor.
    nonisolated static func capture(_ snapshot: Snapshot, archive: ClippingArchive?) -> (clipping: Clipping, secret: String?)? {
        func clipping(
            kind: ClippingKind, payload: String, origin: ClipOrigin, detail: String?,
            byteCount: Int? = nil, isConcealed: Bool = false, assetFilename: String? = nil,
            contentHash: String? = nil, richAssetFilename: String? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil
        ) -> Clipping {
            Clipping(
                kind: kind, payload: payload, sourceBundleID: snapshot.sourceBundleID,
                sourceAppName: snapshot.sourceAppName, createdAt: snapshot.createdAt, isConcealed: isConcealed,
                assetFilename: assetFilename, byteCount: byteCount, detail: detail, contentHash: contentHash,
                origin: origin, richAssetFilename: richAssetFilename, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                sourceURL: snapshot.sourceURL
            )
        }

        if let reason = snapshot.concealReason {
            let concealed = clipping(kind: .text, payload: "", origin: .text, detail: reason,
                                     byteCount: snapshot.string?.utf8.count ?? 0, isConcealed: true)
            return (concealed, snapshot.string)
        }

        if !snapshot.fileURLs.isEmpty {
            let urls = snapshot.fileURLs
            let payload = urls.map(\.path).joined(separator: "\n")
            let detail = urls.count > 1
                ? "\(urls.count) files"
                : (urls[0].deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return (clipping(kind: .file, payload: payload, origin: .fileURLs, detail: detail), nil)
        }

        if let data = snapshot.image {
            guard let archive, let facts = ImageFacts.make(from: data, isPNG: snapshot.imageIsPNG) else { return nil }
            let filename = "\(UUID().uuidString).png"
            guard archive.storeAsset(facts.png, filename: filename) else { return nil }
            let size = "\(facts.pixelWidth)×\(facts.pixelHeight)"
            return (clipping(
                kind: .image, payload: "Image \(size)", origin: .image,
                detail: "\(size) · \(ByteFormat.short(facts.png.count))", byteCount: facts.png.count,
                assetFilename: filename, contentHash: facts.hash,
                pixelWidth: facts.pixelWidth, pixelHeight: facts.pixelHeight
            ), nil)
        }

        if let rtf = snapshot.rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            let plain = snapshot.string ?? attributed.string
            guard !plain.isEmpty else { return nil }
            let classified = Classifier.classify(plain)
            // A link, a path or code keeps its own kind even when it arrives
            // wrapped in RTF (Xcode colours every snippet it copies).
            if classified.kind == .text, RichText.hasRealFormatting(attributed), let archive {
                let filename = "\(UUID().uuidString).rtf"
                if archive.storeAsset(rtf, filename: filename) {
                    return (clipping(
                        kind: .richText, payload: plain, origin: .richText,
                        detail: "styled · \(ByteFormat.short(rtf.count))", richAssetFilename: filename
                    ), nil)
                }
            }
            return (clipping(kind: classified.kind, payload: plain, origin: .richText, detail: classified.detail), nil)
        }

        guard let text = snapshot.string, !text.isEmpty else { return nil }
        let classified = Classifier.classify(text)
        return (clipping(kind: classified.kind, payload: text, origin: .text, detail: classified.detail), nil)
    }
}
