import AppKit
import XCTest
@testable import CpKit

@MainActor
final class PasteFormatTests: XCTestCase {

    // MARK: - Links

    /// Fix 10: "Remove tracking" matched "si" as a prefix and took `size`,
    /// `since`, `sid` and a presigned S3 link's `Signature` with it.
    func testCleanLinkRemovesOnlyTrackingParameters() {
        let shop = "https://shop.example.com/search?q=shoes&size=10&since=2024-01-01&sid=42&utm_source=mail&si=abc&fbclid=x#top"
        XCTAssertEqual(URLTracking.clean(shop), "https://shop.example.com/search?q=shoes&size=10&since=2024-01-01&sid=42#top")

        let s3 = "https://bucket.s3.amazonaws.com/report.pdf?AWSAccessKeyId=AKIAEXAMPLE&Signature=abc%2Bdef%3D&Expires=1790000000"
        XCTAssertEqual(URLTracking.clean(s3), s3, "nothing to remove, nothing re-encoded")

        XCTAssertEqual(URLTracking.clean("https://example.com/p?utm_source=x&UTM_Medium=y&gclid=z"), "https://example.com/p")
        XCTAssertEqual(URLTracking.clean("https://youtu.be/abc?si=xyz&t=42"), "https://youtu.be/abc?t=42")
        XCTAssertEqual(URLTracking.clean("https://example.com/no-query"), "https://example.com/no-query")
        for name in ["dclid", "gbraid", "wbraid", "msclkid", "yclid", "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi",
                     "vero_id", "ref_src", "ref_url"] {
            XCTAssertEqual(URLTracking.clean("https://a.com/?\(name)=1&keep=2"), "https://a.com/?keep=2", name)
        }
    }

    func testTrackingRanges() {
        let url = "https://example.com/p?id=42&utm_source=news&si=abc&size=m"
        let ranges = URLTracking.trackingRanges(in: url)
        XCTAssertEqual(ranges.map { (url as NSString).substring(with: $0) }, ["utm_source=news", "si=abc"])
        XCTAssertTrue(URLTracking.trackingRanges(in: "https://example.com/?size=1&since=2&sid=3").isEmpty)
    }

    // MARK: - Colours

    func testColorNotations() {
        let formats = ColorFormats.strings(for: "#FF5A36")
        XCTAssertEqual(formats[.hex], "#FF5A36")
        XCTAssertEqual(formats[.rgb], "rgb(255, 90, 54)")
        XCTAssertEqual(formats[.hsl], "hsl(11, 100%, 61%)")
        XCTAssertEqual(formats[.swiftUI], "Color(red: 1.00, green: 0.35, blue: 0.21)")

        // What was copied comes back exactly as copied.
        XCTAssertEqual(ColorFormats.strings(for: " #abc ")[.hex], "#abc")
        XCTAssertEqual(ColorFormats.strings(for: "#abc")[.rgb], "rgb(170, 187, 204)")
        XCTAssertEqual(ColorFormats.strings(for: "rgb(255, 90, 54)")[.hex], "#FF5A36")
        XCTAssertEqual(ColorFormats.strings(for: "rgb(255, 90, 54)")[.rgb], "rgb(255, 90, 54)")
        XCTAssertEqual(ColorFormats.strings(for: "#FF5A3680")[.rgb], "rgba(255, 90, 54, 0.5)")
        XCTAssertEqual(ColorFormats.strings(for: "hsl(0, 100%, 50%)")[.hex], "#FF0000")
        XCTAssertEqual(ColorFormats.notation(of: "hsl(0, 100%, 50%)"), .hsl)
        XCTAssertTrue(ColorFormats.strings(for: "not a colour").isEmpty)
    }

    // MARK: - Menus and chips

    private func clip(_ payload: String, kind: ClippingKind? = nil, origin: ClipOrigin? = nil,
                      linkTitle: String? = nil, ocr: String? = nil) -> Clipping {
        let classified = Classifier.classify(payload)
        return Clipping(kind: kind ?? classified.kind, payload: payload, detail: classified.detail, origin: origin,
                        ocrText: ocr, linkTitle: linkTitle)
    }

