import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What capture needs to know about an image, worked out off the main thread:
/// PNG bytes, their hash, and the size in pixels.
///
/// Image I/O reads the pixel size from the file's header without decoding it,
/// and re-encodes TIFF (what Preview and many apps put on the pasteboard) as
/// PNG. Both used to happen on the main thread through `NSImage`, which cost up
/// to half a second per screenshot and reported a Retina screenshot at half its
/// size.
struct ImageFacts: Sendable {
    let png: Data
    let hash: String
    let pixelWidth: Int
    let pixelHeight: Int

    /// From pasteboard bytes. PNG passes through untouched; TIFF, JPEG and HEIC
    /// become PNG, keeping their resolution metadata so a Retina image still
    /// pastes back at its point size.
    static func make(from data: Data, isPNG: Bool) -> ImageFacts? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        if isPNG {
            guard let size = pixelSize(source) else { return nil }
            return ImageFacts(png: data, hash: hash(data), pixelWidth: size.width, pixelHeight: size.height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        guard CGImageDestinationFinalize(destination) else { return nil }
        let png = output as Data
        return ImageFacts(png: png, hash: hash(png), pixelWidth: image.width, pixelHeight: image.height)
    }

    /// Hash and pixel size of a PNG already on disk, for images captured before
    /// either was recorded.
    static func read(fileAt url: URL) -> (hash: String, pixelWidth: Int, pixelHeight: Int)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = pixelSize(source) else { return nil }
        return (hash(data), size.width, size.height)
    }

    /// SHA-256, hex, first 32 characters.
    static func hash(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: hex.prefix(32), as: UTF8.self)
    }

    private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return (height, width)
        }
        return (width, height)
    }
}
