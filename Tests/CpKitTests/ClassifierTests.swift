import XCTest
@testable import CpKit

final class ClassifierTests: XCTestCase {

    private func kind(_ text: String) -> ClippingKind { Classifier.classify(text).kind }
    private func language(_ text: String) -> String? {
        let result = Classifier.classify(text)
        return result.kind == .code ? result.detail : nil
    }

    // MARK: - Colours

    func testHexColors() {
        XCTAssertEqual(kind("#FF5733"), .color)
        XCTAssertEqual(kind("#abc"), .color)
        XCTAssertEqual(kind("#AABBCCDD"), .color)
        XCTAssertEqual(Classifier.classify("#ff5733").detail, "#FF5733")
        // #RGBA is CSS Color 4 shorthand, and `ColorParser` expands it.
        XCTAssertEqual(kind("#F57A"), .color)
        // Wrong digit count is not a colour.
        XCTAssertNotEqual(kind("#FF573"), .color)
        XCTAssertNotEqual(kind("#hello!"), .color)
    }

    /// Fix 12: `#123` and `#1234` are issue and pull-request references.
    func testIssueReferencesAreNotColors() {
        XCTAssertEqual(kind("#123"), .text)
        XCTAssertEqual(kind("#4521"), .text)
        // Corpus samples.
        for ref in ["#382", "#9068", "#8260"] { XCTAssertEqual(kind(ref), .text, ref) }
        // Six all-digit hex digits are still a colour: #123456 is a dark blue.
        XCTAssertEqual(kind("#123456"), .color)
    }

    func testFunctionalColors() {
        XCTAssertEqual(kind("rgb(255, 87, 51)"), .color)
        XCTAssertEqual(kind("rgba(0,0,0,0.5)"), .color)
        XCTAssertEqual(kind("hsl(9, 100%, 60%)"), .color)
        // A CSS variable inside rgb() is not a literal colour.
        XCTAssertNotEqual(kind("rgb(var(--brand))"), .color)
    }

    // MARK: - Links

    func testURLs() {
        let result = Classifier.classify("https://github.com/org/repo/pull/1234")
        XCTAssertEqual(result.kind, .url)
        XCTAssertEqual(result.detail, "github.com")

        XCTAssertEqual(Classifier.classify("www.example.com/path").detail, "www.example.com")
        // Prose containing a link is prose.
        XCTAssertEqual(kind("see https://example.com for details"), .text)
        // A bare word with no dot is not a host...
        XCTAssertNotEqual(kind("https://intranet"), .url)
        // ...except the two a developer copies all day.
        XCTAssertEqual(Classifier.classify("http://localhost:3000/login").detail, "localhost")
        XCTAssertEqual(Classifier.classify("http://127.0.0.1:8080/health").detail, "127.0.0.1")
    }

    // MARK: - Paths

    func testFilePaths() {
        XCTAssertEqual(kind("/Users/me/Documents/notes.md"), .file)
        XCTAssertEqual(kind("~/Projects/cp/README.md"), .file)
        XCTAssertEqual(kind("/Users/dev/Library/Application Support/Novelism/config.json"), .file)
        XCTAssertEqual(kind("/usr/local/bin/cryogen"), .file)
        XCTAssertEqual(kind("file:///Users/me/a.txt"), .file)
        XCTAssertEqual(Classifier.classify("/var/log/idgah.log").detail, "/var/log")
        XCTAssertNotEqual(kind("/"), .file)
    }

    /// Fix 12: anything starting with "/" used to become a file.
    func testSlashLedTextIsNotAFile() {
        XCTAssertNotEqual(kind("/api/v1/users"), .file)
        XCTAssertNotEqual(kind("/api/v1/catechist/8866"), .file)   // corpus sample
        XCTAssertNotEqual(kind("// TODO: remove this hack"), .file)
        XCTAssertNotEqual(kind("/giphy thumbs up"), .file)
        XCTAssertNotEqual(kind("/^\\d{3}-\\d{4}$/"), .file)
        XCTAssertNotEqual(kind("//cdn.example.com/app.js"), .file)
    }

    // MARK: - JSON

    func testJSON() {
        let object = Classifier.classify("{\"a\": 1, \"b\": {\"c\": 2}}")
        XCTAssertEqual(object.kind, .json)
        XCTAssertEqual(object.detail, "2 keys")

        let array = Classifier.classify("[1, [2, 3], {\"x\": 4}]")
        XCTAssertEqual(array.kind, .json)
        XCTAssertEqual(array.detail, "3 items")

        // Invalid JSON that merely starts with a brace falls through to code/text.
        XCTAssertNotEqual(kind("{not json"), .json)
        XCTAssertNotEqual(kind("[1, 2,]"), .json)
    }

