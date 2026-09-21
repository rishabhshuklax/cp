import XCTest
@testable import CpKit

final class ModelTests: XCTestCase {

    func testDedupeKeyIgnoresSourceAndTime() {
        let a = Clipping(kind: .text, payload: "same", sourceAppName: "Xcode")
        let b = Clipping(kind: .text, payload: "same", sourceAppName: "Safari")
        XCTAssertEqual(a.dedupeKey, b.dedupeKey)
    }

    func testDedupeKeySeparatesKinds() {
        let text = Clipping(kind: .text, payload: "#FFF")
        let color = Clipping(kind: .color, payload: "#FFF")
        XCTAssertNotEqual(text.dedupeKey, color.dedupeKey)
    }

    /// Two different screenshots of the same size used to collapse into
    /// one row, because the key was the "Image W×H" payload.
    func testImagesDedupeOnContentHashNotSize() {
        let first = Clipping(kind: .image, payload: "Image 2880×1800", contentHash: "aaaa")
        let second = Clipping(kind: .image, payload: "Image 2880×1800", contentHash: "bbbb")
        let recopy = Clipping(kind: .image, payload: "Image 1440×900", contentHash: "aaaa")
        XCTAssertNotEqual(first.dedupeKey, second.dedupeKey)
        XCTAssertEqual(first.dedupeKey, recopy.dedupeKey)
        // An image from before hashes existed never collapses onto anything.
        let legacy = Clipping(kind: .image, payload: "Image 2880×1800")
        XCTAssertNotEqual(legacy.dedupeKey, Clipping(kind: .image, payload: "Image 2880×1800").dedupeKey)
    }

    /// Every concealed copy is its own row with its own reason.
    func testConcealedClippingsNeverShareAKey() {
        let a = Clipping(kind: .text, payload: "", isConcealed: true, detail: "1Password")
        let b = Clipping(kind: .text, payload: "", isConcealed: true, detail: "looks like a credential")
        XCTAssertNotEqual(a.dedupeKey, b.dedupeKey)
        XCTAssertEqual(a.title, "Password")
    }

    func testTitleSkipsLeadingBlanks() {
        let clipping = Clipping(kind: .code, payload: "\n\n   struct A {}\n")
        XCTAssertEqual(clipping.title, "struct A {}")
        XCTAssertEqual(clipping.titleLine, clipping.title)
        XCTAssertEqual(Clipping(kind: .text, payload: "\r\n  \r\nsecond line\r\n").title, "second line")
    }

    func testTitlePerKind() {
        XCTAssertEqual(Clipping(kind: .url, payload: " https://github.com/a/b \n").title, "https://github.com/a/b")
        XCTAssertEqual(Clipping(kind: .file, payload: "/Users/me/Documents/notes.md\n/tmp/x").title, "notes.md")
        XCTAssertEqual(Clipping(kind: .file, payload: "file:///Users/me/My%20File.pdf").title, "My File.pdf")
        XCTAssertEqual(Clipping(kind: .image, payload: "Image 10×10").title, "Image")
        XCTAssertEqual(Clipping(kind: .color, payload: "#ff5733", detail: "#FF5733").title, "#FF5733")
        let long = String(repeating: "word ", count: 100)
        XCTAssertEqual(Clipping(kind: .text, payload: long).title.count, 199)  // 200, trailing space trimmed
    }

    func testDisplayTitleHostAndLanguage() {
        var link = Clipping(kind: .url, payload: "www.apple.com/mac")
        XCTAssertEqual(link.host, "www.apple.com")
        XCTAssertEqual(link.displayTitle, "www.apple.com/mac")
        link.linkTitle = "Mac - Apple"
        XCTAssertEqual(link.displayTitle, "Mac - Apple")
        XCTAssertNil(Clipping(kind: .text, payload: "www.apple.com").host)
        XCTAssertEqual(Clipping(kind: .code, payload: "x", detail: "swift").language, "swift")
        XCTAssertNil(Clipping(kind: .text, payload: "x", detail: "swift").language)
    }

    /// Counts are stored at capture, and previews are capped.
    func testCountsAndPreviewAreCheapForBigClippings() {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = Clipping(kind: .text, payload: String(repeating: line, count: 1_000))
        XCTAssertEqual(big.lineCount, 1_001)
        XCTAssertEqual(big.wordCount, 1_000)
        XCTAssertEqual(big.byteCount, 100_000)

        // Cut at the last line break inside the limit.
        let preview = big.previewText(limit: 1_050)
        XCTAssertEqual(preview.count, 999)
        XCTAssertTrue(preview.hasSuffix("x"))

        // One enormous line has no break to cut at.
        let single = Clipping(kind: .text, payload: String(repeating: "y", count: 50_000))
        XCTAssertEqual(single.previewText(limit: 100).count, 100)
        XCTAssertEqual(single.lineCount, 1)

        XCTAssertEqual(Clipping(kind: .text, payload: "short").previewText(), "short")
        XCTAssertEqual(Clipping(kind: .text, payload: "").lineCount, 0)
        XCTAssertEqual(Clipping(kind: .text, payload: "a b\tc\nd").wordCount, 4)
    }

    func testTimeBucketing() {
        let now = Date()
        let recent = Clipping(kind: .text, payload: "a", createdAt: now.addingTimeInterval(-60))
        XCTAssertEqual(TimeBucket.bucket(for: recent, now: now), .now)

        let older = Clipping(kind: .text, payload: "b", createdAt: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(TimeBucket.bucket(for: older, now: now), .older)

        let pinned = Clipping(kind: .text, payload: "c", createdAt: now.addingTimeInterval(-30 * 86_400), isPinned: true)
        XCTAssertEqual(TimeBucket.bucket(for: pinned, now: now), .pinned)
    }

    func testRelativeStamps() {
        let now = Date()
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-120), now: now), "2m")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-7_200), now: now), "2h")
        XCTAssertEqual(TimeBucket.relativeStamp(for: now.addingTimeInterval(-2 * 86_400), now: now), "2d")
    }

    func testColorParserExpandsShorthand() {
        XCTAssertNotNil(ColorParser.color(from: "#abc"))
        XCTAssertNotNil(ColorParser.color(from: "#AABBCC"))
        XCTAssertNotNil(ColorParser.color(from: "rgb(255, 0, 0)"))
        XCTAssertNil(ColorParser.color(from: "not a colour"))
    }

    /// `>1e30k` used to trap converting 1.024e33 to `Int`.
    func testByteFormatRejectsWhatDoesNotFit() {
        XCTAssertNil(ByteFormat.parse("1e30k"))
        XCTAssertNil(ByteFormat.parse("1e30"))
        XCTAssertNil(ByteFormat.parse("inf"))
        XCTAssertNil(ByteFormat.parse("nan"))
        XCTAssertNil(ByteFormat.parse("-5k"))
        XCTAssertNil(ByteFormat.parse("banana"))
        XCTAssertEqual(ByteFormat.parse("512"), 512)
        XCTAssertEqual(ByteFormat.parse("1k"), 1_024)
        XCTAssertEqual(ByteFormat.parse("1.5kb"), 1_536)
        XCTAssertEqual(ByteFormat.parse("2mb"), 2 * 1_024 * 1_024)
        XCTAssertEqual(ByteFormat.short(1_536), "1.5 KB")
    }
}
