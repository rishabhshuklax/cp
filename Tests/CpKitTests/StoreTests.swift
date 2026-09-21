import AppKit
import XCTest
@testable import CpKit

@MainActor
final class StoreTests: XCTestCase {

    private var directory: URL!
    private var settings: Settings!

    override func setUp() async throws {
        try await super.setUp()
        directory = TestDirectory.make(name)
        settings = Settings(defaults: MemoryDefaults())
    }

    override func tearDown() async throws {
        TestDirectory.remove(directory)
        try await super.tearDown()
    }

    private func makeStore(archive: Bool = true, recognizer: TextRecognizer? = nil) throws -> (ClippingStore, ClippingArchive?) {
        let archive = archive ? try ClippingArchive(directory: directory) : nil
        return (ClippingStore(archive: archive, settings: settings, recognizer: recognizer), archive)
    }

    private func logLines(_ archive: ClippingArchive?) -> Int {
        archive?.flush()
        let text = (try? String(contentsOf: directory.appendingPathComponent("history.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func concealed(_ reason: String) -> Clipping {
        Clipping(kind: .text, payload: "", sourceAppName: reason, isConcealed: true, detail: reason)
    }

    // MARK: - Concealed

    /// Fix 4: every concealed copy used to collapse into one row.
    func testConcealedCopiesKeepTheirOwnRowsAndSecrets() throws {
        let (store, archive) = try makeStore()
        let first = store.ingest(concealed("1Password"), secret: "hunter2-hunter2")
        let second = store.ingest(concealed("looks like a credential"), secret: "ghp_abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(store.clippings.count, 2)
        XCTAssertEqual(Set(store.clippings.compactMap(\.detail)), ["1Password", "looks like a credential"])
        XCTAssertEqual(store.secret(for: first.id), "hunter2-hunter2")
        XCTAssertEqual(store.secret(for: second.id), "ghp_abcdefghijklmnopqrstuvwxyz")
        XCTAssertNotNil(first.expiresAt)
        XCTAssertEqual(first.title, "Password")
        XCTAssertEqual(logLines(archive), 0, "never written")
        XCTAssertTrue(store.search(ClipQuery(text: "hunter2")).isEmpty, "the text is not searchable")
    }

    func testConcealedClippingsExpireWithTheirText() throws {
        settings.secretLifetime = 0.2
        let (store, _) = try makeStore(archive: false)
        let kept = store.ingest(concealed("1Password"), secret: "s3cret-s3cret")
        store.ingest(Clipping(kind: .text, payload: "ordinary"))
        XCTAssertEqual(store.secret(for: kept.id), "s3cret-s3cret")
        XCTAssertTrue(waitUntil { store.clipping(withID: kept.id) == nil })
        XCTAssertNil(store.secret(for: kept.id))
        XCTAssertEqual(store.clippings.map(\.payload), ["ordinary"])
    }

    func testZeroLifetimeKeepsNothing() throws {
        settings.secretLifetime = 0
        let (store, _) = try makeStore(archive: false)
        let returned = store.ingest(concealed("1Password"), secret: "s3cret-s3cret")
        XCTAssertTrue(store.clippings.isEmpty)
        XCTAssertNil(store.secret(for: returned.id))
    }

    func testForgetAndDeleteRemoveTheSecretNow() throws {
        let (store, _) = try makeStore(archive: false)
        let first = store.ingest(concealed("a"), secret: "one-one-one-one")
        let second = store.ingest(concealed("b"), secret: "two-two-two-two")
        store.forget(first.id)
        XCTAssertNil(store.secret(for: first.id))
        XCTAssertNil(store.delete(second.id), "nothing to undo for a secret")
        XCTAssertNil(store.secret(for: second.id))
        XCTAssertTrue(store.clippings.isEmpty)
    }

    // MARK: - Images

    /// Fix 2: two different same-size screenshots collapsed into one row and the
    /// second PNG was left on disk with nothing pointing at it.
    func testImagesDedupeOnTheirBytesAndLeaveNoOrphans() throws {
        let (store, archive) = try makeStore()
        let archiveValue = try XCTUnwrap(archive)
        func image(_ file: String, hash: String) -> Clipping {
            XCTAssertTrue(archiveValue.storeAsset(Data(file.utf8), filename: file))
            return Clipping(kind: .image, payload: "Image 2880×1800", assetFilename: file, contentHash: hash,
                            pixelWidth: 2_880, pixelHeight: 1_800)
        }
        store.ingest(image("red.png", hash: "aaaa"))
        store.ingest(image("blue.png", hash: "bbbb"))
        XCTAssertEqual(store.clippings.count, 2, "same size, different pictures")

        let again = store.ingest(image("red-again.png", hash: "aaaa"))
        XCTAssertEqual(store.clippings.count, 2)
        XCTAssertEqual(again.copyCount, 2)
        XCTAssertEqual(again.assetFilename, "red.png")
        XCTAssertEqual(store.clippings.first?.id, again.id)

        archiveValue.flush()
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: archiveValue.assetsDirectory.path))
        XCTAssertEqual(onDisk, Set(store.clippings.compactMap(\.assetFilename)))
    }

    // MARK: - History limit

    /// Fix 14: once the history was full, every copy rewrote the whole log.
    func testTrimmingAppendsTombstonesAndCompactsRarely() throws {
        settings.historyLimit = 50
        let (store, archive) = try makeStore()
        for index in 0..<50 { store.ingest(Clipping(kind: .text, payload: "copy \(index)")) }
        XCTAssertEqual(logLines(archive), 50)

        store.ingest(Clipping(kind: .text, payload: "one over the limit"))
        XCTAssertEqual(store.clippings.count, 50)
        XCTAssertEqual(logLines(archive), 52, "an upsert and a tombstone, not a rewrite")

        // The log is rewritten only once it passes max(256, 2 × live).
        var sawRewrite = false
        var previous = 52
        for index in 0..<150 {
            store.ingest(Clipping(kind: .text, payload: "more \(index)"))
            let lines = logLines(archive)
            if lines < previous { sawRewrite = true; XCTAssertEqual(lines, 50) }
            previous = lines
        }
        XCTAssertTrue(sawRewrite)
        XCTAssertLessThanOrEqual(previous, 257)

        let reloaded = ClippingStore(archive: try ClippingArchive(directory: directory), settings: settings, recognizer: nil)
        XCTAssertEqual(reloaded.clippings.map(\.id), store.clippings.map(\.id))
    }

    func testLoweringTheLimitTrimsAtOnce() throws {
        let (store, archive) = try makeStore()
        for index in 0..<120 { store.ingest(Clipping(kind: .text, payload: "copy \(index)")) }
        store.togglePin(try XCTUnwrap(store.clippings.last?.id))
        settings.historyLimit = 50
        XCTAssertTrue(waitUntil { store.clippings.count == 51 }, "50 plus the pin, without waiting for a copy")
        XCTAssertTrue(store.clippings.last?.isPinned == true)
        XCTAssertEqual(store.clippings.first?.payload, "copy 119")
        let reloaded = try ClippingArchive(directory: directory)
        archive?.flush()
        XCTAssertEqual(reloaded.load().count, 51)
    }

    // MARK: - Mutation

    func testOrderIsRecencyWithPinsInPlace() throws {
        let (store, _) = try makeStore(archive: false)
        let now = Date()
        store.ingest(Clipping(kind: .text, payload: "old", createdAt: now.addingTimeInterval(-300)))
        store.ingest(Clipping(kind: .text, payload: "new", createdAt: now))
        store.ingest(Clipping(kind: .text, payload: "middle", createdAt: now.addingTimeInterval(-100), isPinned: true))
        XCTAssertEqual(store.clippings.map(\.payload), ["new", "middle", "old"])
        let version = store.version
        store.ingest(Clipping(kind: .text, payload: "old", createdAt: now.addingTimeInterval(10)))
        XCTAssertEqual(store.clippings.map(\.payload), ["old", "new", "middle"])
        XCTAssertGreaterThan(store.version, version)
    }

    func testDeleteAndRestore() throws {
        let (store, archive) = try makeStore()
        let archiveValue = try XCTUnwrap(archive)
        XCTAssertTrue(archiveValue.storeAsset(Data([1, 2, 3]), filename: "shot.png"))
        let now = Date()
        let image = store.ingest(Clipping(kind: .image, payload: "Image 1×1", createdAt: now.addingTimeInterval(-60),
                                          assetFilename: "shot.png", contentHash: "cafe"))
        store.ingest(Clipping(kind: .text, payload: "newer", createdAt: now))

        let deleted = try XCTUnwrap(store.delete(image.id))
        archiveValue.flush()
        XCTAssertNil(store.clipping(withID: image.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveValue.assetURL(for: "shot.png").path))

        store.restore(deleted)
        archiveValue.flush()
        XCTAssertEqual(store.clippings.map(\.payload), ["newer", "Image 1×1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveValue.assetURL(for: "shot.png").path))
        XCTAssertEqual(store.assetURL("shot.png"), archiveValue.assetURL(for: "shot.png"))

        let reloaded = ClippingStore(archive: try ClippingArchive(directory: directory), settings: settings, recognizer: nil)
        XCTAssertEqual(reloaded.clippings.map(\.id), store.clippings.map(\.id))
    }

    func testBulkPinDeleteAndClear() throws {
        let (store, archive) = try makeStore()
        let clippings = (0..<5).map { store.ingest(Clipping(kind: .text, payload: "item \($0)")) }
        store.setPinned([clippings[0].id, clippings[1].id], true)
        store.delete([clippings[2].id, clippings[3].id])
        XCTAssertEqual(Set(store.clippings.map(\.payload)), ["item 0", "item 1", "item 4"])
        store.clearUnpinned()
        XCTAssertEqual(Set(store.clippings.map(\.payload)), ["item 0", "item 1"])
        archive?.flush()
        let reloaded = try ClippingArchive(directory: directory).load()
        XCTAssertEqual(Set(reloaded.map(\.payload)), ["item 0", "item 1"])
        XCTAssertTrue(reloaded.allSatisfy(\.isPinned))
    }

    // MARK: - Recognizing text

    func testRecognizesTextInImagesAfterIngest() throws {
        let (store, archive) = try makeStore(recognizer: TextRecognizer())
        let png = try XCTUnwrap(Self.textImage("Invoice 2291 total due"))
        XCTAssertTrue(try XCTUnwrap(archive).storeAsset(png, filename: "invoice.png"))
        let image = store.ingest(Clipping(kind: .image, payload: "Image", assetFilename: "invoice.png", contentHash: "1234"))
        XCTAssertNil(image.ocrText, "ingest returns at once; the text comes later")

        XCTAssertTrue(waitUntil(timeout: 20) { store.clipping(withID: image.id)?.ocrText != nil })
        let recognized = try XCTUnwrap(store.clipping(withID: image.id))
        XCTAssertTrue(recognized.ocrText?.contains("Invoice") == true, recognized.ocrText ?? "")
        XCTAssertFalse(recognized.ocrLines?.isEmpty ?? true)
        if let box = recognized.ocrLines?.first?.box {
            XCTAssertTrue((0...1).contains(box.minY) && box.maxY <= 1.0001)
            XCTAssertLessThan(box.minY, 0.5, "top-left origin: the text is drawn near the top")
        }
        XCTAssertEqual(store.search(ClipQuery(text: "invoice")).first?.field, .imageText)
    }

    func testRecognitionCanBeTurnedOff() throws {
        settings.recognizeText = false
        let (store, archive) = try makeStore(recognizer: TextRecognizer())
        let png = try XCTUnwrap(Self.textImage("Hello"))
        XCTAssertTrue(try XCTUnwrap(archive).storeAsset(png, filename: "hello.png"))
        let image = store.ingest(Clipping(kind: .image, payload: "Image", assetFilename: "hello.png", contentHash: "5678"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(store.clipping(withID: image.id)?.ocrText)
    }

    /// Black text near the top of a white 800×200 image.
    static func textImage(_ text: String) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 200, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 200).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 130), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
