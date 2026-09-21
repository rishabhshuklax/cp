import AppKit
import XCTest
@testable import CpKit

/// Everything here writes to a private, named pasteboard — never the general
/// one — and releases it afterwards.
@MainActor
final class PasterTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var paster: Paster!

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.cp.tests.\(UUID().uuidString)"))
        paster = Paster(pasteboard: pasteboard)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try await super.tearDown()
    }

    private var everyItemIsMarked: Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        return items.allSatisfy { $0.types.contains(Paster.ownPasteboardType) }
    }

    /// Fix 1: the change count to ignore is the one after the write, and the
    /// write is marked as cp's own.
    func testWriteReturnsTheCountItLandedAtAndMarksItsItems() {
        let before = pasteboard.changeCount
        let count = paster.write(PastePayload(string: "hello"))
        XCTAssertEqual(count, pasteboard.changeCount)
        XCTAssertGreaterThan(count, before)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertTrue(everyItemIsMarked)
    }

    /// Fix 3: file references come with their paths as plain text.
    func testFileURLsCarryTheirPathsAsText() {
        let urls = [URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/Users/me/b c.png")]
        paster.write(PastePayload(fileURLs: urls))
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read, urls)
        XCTAssertEqual(pasteboard.string(forType: .string), "/Users/me/a.txt\n/Users/me/b c.png")
        XCTAssertTrue(everyItemIsMarked)
    }

    func testPlainTextHasNoFileFlavour() {
        paster.write(PastePayload(string: "/Users/me/a.txt"))
        XCTAssertNil(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first)
        XCTAssertEqual(pasteboard.string(forType: .string), "/Users/me/a.txt")
    }

    func testImagesWritePNGAndOfferTIFFOnDemand() throws {
        let png = try XCTUnwrap(StoreTests.textImage("PNG"))
        paster.write(PastePayload(png: png))
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.png))
        XCTAssertTrue(types.contains(.tiff))
        XCTAssertEqual(pasteboard.data(forType: .png), png)
        let tiff = try XCTUnwrap(pasteboard.data(forType: .tiff))
        XCTAssertEqual(NSBitmapImageRep(data: tiff)?.pixelsWide, 800)
    }

    func testRichTextWritesRTFAndString() {
        let rtf = Data("{\\rtf1 hi}".utf8)
        paster.write(PastePayload(string: "hi", rtf: rtf))
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
        XCTAssertEqual(pasteboard.string(forType: .string), "hi")
    }

    /// No keystroke is ever posted from these: automatic off, or no target.
    func testPasteThatCannotReachATargetOnlyCopies() {
        var outcomes: [PasteOutcome] = []
        paster.paste(into: nil, automatic: false) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.copiedOnly(.turnedOff)])

        paster.paste(into: nil, automatic: true) { outcomes.append($0) }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue([.copiedOnly(.notAllowed), .copiedOnly(.targetGone)].contains(outcomes[1]), "\(outcomes[1])")

        paster.replaceLastPaste(with: PastePayload(string: "swapped"), in: nil) { outcomes.append($0) }
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertNotEqual(outcomes[2], .pasted(appName: nil))
        XCTAssertEqual(pasteboard.string(forType: .string), "swapped", "the new format lands on the pasteboard anyway")
    }
}