    func testMenusOfferWhatAppliesDefaultFirst() {
        XCTAssertEqual(PasteFormats.menu(for: clip("one line")), [.original])
        XCTAssertEqual(PasteFormats.menu(for: clip("two\nlines")), [.original, .oneLine])
        XCTAssertEqual(PasteFormats.menu(for: clip("  indented\n  prose", kind: .text)), [.original, .oneLine, .dedented])
        XCTAssertEqual(PasteFormats.menu(for: clip("words", kind: .richText)), [.original, .plainText, .markdown])

        XCTAssertEqual(PasteFormats.menu(for: clip("https://example.com/a")), [.original, .markdown])
        XCTAssertEqual(PasteFormats.menu(for: clip("https://example.com/a?utm_source=x", linkTitle: "A")),
                       [.original, .markdown, .cleanLink, .linkTitle])

        XCTAssertEqual(PasteFormats.menu(for: clip("    let x = 1\n    let y = 2", kind: .code)), [.original, .codeBlock, .dedented])
        XCTAssertEqual(PasteFormats.menu(for: clip("{\"a\":1}")), [.jsonPretty, .jsonMinified])
        XCTAssertEqual(PasteFormats.menu(for: clip("{\n    \"a\": 1\n}")), [.jsonPretty, .jsonMinified, .original])

        XCTAssertEqual(PasteFormats.menu(for: clip("#FF5A36")), [.color(.hex), .color(.rgb), .color(.hsl), .color(.swiftUI)])
        XCTAssertEqual(PasteFormats.menu(for: clip("rgb(255, 90, 54)")).first, .color(.rgb))

        XCTAssertEqual(PasteFormats.menu(for: clip("Image", kind: .image)), [.original])
        XCTAssertEqual(PasteFormats.menu(for: clip("Image", kind: .image, ocr: "Invoice")), [.original, .imageText])
        XCTAssertEqual(PasteFormats.menu(for: clip("/Users/me/a.txt", origin: .fileURLs)), [.original, .filePath])
        XCTAssertEqual(PasteFormats.menu(for: clip("/Users/me/a.txt")), [.original])
        XCTAssertEqual(PasteFormats.menu(for: Clipping(kind: .text, payload: "", isConcealed: true)), [.original])
    }

    func testChipsOfferTheAlternativesAfterAPaste() {
        XCTAssertEqual(PasteFormats.chip(for: clip("one line")), [])
        XCTAssertEqual(PasteFormats.chip(for: clip("two\nlines")), [.original, .oneLine])
        XCTAssertEqual(PasteFormats.chip(for: clip("words", kind: .richText)), [.original, .plainText, .markdown])
        XCTAssertEqual(PasteFormats.chip(for: clip("https://example.com/a?utm_source=x", linkTitle: "A")),
                       [.original, .linkTitle, .markdown, .cleanLink])
        XCTAssertEqual(PasteFormats.chip(for: clip("let x = 1", kind: .code)), [.original, .codeBlock])
        XCTAssertEqual(PasteFormats.chip(for: clip("[1,2]")), [.jsonPretty, .jsonMinified])
        XCTAssertEqual(PasteFormats.chip(for: clip("#FF5A36")).count, 4)
        XCTAssertEqual(PasteFormats.chip(for: clip("Image", kind: .image)), [])
        XCTAssertEqual(PasteFormats.chip(for: clip("Image", kind: .image, ocr: "Invoice")), [.original, .imageText])
        XCTAssertEqual(PasteFormats.chip(for: clip("/Users/me/a.txt", origin: .fileURLs)), [.original, .filePath])
        XCTAssertEqual(PasteFormats.chip(for: Clipping(kind: .text, payload: "", isConcealed: true)), [])
    }

    func testDefaultFollowsSettings() {
        let settings = Settings(defaults: MemoryDefaults())
        let rich = clip("words", kind: .richText)
        XCTAssertEqual(PasteFormats.defaultFormat(for: rich, settings: settings), .original)
        settings.pasteRichAsPlain = true
        XCTAssertEqual(PasteFormats.defaultFormat(for: rich, settings: settings), .plainText)
        XCTAssertEqual(PasteFormats.menu(for: rich, settings: settings).first, .plainText)
        XCTAssertEqual(PasteFormats.defaultFormat(for: clip("{\"a\":1}"), settings: settings), .jsonPretty)
        XCTAssertEqual(PasteFormats.defaultFormat(for: clip("hsl(0, 100%, 50%)"), settings: settings), .color(.hsl))
    }

