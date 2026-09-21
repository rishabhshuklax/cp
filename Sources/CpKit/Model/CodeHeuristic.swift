import Foundation

/// Decides whether a blob of text is source code, and if so which language.
///
/// This is a scorer, not a parser. It exists to make the *row* look right — a
/// monospace preview with a language badge — and a wrong guess costs a
/// mislabelled badge, not correctness.
///
/// It reads line by line. Punctuation alone (braces, semicolons) finds C-family
/// code but misses most of Python, YAML, SQL and shell, which are written in
/// keywords and indentation instead. So each line is asked what it looks like —
/// `def total(items):`, `FROM users`, `git rebase -i HEAD~3`, `}` — and the text
/// is code when enough of its lines answer "code". Prose answers "nothing" on
/// nearly every line, which is what keeps a paragraph with one semicolon out.
/// Every pattern is written so that a chat message cannot match it by accident:
/// "def gonna be late", "export the data", "done" and "extension cord" are text.
public enum CodeHeuristic {

    /// Language, or `"code"` when the text is code but the language is unclear,
    /// or `nil` when it is not code.
    public static func detectLanguage(_ text: String) -> String? {
        let lines = significantLines(text)
        guard !lines.isEmpty else { return nil }

        if text.pre("#!") { return "shell" }
        if isYAML(lines) { return "yaml" }
        if let sql = sqlLanguage(lines) { return sql }

        var tally: [String: Int] = [:]
        var codeLines = 0
        var strongLines = 0
        var neutralLines = 0
        var inDocstring = false
        var inBlockComment = false

        /// A copy often starts inside a comment or docstring whose opening was
        /// not copied. When its close turns up, everything before it was
        /// commentary, not prose.
        func discardEverything(upTo index: Int) {
            tally = [:]
            codeLines = 0
            strongLines = 0
            neutralLines = index + 1
        }

        for (index, line) in lines.enumerated() {
            let t = line.text
            // Docstrings and block comments are prose inside code; they should
            // neither count for the code nor dilute it.
            if inBlockComment {
                neutralLines += 1
                if t.has("*/") { inBlockComment = false }
                continue
            }
            if t.has("*/"), !t.has("/*") {
                discardEverything(upTo: index)
                continue
            }
            let tripleQuotes = t.occurrences(of: "\"\"\"") + t.occurrences(of: "'''")
            if inDocstring {
                neutralLines += 1
                if tripleQuotes % 2 == 1 { inDocstring = false }
                continue
            }
            if tripleQuotes > 0 {
                if tripleQuotes % 2 == 1 {
                    // `"""Summary` opens a docstring. A bare `"""` (or one that ends
                    // a line, or is followed by `, re.VERBOSE)`) either opens one or
                    // closes one that began before the copy; code right after it
                    // means it closed one.
                    let quoteFirst = t.pre("\"\"\"") || t.pre("'''")
                    let afterQuotes = quoteFirst ? t.dropFirst(3).first : nil
                    let opensWithText = quoteFirst && (afterQuotes?.isLetter == true || afterQuotes == " ")
                    if !opensWithText, codeFollows(lines, after: index) {
                        discardEverything(upTo: index)
                        tally["python", default: 0] += 1
                        continue
                    }
                    inDocstring = true
                }
                codeLines += 1
                tally["python", default: 0] += 1
                continue
            }
            if t.pre("/*"), !t.has("*/") {
                inBlockComment = true
                neutralLines += 1
                continue
            }

            let next = index + 1 < lines.count ? lines[index + 1] : nil
            switch evidence(for: line, next: next) {
            case .neutral:
                neutralLines += 1
            case .code(let language, let strength):
                codeLines += 1
                if strength >= 2 { strongLines += 1 }
                if let language { tally[language, default: 0] += strength }
            case .none:
                break
            }
        }

        let considered = lines.count - neutralLines
        guard considered > 0 else {
            // Nothing but comments. `/*` and `//` never start prose; `#` starts
            // Markdown headings, so it proves nothing.
            if let first = lines.first?.text, first.pre("/*") || first.pre("//") {
                return signatureLanguage(text) ?? "code"
            }
            return nil
        }
        let ratio = Double(codeLines) / Double(considered)
        let markers = structuralMarkerCount(text)

        let isCode: Bool
        if considered == 1 {
            // One line has to be unmistakable on its own.
            isCode = strongLines == 1 || (codeLines == 1 && markers >= 2)
        } else {
            isCode = (ratio >= 0.5 && codeLines >= 2)
                || (strongLines >= 2 && ratio >= 0.3)
                || (ratio >= 0.3 && markers >= 3 && isMostlyIndented(lines))
        }
        guard isCode else { return nil }

        // Prose runs long. A paragraph that trips a few code patterns is still a
        // paragraph.
        let averageLength = lines.reduce(0) { $0 + $1.text.count } / lines.count
        if averageLength > 160, ratio < 0.8 { return nil }

        if let best = tally.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        return signatureLanguage(text) ?? "code"
    }

