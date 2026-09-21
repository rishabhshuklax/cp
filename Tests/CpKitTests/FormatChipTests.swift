import AppKit
import XCTest
@testable import CpKit

@MainActor
final class FormatChipTests: XCTestCase {

    private var settings: Settings!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings(defaults: MemoryDefaults())
    }

    private func clip(_ payload: String, kind: ClippingKind? = nil, origin: ClipOrigin? = nil,
                      linkTitle: String? = nil, ocr: String? = nil, concealed: Bool = false) -> Clipping {
        let classified = Classifier.classify(payload)
        return Clipping(kind: kind ?? classified.kind, payload: payload, isConcealed: concealed,
                        detail: classified.detail, origin: origin, ocrText: ocr, linkTitle: linkTitle)
    }

    private func labels(_ clipping: Clipping) -> [String] {
        PasteFormats.chip(for: clipping).map { $0.chipLabel(for: clipping) }
    }

    /// The chip offers exactly what the kind can be: no menu, no guessing.
    func testChipFormatsPerKind() {
        XCTAssertEqual(labels(clip("https://example.com/a")), ["Link", "Markdown"])
        XCTAssertEqual(labels(clip("https://example.com/a?utm_source=x")), ["Link", "Markdown", "Clean"])
        XCTAssertEqual(labels(clip("https://example.com/a", linkTitle: "A page")), ["Link", "Title", "Markdown"])
        XCTAssertEqual(labels(clip("one\ntwo")), ["As copied", "One line"])
        XCTAssertEqual(labels(clip("just one line")), [], "nothing else it could be")
        XCTAssertEqual(labels(clip("some words", kind: .richText)), ["Rich", "Plain", "Markdown"])
        XCTAssertEqual(labels(clip("#FF5A36")), ["HEX", "RGB", "HSL", "SwiftUI"])
        XCTAssertEqual(labels(clip("{\"a\":1}")), ["Formatted", "One line"])
        XCTAssertEqual(labels(clip("func a() {\n    b()\n}")), ["Plain", "Code block"])
        XCTAssertEqual(labels(clip("Image 8×6", kind: .image, ocr: "invoice")), ["Image", "Text"])
        XCTAssertEqual(labels(clip("Image 8×6", kind: .image)), [], "no text in it to offer")
        XCTAssertEqual(labels(clip("/Users/me/a.txt", origin: .fileURLs)), ["File", "Path"])
        XCTAssertEqual(labels(clip("/Users/me/a.txt")), [], "it arrived as text, so it is text")
        XCTAssertEqual(labels(clip("", concealed: true)), [], "a password gets no second thoughts")
    }

    // MARK: - Placement

    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    private let chipSize = CGSize(width: 200, height: 40)

    func testTheChipSitsUnderTheCaretWhenThereIsOne() {
        let caret = CGRect(x: 700, y: 500, width: 2, height: 20)
        let origin = ChipPlacement.origin(
            chipSize: chipSize, caret: caret, window: CGRect(x: 100, y: 100, width: 800, height: 600),
            pointer: CGPoint(x: 10, y: 10), screen: screen
        )
        XCTAssertEqual(origin.x, caret.midX - chipSize.width / 2)
        XCTAssertEqual(origin.y, caret.minY - chipSize.height - 2, "just below the caret")
    }

    /// Chrome and Electron answer with an empty rect; that is not an answer.
    func testAnEmptyOrNonsenseCaretFallsBackToTheWindow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        for caret in [CGRect.zero, CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan), CGRect.infinite, CGRect.null] {
            let origin = ChipPlacement.origin(
                chipSize: chipSize, caret: caret, window: window,
                pointer: CGPoint(x: 10, y: 10), screen: screen
            )
            XCTAssertEqual(origin.x, window.midX - chipSize.width / 2, "\(caret)")
            XCTAssertEqual(origin.y, window.minY + 24, "\(caret)")
        }
    }

    func testWithNoCaretAndNoWindowItGoesByThePointer() {
        let pointer = CGPoint(x: 600, y: 400)
        let origin = ChipPlacement.origin(
            chipSize: chipSize, caret: nil, window: nil, pointer: pointer, screen: screen
        )
        XCTAssertEqual(origin.x, pointer.x - chipSize.width / 2)
        XCTAssertEqual(origin.y, pointer.y - chipSize.height - 18)
    }

    func testItIsAlwaysOnScreen() {
        let atTheEdge = ChipPlacement.origin(
            chipSize: chipSize, caret: CGRect(x: 1_430, y: 10, width: 2, height: 20),
            window: nil, pointer: .zero, screen: screen
        )
        XCTAssertEqual(atTheEdge.x, screen.maxX - chipSize.width - 12)
        XCTAssertEqual(atTheEdge.y, screen.minY + 12, "a caret near the bottom pushes the chip back up")

        let offTheTop = ChipPlacement.origin(
            chipSize: chipSize, caret: CGRect(x: -50, y: 890, width: 2, height: 20),
            window: nil, pointer: .zero, screen: screen
        )
        XCTAssertEqual(offTheTop.x, screen.minX + 12)
    }
}
