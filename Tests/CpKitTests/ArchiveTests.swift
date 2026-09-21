import XCTest
@testable import CpKit

final class ArchiveTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestDirectory.make(name)
    }

    override func tearDown() {
        TestDirectory.remove(directory)
        super.tearDown()
    }

    private var logURL: URL { directory.appendingPathComponent("history.jsonl") }

    /// Lines exactly as version 0.1 wrote them: whole-second dates, escaped slashes,
    /// none of the redesign's fields.
    private let legacyLines = [
        #"{"upsert":{"_0":{"lastCopiedAt":"2026-09-21T12:07:07Z","copyCount":1,"sourceAppName":"System Settings","byteCount":36,"kind":"text","id":"26447945-C1CB-442F-9302-46EEFBAFBF5A","createdAt":"2026-09-21T12:07:07Z","payload":"hello world, plain prose from a chat","isPinned":true,"isConcealed":false,"sourceBundleID":"com.apple.systempreferences"}}}"#,
        #"{"upsert":{"_0":{"lastCopiedAt":"2026-09-18T02:09:02Z","sourceAppName":"Terminal","copyCount":1,"id":"F94174EF-2F81-4E91-B0A8-485AEA235482","byteCount":18,"kind":"file","detail":"\/var\/log","createdAt":"2026-09-18T02:09:02Z","sourceBundleID":"com.apple.Terminal","payload":"\/var\/log\/idgah.log","isPinned":true,"isConcealed":false}}}"#,
        #"{"upsert":{"_0":{"lastCopiedAt":"2026-09-21T12:57:52Z","copyCount":1,"id":"AAF723D0-B755-42BC-8F4F-5818091D5B0C","byteCount":233,"kind":"image","createdAt":"2026-09-21T12:57:52Z","payload":"Image 64×64","isPinned":false,"assetFilename":"280FE821-5811-4580-8D57-934D21B0CECD.png","isConcealed":false}}}"#,
        #"{"upsert":{"_0":{"lastCopiedAt":"2026-09-21T12:07:11Z","copyCount":1,"byteCount":0,"kind":"text","id":"673579C0-CFBA-4A5D-9D6B-22B3D563DD62","createdAt":"2026-09-21T12:07:11Z","payload":"filler 59","isPinned":false,"isConcealed":false}}}"#,
        #"{"delete":{"_0":"673579C0-CFBA-4A5D-9D6B-22B3D563DD62"}}"#,
    ]

    func testHistoryWrittenBeforeTheRedesignStillLoads() throws {
        try (legacyLines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        let loaded = try ClippingArchive(directory: directory).load()

        XCTAssertEqual(loaded.count, 3, "the deleted one stays deleted")
        let text = try XCTUnwrap(loaded.first { $0.kind == .text })
        XCTAssertEqual(text.payload, "hello world, plain prose from a chat")
        XCTAssertEqual(text.title, "hello world, plain prose from a chat")
        XCTAssertEqual(text.wordCount, 7)
        XCTAssertEqual(text.lineCount, 1)
        XCTAssertEqual(text.origin, .text)
        XCTAssertTrue(text.isPinned)
        XCTAssertEqual(text.sourceBundleID, "com.apple.systempreferences")
        XCTAssertEqual(text.createdAt, try Date("2026-09-21T12:07:07Z", strategy: .iso8601))

        let file = try XCTUnwrap(loaded.first { $0.kind == .file })
        XCTAssertEqual(file.payload, "/var/log/idgah.log")
        XCTAssertEqual(file.title, "idgah.log")
        XCTAssertEqual(file.detail, "/var/log")

        let image = try XCTUnwrap(loaded.first { $0.kind == .image })
        XCTAssertEqual(image.title, "Image")
        XCTAssertEqual(image.origin, .image)
        XCTAssertNil(image.contentHash)
        XCTAssertEqual(image.assetFilename, "280FE821-5811-4580-8D57-934D21B0CECD.png")

        XCTAssertEqual(loaded.map(\.id.uuidString), [
            "AAF723D0-B755-42BC-8F4F-5818091D5B0C", "26447945-C1CB-442F-9302-46EEFBAFBF5A",
            "F94174EF-2F81-4E91-B0A8-485AEA235482",
        ], "newest first")
    }

    /// Two copies in the same second used to swap places after a relaunch.
    func testDatesKeepFractionalSecondsAndOrder() throws {
        let archive = try ClippingArchive(directory: directory)
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000.1)
        let first = Clipping(kind: .text, payload: "first", createdAt: base)
        let second = Clipping(kind: .text, payload: "second", createdAt: base.addingTimeInterval(0.3))
        archive.append(second)   // written first, but copied later
        archive.append(first)
        archive.flush()

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains(".100000Z") && log.contains(".400000Z"), log)
        XCTAssertEqual(ClippingArchive.encode(Date(timeIntervalSinceReferenceDate: 0.9999996)), "2001-01-01T00:00:01.000000Z")

        let loaded = try ClippingArchive(directory: directory).load()
        XCTAssertEqual(loaded.map(\.payload), ["second", "first"])
        XCTAssertEqual(loaded[0].lastCopiedAt.timeIntervalSince(second.lastCopiedAt), 0, accuracy: 0.000_002)
        XCTAssertEqual(loaded[1].createdAt.timeIntervalSince(first.createdAt), 0, accuracy: 0.000_002)
    }

    /// A crash mid-write leaves a line with no newline. The next record
    /// used to be glued onto it and lost with it.
    func testTornLastLineCostsOnlyItself() throws {
        let archive = try ClippingArchive(directory: directory)
        archive.append(Clipping(kind: .text, payload: "before the crash"))
        archive.flush()
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"upsert":{"_0":{"trunc"#.utf8))
        try handle.close()

        let relaunched = try ClippingArchive(directory: directory)
        XCTAssertEqual(relaunched.load().map(\.payload), ["before the crash"])
        relaunched.append(Clipping(kind: .text, payload: "first copy after the crash"))
        relaunched.flush()

        let reloaded = try ClippingArchive(directory: directory).load()
        XCTAssertEqual(Set(reloaded.map(\.payload)), ["before the crash", "first copy after the crash"])
    }

    func testConcealedClippingsNeverReachTheLog() throws {
        let archive = try ClippingArchive(directory: directory)
        archive.append(Clipping(kind: .text, payload: "", isConcealed: true, detail: "1Password"))
        archive.append(Clipping(kind: .text, payload: "visible"))
        archive.flush()
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("\"isConcealed\":true"))
        XCTAssertEqual(log.split(separator: "\n").count, 1)
    }

    func testDeletedAssetsWaitInTheTrashForUndo() throws {
        let archive = try ClippingArchive(directory: directory)
        XCTAssertTrue(archive.storeAsset(Data([1, 2, 3]), filename: "a.png"))
        let clipping = Clipping(kind: .image, payload: "Image", assetFilename: "a.png")
        archive.append(clipping)

        archive.remove([clipping], keepAssets: true)
        archive.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.assetURL(for: "a.png").path))

        archive.restoreAssets(of: clipping)
        archive.append(clipping)
        archive.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.assetURL(for: "a.png").path))
        XCTAssertEqual(try ClippingArchive(directory: directory).load().map(\.id), [clipping.id])
    }

    /// Orphans are only swept at launch, and only files older than the launch:
    /// the compaction-time sweep used to delete a PNG whose capture was still
    /// on its way to the store.
    func testLaunchSweepsOnlyOldOrphans() throws {
        let archive = try ClippingArchive(directory: directory)
        XCTAssertTrue(archive.storeAsset(Data([1]), filename: "kept.png"))
        XCTAssertTrue(archive.storeAsset(Data([2]), filename: "orphan.png"))
        let old = Date().addingTimeInterval(-3_600)
        for file in ["kept.png", "orphan.png"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: archive.assetURL(for: file).path)
        }
        archive.append(Clipping(kind: .image, payload: "Image", assetFilename: "kept.png"))
        archive.flush()

        let relaunched = try ClippingArchive(directory: directory)
        _ = relaunched.load()
        XCTAssertTrue(relaunched.storeAsset(Data([3]), filename: "in-flight.png"))
        relaunched.compact(liveClippings: [])
        relaunched.flush()

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: relaunched.assetsDirectory.path))
        XCTAssertEqual(files, ["kept.png", "in-flight.png"])
    }
}
