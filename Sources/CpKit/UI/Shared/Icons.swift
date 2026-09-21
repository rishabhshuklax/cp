import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// App icons, by bundle identifier.
///
/// Every row draws one, so this is on the scroll path: `NSWorkspace.icon(forFile:)`
/// hits the filesystem, and doing that per row per frame is what makes a list
/// feel cheap.
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

/// Document icons, by path. Finder's own icon for a file that exists, the
/// type's icon for one that no longer does.
@MainActor
public final class FileIconProvider {
    public static let shared = FileIconProvider()

    private var cache: [String: NSImage] = [:]

    private init() {}

    public func icon(forPath path: String) -> NSImage {
        let key = FileManager.default.fileExists(atPath: path) ? path : "ext:\((path as NSString).pathExtension.lowercased())"
        if let cached = cache[key] { return cached }
        let icon: NSImage
        if key.hasPrefix("ext:") {
            let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(forFile: path)
        }
        icon.size = NSSize(width: 64, height: 64)
        cache[key] = icon
        return icon
    }
}

/// Image thumbnails, decoded off the main thread and kept.
///
/// Decoding a 5K screenshot on the main thread to draw it 22pt wide is what
/// made the old list stutter. Image I/O scales while it decodes, so the work is
/// proportional to the thumbnail, not to the file.
@MainActor
@Observable
public final class ThumbnailStore {
    public static let shared = ThumbnailStore()

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let maximumEntries = 400

    private init() {}

    /// The thumbnail if it is ready; otherwise nil now and a redraw when it is.
    public func thumbnail(filename: String, url: URL?, maxPixel: CGFloat) -> NSImage? {
        let key = "\(filename)@\(Int(maxPixel))"
        if let image = images[key] { return image }
        guard let url, !loading.contains(key) else { return nil }
        loading.insert(key)
        Task.detached(priority: .userInitiated) {
            let image = Self.decode(url: url, maxPixel: maxPixel)
            await MainActor.run { self.store(image, forKey: key) }
        }
        return nil
    }

    private func store(_ image: NSImage?, forKey key: String) {
        loading.remove(key)
        guard let image else { return }
        if images.count >= maximumEntries { images.removeAll(keepingCapacity: true) }
        images[key] = image
    }

    nonisolated private static func decode(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// The stand-in for a site with no favicon yet: its first letter on a rounded
/// square, the same shape an app icon has.
public struct LetterMark: View {
    private let text: String
    private let size: CGFloat

    public init(_ text: String, size: CGFloat) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(nsColor: .systemGray).opacity(0.55))
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.52, weight: .heavy))
                    .foregroundStyle(.white)
            }
    }

    private var letter: String {
        let stripped = text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
        return String(stripped.first ?? "?").uppercased()
    }
}
