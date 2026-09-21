import CoreGraphics
import Foundation
import Vision

/// Reads the text in an image, on the device, so a screenshot can be found by
/// what it says.
///
/// Vision's accurate recognizer takes a few hundred milliseconds per
/// screenshot, which is why this runs on its own serial queue after the copy
/// has already landed in the list: one image at a time, never on the main
/// thread, and never in the way of the next copy.
public final class TextRecognizer: Sendable {

    private let queue = DispatchQueue(label: "dev.cp.recognizer", qos: .utility)

    public init() {}

    /// The recognized lines, top to bottom, or `nil` when there is no text or the
    /// file cannot be read. Boxes are normalized with a top-left origin.
    public func recognize(pngAt url: URL) async -> (text: String, lines: [OCRLine])? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.recognizeNow(url))
            }
        }
    }

    private static func recognizeNow(_ url: URL) -> (text: String, lines: [OCRLine])? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // Vision's boxes have a bottom-left origin, like Core Graphics; views
            // and images drawn in SwiftUI count from the top.
            let box = observation.boundingBox
            lines.append(OCRLine(text: text, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
        }
        guard !lines.isEmpty else { return nil }
        return (lines.map(\.text).joined(separator: "\n"), lines)
    }
}
