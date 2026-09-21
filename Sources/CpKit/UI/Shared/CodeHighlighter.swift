import SwiftUI

/// Colours a short code preview.
///
/// Deliberately a scanner and not a parser: it runs on at most a screenful of
/// text, it never has to be right about a whole file, and a wrong colour costs
/// a wrong colour. What it buys is that two snippets stop looking identical —
/// the same reason clippings are typed in the first place.
public enum CodeHighlighter {

    /// `text` in mono, with strings, comments, numbers and keywords coloured.
    public static func attributed(_ text: String, language: String?, font: Font) -> AttributedString {
        var result = AttributedString()
        let keywords = Self.keywords(for: language)
        let commentMarkers = Self.commentMarkers(for: language)
        let scalars = Array(text)
        var index = 0

        func append(_ piece: String, _ colour: Color?) {
            var run = AttributedString(piece)
            if let colour { run.foregroundColor = colour }
            result += run
        }

        while index < scalars.count {
            let character = scalars[index]

            // Strings, single or double quoted, escapes included.
            if character == "\"" || character == "'" {
                let quote = character
                var end = index + 1
                while end < scalars.count, scalars[end] != quote, scalars[end] != "\n" {
                    if scalars[end] == "\\", end + 1 < scalars.count { end += 1 }
                    end += 1
                }
                if end < scalars.count, scalars[end] == quote { end += 1 }
                append(String(scalars[index..<end]), Theme.Code.string)
                index = end
                continue
            }

            // Comments to the end of the line.
            if let marker = commentMarkers.first(where: { matches($0, in: scalars, at: index) }) {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                _ = marker
                append(String(scalars[index..<end]), Theme.Code.comment)
                index = end
                continue
            }

            // Numbers.
            if character.isNumber, index == 0 || !isWordCharacter(scalars[index - 1]) {
                var end = index
                while end < scalars.count, scalars[end].isNumber || scalars[end] == "." || scalars[end] == "_" { end += 1 }
                append(String(scalars[index..<end]), Theme.Code.number)
                index = end
                continue
            }

            // A command-line flag is the one thing that makes a shell line
            // readable, so it gets a colour of its own.
            if character == "-", index > 0, scalars[index - 1] == " ", index + 1 < scalars.count,
               scalars[index + 1].isLetter || scalars[index + 1] == "-" {
                var end = index
                while end < scalars.count, scalars[end] == "-" { end += 1 }
                while end < scalars.count, isWordCharacter(scalars[end]) || scalars[end] == "-" { end += 1 }
                append(String(scalars[index..<end]), Theme.Code.key)
                index = end
                continue
            }

            if isWordCharacter(character), !character.isNumber {
                var end = index
                while end < scalars.count, isWordCharacter(scalars[end]) { end += 1 }
                let word = String(scalars[index..<end])
                let next = end < scalars.count ? scalars[end] : " "
                if keywords.contains(word) {
                    append(word, Theme.Code.keyword)
                } else if next == "(" {
                    append(word, Theme.Code.function)
                } else if let first = word.first, first.isUppercase {
                    append(word, Theme.Code.type)
                } else {
                    append(word, nil)
                }
                index = end
                continue
            }

            var end = index
            while end < scalars.count, !isInteresting(scalars[end]) { end += 1 }
            if end == index { end += 1 }
            append(String(scalars[index..<end]), nil)
            index = end
        }

        result.font = font
        return result
    }