    // MARK: - Lines

    struct Line {
        /// Trimmed on both ends.
        let text: Substring
        /// Leading whitespace, tabs counted as four.
        let indent: Int
    }

    private static let lineLimit = 200

    static func significantLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        for raw in rawLines(text) {
            var indent = 0
            var start = raw.startIndex
            while start < raw.endIndex, raw[start] == " " || raw[start] == "\t" {
                indent += raw[start] == "\t" ? 4 : 1
                start = raw.index(after: start)
            }
            var end = raw.endIndex
            while end > start, raw[raw.index(before: end)].isWhitespace {
                end = raw.index(before: end)
            }
            guard start < end else { continue }
            lines.append(Line(text: raw[start..<end], indent: indent))
            if lines.count >= lineLimit { break }
        }
        return lines
    }

    /// Lines split on UTF-8 newline bytes, stopping once enough have been seen:
    /// the head of a 1 MB log says as much as the whole of it.
    private static func rawLines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex, result.count < lineLimit * 2 {
            var end = start
            while end < utf8.endIndex, utf8[end] != 0x0A, utf8[end] != 0x0D { utf8.formIndex(after: &end) }
            if end > start { result.append(text[start..<end]) }
            start = end < utf8.endIndex ? utf8.index(after: end) : end
        }
        return result
    }

    /// Whether the first non-comment line after `index` reads as code.
    private static func codeFollows(_ lines: [Line], after index: Int) -> Bool {
        var next = index + 1
        while next < lines.count, next <= index + 6 {
            let following = next + 1 < lines.count ? lines[next + 1] : nil
            switch evidence(for: lines[next], next: following) {
            case .code: return true
            case .none: return false
            case .neutral: next += 1
            }
        }
        return false
    }

    private static func isMostlyIndented(_ lines: [Line]) -> Bool {
        let indented = lines.filter { $0.indent > 0 }.count
        return indented * 3 >= lines.count
    }

    // MARK: - Per-line evidence

    enum Evidence {
        /// Looks like code; `language` when the line says which, `strength` 2 when
        /// the line is unmistakable on its own.
        case code(language: String?, strength: Int)
        /// Comments: neither prose nor code, so they don't dilute the ratio.
        case neutral
        case none
    }

    private static let preprocessor = ["#include", "#import", "#define", "#if", "#endif", "#else", "#elif",
                                       "#pragma", "#undef", "#[", "#!"]

    static func evidence(for line: Line, next: Line?) -> Evidence {
        let opensBlock = next.map { $0.indent > line.indent } ?? false

        // Comments first: they look like anything.
        let raw = line.text
        if raw.pre("//") || raw.pre("/*") || raw.pre("*/") || raw == "*" || raw.pre("* ") {
            return .neutral
        }
        if raw.pre("#"), !preprocessor.contains(where: { raw.pre($0) }) {
            return .neutral
        }
        // `char ar_uid[6];   /* user id */` is judged on the code, not the note.
        let t = stripTrailingComment(raw)
        if t.isEmpty { return .neutral }

        // Doctests: `>>> thread.start()`.
        if t.pre(">>> ") { return .code(language: "python", strength: 2) }

        if let hit = languageEvidence(t, opensBlock: opensBlock) {
            return .code(language: hit.name, strength: hit.strength)
        }
        if isShellCommand(t) {
            return .code(language: "shell", strength: 2)
        }
        if isGenericCode(t) {
            return .code(language: nil, strength: isAssignmentOrCall(t) ? 2 : 1)
        }
        return .none
    }

    /// Cuts a trailing `/* note */` or ` // note` off a line of code. `://` in a
    /// URL has no space before it, so links survive.
    static func stripTrailingComment(_ t: Substring) -> Substring {
        var result = t
        guard t.has("/*") || t.has("//") else { return t }
        if result.suf("*/"), let open = result.range(of: "/*", options: .backwards), open.lowerBound > result.startIndex {
            result = result[..<open.lowerBound]
        }
        for marker in [" //", "\t//"] where result.has(marker) {
            if let range = result.range(of: marker) {
                result = result[..<range.lowerBound]
            }
        }
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return result
    }

    private struct LanguageHit {
        let name: String?
        let strength: Int
    }

    private static func languageEvidence(_ t: Substring, opensBlock: Bool) -> LanguageHit? {
        func hit(_ name: String?, _ strength: Int = 2) -> LanguageHit { LanguageHit(name: name, strength: strength) }
        let endsWithColon = t.suf(":")
        // Only a handful of patterns need the words; most lines are rejected on
        // their first few bytes, so split lazily.
        lazy var words = t.split(separator: " ", omittingEmptySubsequences: true)
        let second: Substring? = {
            guard let space = t.firstIndex(of: " ") else { return nil }
            let rest = t[space...].drop(while: { $0 == " " })
            let word = rest.prefix(while: { $0 != " " })
            return word.isEmpty ? nil : word
        }()

        // Python
        if (t.pre("def ") || t.pre("async def ")) && t.has("(") && endsWithColon { return hit("python") }
        if t.pre("class "), endsWithColon, !t.has("{"), second?.first?.isUppercase == true { return hit("python") }
        if t.pre("from "), words.count >= 4, words[2] == "import", isDottedIdentifier(words[1]) { return hit("python") }
        if t.pre("elif ") && endsWithColon { return hit("python") }
        if t == "else:" || t == "try:" || t == "finally:" { return hit("python") }
        if t.pre("except") && endsWithColon { return hit("python") }
        if (t.pre("if ") || t.pre("while ")) && endsWithColon && !t.has("{") && hasCodeOperator(t) {
            return hit("python")
        }
        if t.pre("for ") && t.has(" in ") && endsWithColon { return hit("python") }
        if t.pre("with ") && endsWithColon && (t.has("(") || t.has(" as ")) { return hit("python") }
        if t.pre("raise "), second?.first?.isUppercase == true || t.has("(") { return hit("python") }
        if t.pre("yield "), t.has("(") || words.count == 2 { return hit("python") }
        if t.pre("lambda ") && t.has(":") { return hit("python") }
        if t.pre("self.") || t.pre("return self") || t.pre("if __name__") { return hit("python") }
        if t == "pass" || t == "raise" { return hit("python", 1) }

        // Ruby
        if t.pre("def "), !endsWithColon, isRubyMethodHead(t) { return hit("ruby") }
        if t == "end" { return hit("ruby", 1) }
        if t.pre("require '") || t.pre("require \"") || t.pre("require_relative ") { return hit("ruby") }
        if t.pre("module "), second?.first?.isUppercase == true, !t.suf("{"), words.count == 2 { return hit("ruby") }
        if t.pre("attr_accessor :") || t.pre("attr_reader :") || t.pre("attr_writer :") { return hit("ruby") }
        if t.has(" do |") { return hit("ruby") }

        // Go
        if t.pre("package "), words.count == 2, second.map(isIdentifier) == true { return hit("go", 1) }
        if t.has(" := ") { return hit("go") }
        if t.pre("if err != nil") || t.pre("func (") || t.pre("fmt.") || t == "import (" || t.pre("go func") {
            return hit("go")
        }
        if t.pre("type ") && (t.suf(" struct {") || t.suf(" interface {")) { return hit("go") }

        // Rust
        if t.pre("fn ") || t.pre("pub fn ") || t.pre("pub(crate) fn ") || t.pre("async fn ") {
            if t.has("(") { return hit("rust") }
        }
        if t.pre("let mut ") || t.pre("impl<") || t.pre("#[") { return hit("rust") }
        if t.pre("impl "), t.suf("{") { return hit("rust") }
        if t.pre("use ") && t.has("::") && t.suf(";") { return hit("rust") }
        if t.has("println!(") || t.has("vec![") || t.has("format!(") { return hit("rust") }
        if t.pre("pub struct ") || t.pre("pub enum ") || (t.pre("mod ") && t.suf(";")) { return hit("rust") }
        if t.pre("match ") && t.suf("{") { return hit("rust", 1) }

        // Swift
        if t.pre("guard "), t.has(" else {") || t.suf(" else"),
           t.has("=") || t.has(".") || t.has("!") || t.has("let ") {
            return hit("swift")
        }
        if t.pre("extension ") || t.pre("protocol "), second?.first?.isUppercase == true,
           t.suf("{") || t.has(":") {
            return hit("swift")
        }
        if t.pre("case .") || t.pre("@State ") || t.pre("@Published ") || t.pre("@MainActor")
            || t.pre("@Observable") || t.pre("@objc") || t.pre("@available(") || t.pre("@Environment(")
            || t.pre("@Binding ") || t.pre("@discardableResult") || t.pre("@testable ")
            || t.has("some View") || t.pre("XCTAssert") || t.pre("init(") || t == "deinit {" {
            return hit("swift")
        }
        let declaration = stripModifiers(t)
        if declaration.pre("func "), declaration.has("(") {
            // `func name(label: Type) -> T` is Swift; Go has no labels or arrows.
            let isSwift = declaration.has(":") || declaration.has("->") || declaration.has("()")
            return hit(isSwift ? "swift" : "go")
        }
        if declaration.pre("init(") || declaration.pre("init?(") || declaration.pre("convenience init") {
            return hit("swift")
        }
        if declaration.pre("case "), declaration.count > 5, declaration.dropFirst(5).first?.isLowercase == true,
           declaration.dropFirst(5).allSatisfy({ $0.isLetter || $0.isNumber || "_, ()=\".:".contains($0) }) {
            // `case earlierToday` on its own could be "case closed"; it only
            // supports other evidence.
            return hit("swift", 1)
        }
        if declaration.pre("let ") || declaration.pre("var ") {
            // `let resultCount: Int` — a typed declaration with no value is Swift.
            let declared = declaration.dropFirst(4).prefix(while: { $0 != " " })
            if declared.suf(":"), isIdentifier(declared.dropLast()), declaration.split(separator: " ").count <= 10 {
                return hit("swift")
            }
            if declaration.suf(";") && declaration.has(" = ") { return hit("javascript", 1) }
            if let colon = declaration.firstIndex(of: ":"), let equals = declaration.firstIndex(of: "="), colon < equals,
               declaration.split(separator: " ").count <= 12 {
                return hit("swift")
            }
            if declaration.has(" = "), declaration.dropFirst(4).first.map({ $0.isLowercase || $0 == "_" }) == true,
               declaration.split(separator: " ")[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                return hit("swift", 1)
            }
        }
        for keyword in ["struct ", "enum ", "class ", "final class ", "actor "] where declaration.pre(keyword) {
            // Types are UpperCamelCase; "class notes: bring laptop" is not a type.
            let name = declaration.dropFirst(keyword.count)
            guard name.first?.isUppercase == true, declaration.suf("{") || declaration.has(": ") else { break }
            return hit(declaration.has(": ") && !declaration.suf(":") ? "swift" : nil)
        }
        if t.pre("import ") {
            let module = t.dropFirst(7)
            if module.pre("\"") || module == "(" { return hit("go") }
            if module.has(" from ") || module.pre("{") || module.pre("* as ") { return hit("javascript") }
            if module.pre("java.") || module.suf(";") { return hit("java") }
            let swiftModules: Set<Substring> = ["Foundation", "SwiftUI", "AppKit", "UIKit", "Combine", "XCTest", "Cocoa",
                                                "CoreGraphics", "Observation", "os", "Carbon", "Vision", "CryptoKit"]
            if swiftModules.contains(module) { return hit("swift") }
            let parts = module.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.allSatisfy({ isPythonImportItem(Substring($0)) }) { return hit("python") }
        }

        // JavaScript and TypeScript
        if t.pre("function ") || t.pre("async function "), t.has("(") { return hit("javascript") }
        if t.pre("export "), let what = second,
           ["default", "const", "function", "class", "{", "*", "type", "interface", "async", "let", "var", "enum"]
            .contains(where: { what.pre($0) }) {
            return hit("javascript")
        }
        if t.pre("const "), t.has(" = ") { return hit("javascript") }
        if t.pre("module.exports") || t.has("require(") || t.has("console.log(") { return hit("javascript") }
        if t.pre("interface "), t.suf("{") { return hit("typescript") }
        if t.has(": string") || t.has(": number") || t.has(": boolean") { return hit("typescript", 1) }

        // Java, Kotlin
        if t.pre("public class ") || t.pre("public static ") || t.pre("private static ")
            || t.has("System.out.") || t == "@Override" {
            return hit("java")
        }
        if t.pre("fun "), let name = second, name.has("("), isIdentifier(name.prefix(while: { $0 != "(" })) {
            return hit("kotlin")
        }

        // C, C++, Objective-C
        if t.pre("#include") || t.pre("#define ") || t.pre("#ifndef ") || t.pre("#ifdef ")
            || t.pre("#endif") || t.pre("#if ") || t.pre("#pragma ") || t.pre("#undef ")
            || t.pre("#else") || t.pre("#elif") || t.pre("typedef ") || t.pre("extern ") {
            return hit("c")
        }
        if t.pre("#import ") || t.pre("@interface ") || t.pre("@implementation ") || t == "@end"
            || t.pre("@property") {
            return hit("objective-c")
        }

        // Shell control flow. On its own a word like "done" is a chat message, so
        // these only ever support other evidence.
        if ["fi", "done", "esac", "then", "do", ";;"].contains(t) { return hit("shell", 1) }
        if t.pre("if [") || (t.pre("for ") && t.suf("; do")) { return hit("shell") }

        // HTML
        if t.pre("<"), t.suf(">"), let tag = t.dropFirst().first, tag.isLetter || tag == "/" || tag == "!" {
            return hit("html", 1)
        }

        // CSS declarations: `color: #333;`
        if t.suf(";"), let colon = t.firstIndex(of: ":"), !t[..<colon].isEmpty,
           t[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }) {
            return hit("css", 1)
        }

        // Python blocks open with a colon and indent what follows.
        if endsWithColon && opensBlock && isKeywordLed(t) { return hit("python", 1) }
        return nil
    }

    /// `public`, `private static`, `override` and friends sit in front of the
    /// keyword that actually says what the line is.
    private static func stripModifiers(_ t: Substring) -> Substring {
        let modifiers = ["public ", "private ", "internal ", "fileprivate ", "open ", "static ", "override ",
                         "final ", "nonisolated ", "mutating ", "lazy ", "weak ", "private(set) ", "public private(set) "]
        var rest = t
        var changed = true
        while changed {
            changed = false
            for modifier in modifiers where rest.pre(modifier) {
                rest = rest.dropFirst(modifier.count)
                changed = true
            }
            // Attributes and property wrappers: `@FocusState`, `@available(macOS 14, *)`.
            if rest.pre("@"), rest.dropFirst().first?.isLetter == true {
                var end = rest.index(after: rest.startIndex)
                while end < rest.endIndex, rest[end].isLetter || rest[end].isNumber || rest[end] == "_" {
                    end = rest.index(after: end)
                }
                if end < rest.endIndex, rest[end] == "(", let close = rest[end...].firstIndex(of: ")") {
                    end = rest.index(after: close)
                }
                if end < rest.endIndex, rest[end] == " " {
                    rest = rest[rest.index(after: end)...]
                    changed = true
                }
            }
            // `class func` and `class var` are modifiers; `class Foo` is a type.
            if rest.pre("class func ") || rest.pre("class var ") {
                rest = rest.dropFirst(6)
                changed = true
            }
        }
        return rest
    }

    private static func isIdentifier(_ s: Substring) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `os.path`, and the relative `.models` / `..` of `from . import x`.
    private static func isDottedIdentifier(_ s: Substring) -> Bool {
        let relative = s.drop(while: { $0 == "." })
        if relative.isEmpty { return !s.isEmpty }
        return relative.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isIdentifier)
    }

    /// `os`, `os.path`, `numpy as np`.
    private static func isPythonImportItem(_ item: Substring) -> Bool {
        let words = item.split(separator: " ")
        switch words.count {
        case 1: return isDottedIdentifier(words[0])
        case 3: return isDottedIdentifier(words[0]) && words[1] == "as" && isIdentifier(words[2])
        default: return false
        }
    }

    /// `def name`, `def name(args)`, `def self.name`, `def valid?` — and nothing
    /// after the head, which is what rules out "def gonna be late".
    private static func isRubyMethodHead(_ line: Substring) -> Bool {
        var rest = line.dropFirst(4)
        if rest.pre("self.") { rest = rest.dropFirst(5) }
        let name = rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        guard let first = name.first, first.isLowercase || first == "_" else { return false }
        var after = rest.dropFirst(name.count)
        if after.first == "?" || after.first == "!" { after = after.dropFirst() }
        return after.isEmpty || (after.pre("(") && after.suf(")"))
    }

    private static let blockKeywords: Set<Substring> = [
        "if", "for", "while", "def", "class", "with", "try", "else", "elif", "except", "match", "case",
    ]

    private static func isKeywordLed(_ t: Substring) -> Bool {
        blockKeywords.contains(t.prefix(while: { $0 != " " && $0 != ":" }))
    }

    private static func hasCodeOperator(_ t: Substring) -> Bool {
        t.has("=") || t.has("<") || t.has(">") || t.has("(") || t.has("[") || t.has(" not ")
            || t.has(".")
    }

    // MARK: - Generic syntax

    private static func isGenericCode(_ t: Substring) -> Bool {
        let closers: Set<Substring> = ["}", ")", "]", "})", "};", "});", ");", "],", "},", "end)"]
        if closers.contains(t) { return true }
        if t.pre("}") || t.pre("]") || t.pre(")") { return true }
        if t.suf("{") || t.suf(";") || t.suf("(") || t.suf("[") { return !looksLikeSentence(t) }
        if t.pre("return ") && (t.has("(") || t.has(".") || t.has("=") || t.split(separator: " ").count <= 3) {
            return true
        }
        if t == "return" || t == "break" || t == "continue" { return true }
        if isAssignmentOrCall(t) { return true }
        let operators = ["==", "!=", "&&", "||", "->", "=>", "::", "+=", "-=", "++", "<=", ">="]
        if operators.contains(where: { t.has($0) }) && !looksLikeSentence(t) { return true }
        return isListOrArgumentLine(t) || isMacroOrDeclaration(t)
    }

    /// The inside of a literal or an argument list: `'json',`, `...opts,`,
    /// `spec: p,`, `localBin,`, `.font(.body)`. Each is weak alone; a run of them
    /// is a list in code.
    private static func isListOrArgumentLine(_ t: Substring) -> Bool {
        // A quoted element: `'json',`
        if let quote = t.first, "'\"`".contains(quote), t.count > 3, t.suf("\(quote),") { return true }
        // A spread: `...opts,`
        if t.pre("..."), t.suf(","), t.dropFirst(3).first?.isLetter == true { return true }
        // A chained call: `.font(Theme.Font.badge)`
        if t.pre(".") {
            let name = t.dropFirst().prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            if name.first?.isLetter == true, t.dropFirst(1 + name.count).first == "(" { return true }
        }
        if t.suf(","), let first = t.first, first.isLowercase || first == "_" {
            let body = t.dropLast()
            if isIdentifier(body) { return true }
            // `key: value,` with an identifier key.
            if let colon = body.firstIndex(of: ":"), isIdentifier(body[..<colon]),
               body[body.index(after: colon)...].pre(" "), body.split(separator: " ").count <= 8 {
                return true
            }
        }
        return false
    }

    /// C headers: `__BEGIN_DECLS`, `XP_BadMatch = 8,`, and prototypes split over
    /// lines such as `asl_object_t asl_retain(asl_object_t obj)`.
    private static func isMacroOrDeclaration(_ t: Substring) -> Bool {
        if !t.has(" "), t.has("_"), t.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) { return true }
        // An enum value: `... = -12,`
        if t.has("= "), let equals = t.range(of: "= ", options: .backwards) {
            let value = t[equals.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if !value.isEmpty, value.allSatisfy({ $0.isHexDigit || "-xXuUlL".contains($0) }), t.first?.isLetter == true
                || t.first == "_" {
                return true
            }
        }
        // `type name(args)`: an identifier glued to its parenthesis, after a type.
        if t.suf(")") || t.suf(");") || t.suf(") {") {
            guard let paren = t.firstIndex(of: "("), paren > t.startIndex else { return false }
            let head = t[..<paren]
            guard let last = head.last, last.isLetter || last.isNumber || last == "_" else { return false }
            let tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" })
            return tokens.count >= 2 && tokens.allSatisfy { isIdentifier($0) } && !looksLikeSentence(t)
        }
        return false
    }

    /// Declaration keywords that can sit in front of an assignment.
    private static let assignmentKeywords: Set<Substring> = [
        "static", "let", "var", "const", "val", "private", "public", "protected", "readonly", "final", "export", "auto",
    ]

    /// `x = 1`, `self.name = name`, `static params = [`, `main()`, `print(total(cart))`.
    static func isAssignmentOrCall(_ line: Substring) -> Bool {
        var t = line
        while let space = t.firstIndex(where: { $0 == " " || $0 == "\t" }), assignmentKeywords.contains(t[..<space]) {
            t = t[space...].drop(while: { $0 == " " || $0 == "\t" })
        }
        guard let first = t.first, first.isLetter || first == "_" || first == "$" else { return false }
        var index = t.startIndex
        // An identifier path: letters, digits, `_`, `.`, `?`, `!`, `#`, and subscripts.
        while index < t.endIndex {
            let c = t[index]
            if c.isLetter || c.isNumber || "_.$[]\"'?!#".contains(c) {
                index = t.index(after: index)
            } else {
                break
            }
        }
        guard index > t.startIndex, index < t.endIndex else { return false }
        let rest = t[index...]
        if rest.pre("(") {
            // A call statement: the whole line is the call.
            return t.suf(")") || t.suf(");")
        }
        let afterSpace = rest.drop(while: { $0 == " " || $0 == "\t" })
        for op in ["= ", "+= ", "-= ", "*= ", "/= ", "|= ", "&= ", ":= "] where afterSpace.pre(op) {
            // Prose rarely puts a lone `=` after its first word, and never in a
            // long sentence.
            return line.split(separator: " ").count <= 12
        }
        return false
    }

    private static func looksLikeSentence(_ t: Substring) -> Bool {
        let words = t.split(separator: " ")
        guard words.count >= 6 else { return false }
        let plain = words.filter { $0.allSatisfy { $0.isLetter || $0 == "," || $0 == "'" || $0 == "." } }.count
        return plain * 3 >= words.count * 2
    }

    // MARK: - Shell

    /// Tools whose name is not also an English word: a subcommand is enough.
    private static let distinctCommands: Set<Substring> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "docker", "kubectl", "xcodebuild", "xcrun", "cargo", "rustup",
        "pip", "pip3", "gh", "ssh", "scp", "rsync", "curl", "wget", "sudo", "jq", "launchctl", "defaults",
        "killall", "pkill", "codesign", "plutil", "mdfind", "pbcopy", "pbpaste", "terraform", "helm", "psql",
        "sqlite3", "swiftc", "clang", "gcc", "tmux", "nvim", "vim", "deno", "bun", "uv", "poetry", "pytest", "tsc",
        "ffmpeg", "openssl", "xattr", "diskutil", "hdiutil", "simctl", "chmod", "chown", "mkdir", "rmdir", "grep",
        "rg", "sed", "awk", "tar", "cd", "ls", "rm", "fastlane", "rake", "mvn", "gradle", "dotnet",
        "aws", "gcloud", "az", "lsof", "ps",
    ]

    /// Tools named with ordinary words, recognised by their own subcommands:
    /// `go test` is a command, "go home" is not.
    private static let subcommandTools: [Substring: Set<Substring>] = [
        "go": ["run", "build", "test", "mod", "get", "install", "fmt", "vet", "generate", "work", "env", "version",
               "clean", "doc", "list", "tool"],
        "swift": ["build", "test", "run", "package", "format", "repl", "sdk"],
        "make": ["test", "build", "install", "clean", "all", "run", "app", "release", "debug", "check", "lint",
                 "format", "fmt", "dev", "deploy", "docs", "setup", "bootstrap", "dist", "watch", "serve",
                 "start", "stop", "up", "down", "tidy", "bundle", "archive", "publish"],
        "gem": ["install", "uninstall", "update", "list", "build", "push"],
    ]

    /// Tools that are also ordinary words: they need arguments that look like
    /// arguments (a flag, a path, a variable, an operator) before they count.
    private static let wordCommands: Set<Substring> = [
        "open", "find", "touch", "head", "tail", "cat", "less", "echo", "export", "source", "code", "cp", "mv", "ln",
        "du", "df", "wc", "sort", "cut", "tr", "tee", "env", "which", "man", "time", "watch", "date", "file",
        "unset", "alias", "eval", "exec", "test", "say", "sleep", "caffeinate", "sips", "screencapture", "kill",
        "ruby", "pod", "bundle", "sh", "bash", "zsh", "python", "python3", "node", "ping", "dig", "go", "swift",
        "make", "gem",
    ]

    static func isShellCommand(_ line: Substring) -> Bool {
        var t = line
        if t.pre("$ ") { return t.count > 2 }
        if t.pre("sudo ") { t = t.dropFirst(5) }
        let command = t.prefix(while: { $0 != " " })
        guard distinctCommands.contains(command) || wordCommands.contains(command) else { return false }
        if let subcommands = subcommandTools[command], let second = t.dropFirst(command.count).split(separator: " ").first,
           subcommands.contains(second), !(t.last.map { ".?!".contains($0) } ?? false) {
            return true
        }
        let tokens = t.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2 else { return false }
        // A sentence that happens to start with a tool name ends like a sentence.
        if let last = t.last, ".?!".contains(last), t.dropLast().last?.isLetter == true { return false }
        if looksLikeSentence(t) { return false }

        let arguments = tokens.dropFirst()
        let argumentLike = arguments.contains(where: looksLikeArgument)
        let hasOperator = ["&&", "||", " | ", " > ", " >> ", "2>&1", "$(", "`"].contains(where: { t.has($0) })

        if distinctCommands.contains(command) {
            guard let second = arguments.first else { return false }
            // `npm ERR! code ERESOLVE` is npm talking, not a command.
            let isSubcommand = second.first.map { $0.isLowercase || $0.isNumber } == true
                && second.allSatisfy { $0.isLowercase || $0.isNumber || "-_.:/@=+~".contains($0) }
            return isSubcommand || argumentLike || hasOperator
        }
        if wordCommands.contains(command) {
            return argumentLike || hasOperator
        }
        return false
    }

    private static func looksLikeArgument(_ token: Substring) -> Bool {
        if token.pre("-") && token.count > 1 && token.dropFirst().first?.isLetter == true { return true }
        if token.pre("--") && token.count > 2 { return true }
        if token == "." || token == ".." || token.pre("./") || token.pre("../") || token.pre("~") { return true }
        if token.pre("/") || token.pre("$") || token.has("=") || token.has("*") { return true }
        if token.has("/") && !token.pre("http") { return true }
        // file.ext
        if let dot = token.lastIndex(of: "."), dot > token.startIndex, token.index(after: dot) < token.endIndex,
           token[token.index(after: dot)...].allSatisfy({ $0.isLetter || $0.isNumber }) {
            return true
        }
        return false
    }

    // MARK: - SQL

    private static func sqlLanguage(_ lines: [Line]) -> String? {
        guard let first = lines.first?.text else { return nil }
        let upper = first.uppercased()
        let statements = ["SELECT ", "INSERT INTO ", "UPDATE ", "DELETE FROM ", "CREATE TABLE ", "CREATE INDEX ",
                          "CREATE UNIQUE INDEX ", "CREATE VIEW ", "ALTER TABLE ", "DROP TABLE ", "WITH "]
        guard statements.contains(where: { upper.pre($0) }) else { return nil }

        let whole = lines.map { $0.text.uppercased() }.joined(separator: " ")
        let clauses = [" FROM ", " WHERE ", " SET ", " VALUES", " INTO ", " JOIN ", " GROUP BY ", " ORDER BY ", " AS ("]
        guard clauses.contains(where: { whole.has($0) }) || whole.suf(" FROM") else { return nil }

        // "Select the file from the menu." has the words but not the shape: real
        // SQL is shouted, or punctuated.
        let keyword = first.prefix(while: { $0 != " " })
        let shouted = keyword == keyword.uppercased()
        let punctuated = whole.has("*") || whole.has("=") || whole.has(";") || whole.has(",")
            || whole.has("(")
        guard shouted || punctuated else { return nil }
        if let last = lines.last?.text.last, last == "." || last == "?" || last == "!" { return nil }
        return "sql"
    }

    // MARK: - YAML

    /// Two or more `key:` lines, at least one nested under another, and nearly
    /// nothing that is neither a key, a list item nor a comment.
    private static func isYAML(_ lines: [Line]) -> Bool {
        guard lines.count >= 2 else { return false }
        var keys = 0
        var nestedKeys = 0
        var other = 0
        for line in lines {
            let t = line.text
            if t == "---" || t.pre("#") || t.pre("- ") || t == "-" { continue }
            if isYAMLKey(t) {
                keys += 1
                if line.indent > 0 { nestedKeys += 1 }
            } else {
                other += 1
            }
        }
        return keys >= 2 && nestedKeys >= 1 && other * 5 <= lines.count
    }

    private static func isYAMLKey(_ t: Substring) -> Bool {
        guard let colon = t.firstIndex(of: ":") else { return false }
        let key = t[..<colon]
        guard let first = key.first, first.isLetter || first == "_" || first == "\"",
              key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.\"".contains($0) }) else { return false }
        let after = t[t.index(after: colon)...]
        return after.isEmpty || after.pre(" ")
    }

    // MARK: - Fallbacks

    /// Structural markers that say "this is code" regardless of language.
    private static let structuralMarkers = ["{", "}", "();", ";", "=>", "->", "::", "==", "!=", "&&", "||"]

    private static func structuralMarkerCount(_ text: String) -> Int {
        structuralMarkers.filter { text.has($0) }.count
    }

    /// Keywords that are near-conclusive for a language when they appear as whole
    /// words. Used only when no line named a language on its own.
    private static let signatures: [(language: String, keywords: [String])] = [
        ("swift", ["func", "guard", "@State", "SwiftUI", "let ", "var ", "struct", "enum", "extension", "@objc"]),
        ("rust", ["fn ", "impl ", "pub fn", "let mut", "match ", "->", "use std", "#[derive"]),
        ("python", ["def ", "import ", "self", "elif", "lambda", "__init__", "print(", "None"]),
        ("typescript", ["interface ", "type ", ": string", ": number", "export const", "=> {", "async ", "await "]),
        ("javascript", ["function ", "const ", "let ", "=> {", "console.log", "require(", "export default"]),
        ("go", ["func ", "package ", "import (", ":=", "nil", "defer ", "chan "]),
        ("java", ["public class", "private ", "void ", "@Override", "System.out", "import java"]),
        ("c", ["#include", "#define", "typedef", "struct ", "void ", "int ", "char ", "NULL"]),
        ("html", ["<div", "<span", "<html", "<!DOCTYPE", "</", "<p>", "<a href"]),
        ("css", ["px;", "rem;", "@media", "color:", "margin:", "padding:"]),
    ]

    private static func signatureLanguage(_ text: String) -> String? {
        var best: (language: String, score: Int)?
        for signature in signatures {
            var score = 0
            for keyword in signature.keywords where text.has(keyword) {
                // Longer keywords are more distinctive, so weight by length.
                score += keyword.count
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (signature.language, score)
            }
        }
        return best?.language
    }
}

