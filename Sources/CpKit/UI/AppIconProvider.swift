import AppKit
import SwiftUI

/// Caches app icons by bundle identifier.
///
/// Every row draws one, so this is on the scroll path: `NSWorkspace.icon(forFile:)`
/// hits the filesystem, and doing that per row per frame is exactly the kind of
/// thing that makes a SwiftUI list feel cheap.
@MainActor
public final class AppIconProvider {
    public static let shared = AppIconProvider()

    private var cache: [String: NSImage] = [:]
    private var misses: Set<String> = []

    private init() {}

    public func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard !misses.contains(bundleID) else { return nil }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            misses.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        cache[bundleID] = icon
        return icon
    }
}

/// Caches decoded image thumbnails so scrolling a grid of screenshots doesn't
/// re-decode a PNG per frame.
@MainActor
public final class ThumbnailProvider {
    public static let shared = ThumbnailProvider()

    private var cache: [String: NSImage] = [:]
    private let maximumEntries = 300

    private init() {}

    public func thumbnail(filename: String, archive: ClippingArchive?, size: CGFloat) -> NSImage? {
        let key = "\(filename)@\(Int(size))"
        if let cached = cache[key] { return cached }
        guard let archive,
              let data = try? Data(contentsOf: archive.assetURL(for: filename)),
              let image = NSImage(data: data) else { return nil }

        let thumbnail = image.thumbnail(fitting: size)
        if cache.count >= maximumEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = thumbnail
        return thumbnail
    }
}

extension NSImage {
    /// Aspect-fit downscale. Never upscales — a 16×16 favicon rendered at 40pt
    /// looks like a mistake.
    func thumbnail(fitting dimension: CGFloat) -> NSImage {
        let originalSize = size
        guard originalSize.width > 0, originalSize.height > 0 else { return self }

        let scale = min(dimension / originalSize.width, dimension / originalSize.height, 1)
        let target = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .sourceOver,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }
}