    /// JSON gets its own pass: keys read differently from values, which is most
    /// of what you are scanning for.
    public static func json(_ text: String, font: Font) -> AttributedString {
        var result = AttributedString()
        let scalars = Array(text)
        var index = 0

        func append(_ piece: String, _ colour: Color?) {
            var run = AttributedString(piece)
            if let colour { run.foregroundColor = colour }
            result += run
        }

        while index < scalars.count {
            let character = scalars[index]
            if character == "\"" {
                var end = index + 1
                while end < scalars.count, scalars[end] != "\"" {
                    if scalars[end] == "\\", end + 1 < scalars.count { end += 1 }
                    end += 1
                }
                if end < scalars.count { end += 1 }
                var after = end
                while after < scalars.count, scalars[after] == " " { after += 1 }
                let isKey = after < scalars.count && scalars[after] == ":"
                append(String(scalars[index..<end]), isKey ? Theme.Code.key : Theme.Code.string)
                index = end
                continue
            }
            if character.isNumber || (character == "-" && index + 1 < scalars.count && scalars[index + 1].isNumber) {
                var end = index + 1
                while end < scalars.count, scalars[end].isNumber || scalars[end] == "." || scalars[end] == "e"
                    || scalars[end] == "-" || scalars[end] == "+" { end += 1 }
                append(String(scalars[index..<end]), Theme.Code.number)
                index = end
                continue
            }
            if character.isLetter {
                var end = index
                while end < scalars.count, scalars[end].isLetter { end += 1 }
                let word = String(scalars[index..<end])
                append(word, ["true", "false", "null"].contains(word) ? Theme.Code.keyword : nil)
                index = end
                continue
            }
            append(String(character), nil)
            index += 1
        }

        result.font = font
        return result
    }

    // MARK: - Words

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$" || character == "@"
    }

    private static func isInteresting(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == "/" || character == "#" || isWordCharacter(character)
    }

    private static func matches(_ marker: String, in scalars: [Character], at index: Int) -> Bool {
        let characters = Array(marker)
        guard index + characters.count <= scalars.count else { return false }
        for offset in characters.indices where scalars[index + offset] != characters[offset] { return false }
        return true
    }

    private static func commentMarkers(for language: String?) -> [String] {
        switch language?.lowercased() {
        case "shell", "python", "yaml", "ruby": return ["#"]
        case "sql": return ["--"]
        case "css", "json", nil: return ["/*"]
        default: return ["//"]
        }
    }

    private static func keywords(for language: String?) -> Set<String> {
        switch language?.lowercased() {
        case "swift": return swift
        case "python": return python
        case "javascript", "typescript": return javascript
        case "go": return go
        case "rust": return rust
        case "java", "c": return cLike
        case "shell": return shell
        case "sql": return sql
        default: return common
        }
    }

    private static let swift: Set<String> = [
        "func", "let", "var", "return", "guard", "else", "if", "import", "struct", "class", "enum", "nil", "self",
        "true", "false", "private", "public", "internal", "static", "in", "for", "while", "case", "switch",
        "extension", "init", "throws", "try", "await", "async", "some", "protocol", "where", "defer", "typealias",
    ]
    private static let python: Set<String> = [
        "def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
        "None", "True", "False", "with", "as", "try", "except", "finally", "raise", "lambda", "yield", "async", "await",
    ]
    private static let javascript: Set<String> = [
        "function", "const", "let", "var", "return", "if", "else", "for", "while", "import", "from", "export",
        "default", "class", "new", "this", "null", "undefined", "true", "false", "async", "await", "try", "catch",
        "interface", "type", "extends", "implements", "public", "private", "readonly",
    ]
    private static let go: Set<String> = [
        "func", "package", "import", "return", "if", "else", "for", "range", "var", "const", "type", "struct",
        "interface", "go", "defer", "chan", "select", "switch", "case", "nil", "true", "false", "map",
    ]
    private static let rust: Set<String> = [
        "fn", "let", "mut", "pub", "use", "impl", "struct", "enum", "trait", "match", "if", "else", "for", "while",
        "loop", "return", "self", "Self", "mod", "crate", "async", "await", "move", "where", "true", "false",
    ]
    private static let cLike: Set<String> = [
        "int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef", "static", "const",
        "class", "public", "private", "protected", "new", "delete", "null", "true", "false", "import", "package",
    ]
    private static let shell: Set<String> = [
        "if", "then", "fi", "for", "do", "done", "export", "cd", "sudo", "echo", "while", "case", "esac", "function",
        "local", "return", "source", "set",
    ]
    private static let sql: Set<String> = [
        "select", "from", "where", "join", "left", "inner", "outer", "group", "order", "by", "having", "limit",
        "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "as", "on", "and", "or",
        "SELECT", "FROM", "WHERE", "JOIN", "GROUP", "ORDER", "BY", "LIMIT", "INSERT", "INTO", "VALUES", "UPDATE",
    ]
    private static let common: Set<String> = swift.union(javascript).union(python)
}