    func testLabels() {
        let link = clip("https://example.com/a?utm_source=x")
        XCTAssertEqual(PasteFormat.markdown.menuLabel(for: link), "Paste as Markdown link")
        XCTAssertEqual(PasteFormat.cleanLink.menuLabel(for: link), "Paste without tracking")
        XCTAssertEqual(PasteFormat.original.menuLabel(for: link), "Paste link")
        XCTAssertEqual(PasteFormat.markdown.chipLabel(for: link), "Markdown")
        let image = clip("Image", kind: .image, ocr: "x")
        XCTAssertEqual(PasteFormat.imageText.menuLabel(for: image), "Paste text from image")
        XCTAssertEqual(PasteFormat.imageText.chipLabel(for: image), "Text")
        let color = clip("#FF5A36")
        XCTAssertEqual(PasteFormat.color(.hex).menuLabel(for: color), "Paste #FF5A36")
        XCTAssertEqual(PasteFormat.color(.rgb).menuLabel(for: color), "Paste rgb(255, 90, 54)")
        XCTAssertEqual(PasteFormat.color(.swiftUI).menuLabel(for: color), "Paste as SwiftUI Color")
        XCTAssertEqual(PasteFormat.color(.hex).chipLabel(for: color), "HEX")
        XCTAssertEqual(PasteFormat.plainText.chipLabel(for: clip("x", kind: .richText)), "Plain")
        XCTAssertEqual(PasteFormat.original.menuLabel(for: clip("/Users/a\n/Users/b", kind: .file, origin: .fileURLs)), "Paste files")
    }

    // MARK: - Rendering

    private func makeStore() -> (ClippingStore, URL) {
        let directory = TestDirectory.make(name)
        let archive = try? ClippingArchive(directory: directory)
        return (ClippingStore(archive: archive, settings: Settings(defaults: MemoryDefaults()), recognizer: nil), directory)
    }

