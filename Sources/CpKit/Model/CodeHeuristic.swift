import Foundation

/// Decides whether a blob of text is source code, and if so which language.
///
/// This is a scorer, not a parser. It exists to make the *row* look right — a
/// monospace, syntax-coloured, three-line preview with a language badge — and a
/// wrong guess costs a mislabelled badge, not correctness. That budget buys a
/// much simpler implementation than a real tokenizer.
public enum CodeHeuristic {

    /// Keywords that are near-conclusive for a language when they appear as whole
    /// words. Ordered most-distinctive first within each language.
    private static let signatures: [(language: String, keywords: [String])] = [
        ("swift", ["func", "guard", "@State", "SwiftUI", "let ", "var ", "struct", "enum", "extension", "@objc"]),
        ("rust", ["fn ", "impl ", "pub fn", "let mut", "match ", "->", "use std", "#[derive"]),
        ("python", ["def ", "import ", "self", "elif", "lambda", "__init__", "print(", "None"]),
        ("typescript", ["interface ", "type ", ": string", ": number", "export const", "=> {", "async ", "await "]),
        ("javascript", ["function ", "const ", "let ", "=> {", "console.log", "require(", "export default"]),
        ("go", ["func ", "package ", "import (", ":=", "nil", "defer ", "chan "]),
        ("java", ["public class", "private ", "void ", "@Override", "System.out", "import java"]),
        ("ruby", ["def ", "end", "puts ", "require ", "do |", "@"]),
        ("shell", ["#!/", "echo ", "export ", "$(", "fi", "esac", "&&", "||"]),
        ("sql", ["SELECT ", "FROM ", "WHERE ", "JOIN ", "INSERT INTO", "UPDATE ", "GROUP BY"]),
        ("html", ["<div", "<span", "<html", "<!DOCTYPE", "</", "<p>", "<a href"]),
        ("css", ["{", "}", ":", ";", "px", "rem", "@media", "--"]),
    ]

    /// Structural markers that say "this is code" regardless of language.
    private static let structuralMarkers = ["{", "}", "();", ";", "=>", "->", "::", "==", "!=", "&&", "||"]

    public static func detectLanguage(_ text: String) -> String? {
        guard looksLikeCode(text) else { return nil }

        var best: (language: String, score: Int)?
        for signature in signatures {
            var score = 0
            for keyword in signature.keywords where text.contains(keyword) {
                // Longer keywords are more distinctive, so weight by length.
                score += keyword.count
            }
            if score > 0, score > (best?.score ?? 0) {
                best = (signature.language, score)
            }
        }
        // CSS scores on punctuation alone, so demand a real declaration before
        // believing it over a generic "code" verdict.
        if best?.language == "css", !text.contains(";"), !text.contains("@media") {
            return "code"
        }
        return best?.language ?? "code"
    }

    /// The gate. Prose with one semicolon in it is still prose.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        if text.hasPrefix("#!") { return true }

        var markerHits = 0
        for marker in structuralMarkers where text.contains(marker) {
            markerHits += 1
        }

        let indentedLines = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let isIndented = lines.count > 1 && indentedLines * 2 >= lines.count

        // Prose runs long and unpunctuated by code markers; code runs short and dense.
        let averageLineLength = lines.isEmpty ? 0 : text.count / lines.count
        let isDense = averageLineLength < 120

        if markerHits >= 3 && isDense { return true }
        if markerHits >= 2 && isIndented { return true }
        if lines.count > 2 && isIndented && markerHits >= 1 { return true }
        return false
    }
}