    /// Fix 12: JSON bigger than the 8 KB scan window used to be typed as text.
    func testJSONOverTheScanWindow() {
        let items = (0..<400).map { "{\"id\":\($0),\"name\":\"user\($0)\",\"active\":true}" }
        let big = "[" + items.joined(separator: ",") + "]"
        XCTAssertGreaterThan(big.utf8.count, 8_192)
        let result = Classifier.classify(big)
        XCTAssertEqual(result.kind, .json)
        XCTAssertEqual(result.detail, "400 items")
    }

    // MARK: - Code

    func testSwiftAndShebang() {
        let swift = """
        struct PullRequestView: View {
            @State private var isExpanded = false
            var body: some View { Text("hi") }
        }
        """
        XCTAssertEqual(language(swift), "swift")
        XCTAssertEqual(language("#!/usr/bin/env bash\necho hello"), "shell")
    }

    /// Fix 12: 68 of 100 Python snippets in the audit corpus were typed as text.
    func testPython() {
        XCTAssertEqual(language("def total(items):\n    return sum(i.price for i in items)\n\nprint(total(cart))"), "python")
        XCTAssertEqual(language("import os\nfrom pathlib import Path\n\nroot = Path(os.getcwd())"), "python")
        XCTAssertEqual(language("class Cache:\n    def __init__(self):\n        self.items = {}"), "python")
        // Corpus samples: stdlib fragments with no braces or semicolons at all.
        XCTAssertEqual(language("            def default(self, o):\n                try:\n                    iterable = iter(o)\n                except TypeError:\n                    pass"), "python")
        XCTAssertEqual(language("                        else:\n                            line = line.rstrip('\\r\\n')\n                line = self.precmd(line)\n                stop = self.onecmd(line)\n                stop = self.postcmd(stop, line)\n            self.postloop()"), "python")
        XCTAssertEqual(kind("        return self.header_factory(name, value)\n\n    def fold(self, name, value):\n        \"\"\"+\n        Header folding is controlled by the refold_source policy setting.  A"), .code)
    }

    func testOtherKeywordLanguages() {
        XCTAssertEqual(language("SELECT id, name\nFROM users\nWHERE active = true\nORDER BY name;"), "sql")
        XCTAssertEqual(language("select * from users where id = 1"), "sql")
        XCTAssertEqual(language("services:\n  web:\n    image: nginx:latest\n    ports:\n      - \"80:80\""), "yaml")
        XCTAssertEqual(language("package main\n\nimport \"fmt\"\n\nfunc main() {\n\tx := 1\n\tfmt.Println(x)\n}"), "go")
        XCTAssertEqual(language("fn main() {\n    let mut total = 0;\n    println!(\"{}\", total);\n}"), "rust")
        XCTAssertEqual(language("require 'json'\n\ndef greet(name)\n  puts \"hi #{name}\"\nend"), "ruby")
        XCTAssertEqual(language("git rebase -i HEAD~3"), "shell")
        XCTAssertEqual(language("make test"), "shell")
        XCTAssertEqual(language("curl -sS https://api.example.com/v1/status | jq ."), "shell")
        XCTAssertEqual(language("export API_URL=https://example.internal"), "shell")
        // Corpus samples: a C header and npm's JavaScript.
        XCTAssertEqual(language("\t\t__attribute__((__format__ (__strfmon__, fmtarg, firstvararg)))\n#define __strftimelike(fmtarg) \\\n\t\t__attribute__((__format__ (__strftime__, fmtarg, 0)))\n#else\n#define __strfmonlike(fmtarg, firstvararg)\n#define __strftimelike(fmtarg)"), "c")
        XCTAssertEqual(language("    }\n\n    const dryRun = this.npm.config.get('dry-run')\n    const where = this.npm.prefix\n    const Arborist = require('@npmcli/arborist')"), "javascript")
    }

    /// The precision half of the bargain: chat and prose that happen to start
    /// with a keyword stay text.
    func testProseIsNotCode() {
        let prose = """
        The meeting is at 3pm; please bring the deck. We'll review the numbers \
        and decide whether to ship on Friday or wait for the next cycle.
        """
        let samples = [
            prose,
            "def gonna be late", "done", "export the data to CSV", "Select the file from the menu.",
            "raise a ticket for it", "class notes: bring the laptop", "extension cord is in the garage",
            "import the photos into the library", "make sure the build is green", "package arrived",
            "case closed", "return the book tomorrow", "go home", "open the pod bay doors",
            "Hi {firstName}, your order {orderId} shipped; track it here",
            "Agenda:\n  - intro; goals\n  - roadmap review\n  - Q&A",
            "Build succeeded in 65.2s", "zsh: command not found: wryly", "error: cannot find 'plak' in scope",
            "I'll take a look this afternoon running 5 min late",
            "Instead, the expanded line is reloaded into the readline editing buffer for further modification.",
            "Hi Bob,\n\nThanks for the notes.\n\nRegards,\nAlice",
        ]
        for sample in samples {
            XCTAssertEqual(kind(sample), .text, sample)
        }
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(kind(""), .text)
        XCTAssertEqual(kind("   \n  "), .text)
    }
}