    func testRenderedPayloads() throws {
        let (store, directory) = makeStore()
        defer { TestDirectory.remove(directory) }
        func render(_ c: Clipping, _ format: PasteFormat) -> PastePayload? {
            PasteRenderer.payload(for: c, as: format, store: store)
        }

        let link = clip("https://www.figma.com/design/Qp2kT/cp?node-id=12-4&utm_source=slack", linkTitle: "cp — Picker [v2]")
        XCTAssertEqual(render(link, .markdown)?.string, "[cp — Picker \\[v2\\]](https://www.figma.com/design/Qp2kT/cp?node-id=12-4)")
        XCTAssertEqual(render(clip("https://github.com/a/b"), .markdown)?.string, "[github.com](https://github.com/a/b)")
        XCTAssertEqual(render(link, .linkTitle)?.string, "cp — Picker [v2]")
        XCTAssertNil(render(clip("https://github.com/a/b"), .linkTitle))

        let code = Clipping(kind: .code, payload: "    guard x else { return }\n    run()\n", detail: "swift")
        XCTAssertEqual(render(code, .codeBlock)?.string, "```swift\n    guard x else { return }\n    run()\n```")
        XCTAssertEqual(render(code, .dedented)?.string, "guard x else { return }\nrun()\n")
        XCTAssertEqual(render(Clipping(kind: .code, payload: "x", detail: "code"), .codeBlock)?.string, "```\nx\n```")
        XCTAssertEqual(render(clip("one\n  two  \n\nthree"), .oneLine)?.string, "one two three")

        let json = clip(#"{"b":10.10,"a":[1,2]}"#)
        XCTAssertEqual(render(json, .jsonPretty)?.string, "{\n  \"b\": 10.10,\n  \"a\": [\n    1,\n    2\n  ]\n}")
        XCTAssertEqual(render(clip("{\n \"b\" : 1 }"), .jsonMinified)?.string, #"{"b":1}"#)
        XCTAssertEqual(render(clip("#FF5A36"), .color(.hsl))?.string, "hsl(11, 100%, 61%)")

        let image = clip("Image", kind: .image, ocr: "Invoice 2291")
        XCTAssertEqual(render(image, .imageText)?.string, "Invoice 2291")
        XCTAssertNil(render(clip("Image", kind: .image), .imageText))
        XCTAssertNil(render(image, .original), "no asset on disk")
    }

    /// Fix 3: every `.file` clipping pasted as a file reference with no text.
    func testFilesPasteAsReferencesOnlyWhenTheyArrivedAsFiles() {
        let (store, directory) = makeStore()
        defer { TestDirectory.remove(directory) }
        let copied = clip("/Users/me/a.txt\n/Users/me/b.png", kind: .file, origin: .fileURLs)
        let payload = PasteRenderer.payload(for: copied, as: .original, store: store)
        XCTAssertEqual(payload?.fileURLs, [URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/Users/me/b.png")])
        XCTAssertEqual(payload?.string, "/Users/me/a.txt\n/Users/me/b.png")
        XCTAssertEqual(PasteRenderer.payload(for: copied, as: .filePath, store: store), PastePayload(string: "/Users/me/a.txt\n/Users/me/b.png"))

        let typed = clip("~/Projects/cp/README.md")
        XCTAssertEqual(typed.kind, .file)
        XCTAssertEqual(PasteRenderer.payload(for: typed, as: .original, store: store), PastePayload(string: "~/Projects/cp/README.md"))
    }

    func testConcealedPayloadComesFromTheVault() {
        let (store, directory) = makeStore()
        defer { TestDirectory.remove(directory) }
        let secret = store.ingest(Clipping(kind: .text, payload: "", isConcealed: true), secret: "correct horse battery")
        XCTAssertEqual(PasteRenderer.payload(for: secret, as: .original, store: store)?.string, "correct horse battery")
        XCTAssertNil(PasteRenderer.payload(for: secret, as: .markdown, store: store))
        store.forget(secret.id)
        XCTAssertNil(PasteRenderer.payload(for: secret, as: .original, store: store))
    }

    func testImageAndRichTextCarryTheirBytes() throws {
        let (store, directory) = makeStore()
        defer { TestDirectory.remove(directory) }
        let archive = try ClippingArchive(directory: directory)
        XCTAssertTrue(archive.storeAsset(Data([0x89, 0x50]), filename: "i.png"))

        let styled = NSMutableAttributedString(string: "Bold claim and a link")
        styled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 0, length: 4))
        styled.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 4, length: 17))
        styled.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 17, length: 4))
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertTrue(archive.storeAsset(rtf, filename: "r.rtf"))

        let image = Clipping(kind: .image, payload: "Image", assetFilename: "i.png")
        XCTAssertEqual(PasteRenderer.payload(for: image, as: .original, store: store)?.png, Data([0x89, 0x50]))

        let rich = Clipping(kind: .richText, payload: styled.string, richAssetFilename: "r.rtf")
        let original = PasteRenderer.payload(for: rich, as: .original, store: store)
        XCTAssertEqual(original?.string, "Bold claim and a link")
        XCTAssertEqual(original?.rtf, rtf)
        XCTAssertEqual(PasteRenderer.payload(for: rich, as: .plainText, store: store), PastePayload(string: "Bold claim and a link"))
        XCTAssertEqual(PasteRenderer.payload(for: rich, as: .markdown, store: store)?.string,
                       "**Bold** claim and a [link](https://example.com)")
    }

    // MARK: - Rich text

    /// Fix 5: every RTF names a font, so every RTF was typed rich.
    func testRichOnlyWhenFormattingIsReal() throws {
        func attributed(_ build: (NSMutableAttributedString) -> Void) -> NSAttributedString {
            let text = NSMutableAttributedString(string: "Some words here\n",
                                                 attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
            build(text)
            // Round-trip through RTF, as it arrives from another app.
            let data = try! text.data(from: NSRange(location: 0, length: text.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return NSAttributedString(rtf: data, documentAttributes: nil)!
        }
        let whole = NSRange(location: 0, length: 4)
        XCTAssertFalse(RichText.hasRealFormatting(attributed { _ in }))
        XCTAssertFalse(RichText.hasRealFormatting(attributed { $0.addAttribute(.foregroundColor, value: NSColor.black, range: whole) }))
        XCTAssertFalse(RichText.hasRealFormatting(attributed {
            $0.addAttribute(.font, value: NSFont(name: "Helvetica", size: 20)!, range: NSRange(location: 15, length: 1))
        }), "a different size on the trailing newline is invisible")
        XCTAssertTrue(RichText.hasRealFormatting(attributed { $0.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: whole) }))
        XCTAssertTrue(RichText.hasRealFormatting(attributed { $0.addAttribute(.underlineStyle, value: 1, range: whole) }))
        XCTAssertTrue(RichText.hasRealFormatting(attributed { $0.addAttribute(.link, value: URL(string: "https://a.com")!, range: whole) }))
        XCTAssertTrue(RichText.hasRealFormatting(attributed { $0.addAttribute(.foregroundColor, value: NSColor.systemRed, range: whole) }))
        XCTAssertTrue(RichText.hasRealFormatting(attributed {
            $0.addAttribute(.font, value: NSFont(name: "Helvetica", size: 24)!, range: whole)
        }), "two sizes")
    }
}