// MARK: - Byte-level matching

/// Classification runs on every copy and asks each line dozens of questions.
/// Foundation's `contains`/`hasPrefix` bridge through `NSString` on every call;
/// comparing UTF-8 bytes keeps a 200-line log well under a millisecond.
extension StringProtocol {
    fileprivate func pre(_ prefix: String) -> Bool {
        compare(prefix, atEnd: false)
    }

    fileprivate func suf(_ suffix: String) -> Bool {
        compare(suffix, atEnd: true)
    }

    private func compare(_ other: String, atEnd: Bool) -> Bool {
        var other = other
        other.makeContiguousUTF8()
        let result: Bool?? = other.utf8.withContiguousStorageIfAvailable { theirs -> Bool? in
            utf8.withContiguousStorageIfAvailable { mine -> Bool in
                guard mine.count >= theirs.count else { return false }
                guard let theirBase = theirs.baseAddress, let myBase = mine.baseAddress else { return theirs.isEmpty }
                let start = atEnd ? mine.count - theirs.count : 0
                return memcmp(myBase + start, theirBase, theirs.count) == 0
            }
        }
        if let answer = result ?? nil { return answer }
        return atEnd ? utf8.reversed().starts(with: other.utf8.reversed()) : utf8.starts(with: other.utf8)
    }

    fileprivate func has(_ needle: String) -> Bool {
        occurrenceIndex(of: needle, from: 0) != nil
    }

    fileprivate func occurrences(of needle: String) -> Int {
        var count = 0
        var from = 0
        while let found = occurrenceIndex(of: needle, from: from) {
            count += 1
            from = found + needle.utf8.count
        }
        return count
    }

    /// Byte offset of the first occurrence at or after `from`.
    private func occurrenceIndex(of needle: String, from: Int) -> Int? {
        var needle = needle
        needle.makeContiguousUTF8()
        return needle.utf8.withContiguousStorageIfAvailable { needleBytes -> Int? in
            guard needleBytes.count > 0 else { return from }
            let found: Int?? = utf8.withContiguousStorageIfAvailable { hay -> Int? in
                Self.search(hay, needleBytes, from: from)
            }
            if let found { return found }
            // Bridged strings have no contiguous UTF-8; copy once and search that.
            return Array(utf8).withUnsafeBufferPointer { Self.search($0, needleBytes, from: from) }
        } ?? nil
    }

    private static func search(_ hay: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < hay.count, let base = hay.baseAddress, let needleBase = needle.baseAddress,
              let found = memmem(base + from, hay.count - from, needleBase, needle.count) else { return nil }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }
}
