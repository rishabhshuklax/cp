import Foundation

/// Re-spaces JSON without re-encoding it.
///
/// `JSONSerialization` round-trips through dictionaries and doubles, so key order
/// is lost, `10.10` comes back as `10.1` and a 20-digit id loses precision — a
/// "pretty-print" that quietly edits your data. This works on tokens instead:
/// strings and numbers are copied byte for byte, keys stay in the order they were
/// written, and only the whitespace between tokens changes. Invalid JSON returns
/// `nil`, so the caller keeps the original.
public enum JSONFormatter {

    public static func pretty(_ s: String, indent: Int = 2) -> String? {
        format(s, style: .pretty(max(0, indent)))
    }

    public static func minified(_ s: String) -> String? {
        format(s, style: .minified)
    }

    /// The top-level container and how many members it has, or `nil` when the
    /// text is not a JSON object or array. Used by the classifier, which only
    /// calls something JSON when it is a container — a bare `42` is not what
    /// anyone means.
    struct Summary: Equatable {
        let isObject: Bool
        let count: Int
    }

    static func summary(_ s: String) -> Summary? {
        var scanner = Scanner(style: .validate)
        guard let result = scanner.run(s) else { return nil }
        return result.summary
    }

    // MARK: - Scanner

    private enum Style {
        case pretty(Int)
        case minified
        case validate
    }

    private static func format(_ s: String, style: Style) -> String? {
        var scanner = Scanner(style: style)
        guard let result = scanner.run(s) else { return nil }
        return String(decoding: result.output, as: UTF8.self)
    }

    private struct Result {
        var output: [UInt8]
        var summary: Summary?
    }

    /// A single pass over the UTF-8 bytes: validates the grammar with an explicit
    /// stack (no recursion, so deep nesting cannot overflow) and writes the
    /// re-spaced output as it goes.
    private struct Scanner {
        let style: Style
        var output: [UInt8] = []
        /// One entry per open container: true for an object.
        var stack: [Bool] = []
        /// Members seen in the top-level container, for `summary`.
        var topLevelCount = 0
        var topLevelIsObject: Bool?

        init(style: Style) {
            self.style = style
        }

        private enum Expect {
            case value            // start, after `:`, after `,` in an array
            case valueOrClose     // right after `[`
            case keyOrClose       // right after `{`
            case key              // after `,` in an object
            case colon
            case commaOrClose
            case end
        }

        mutating func run(_ s: String) -> Result? {
            let bytes = Array(s.utf8)
            var i = 0
            // A UTF-8 byte order mark is legal noise at the very start.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }

            if case .validate = style {} else { output.reserveCapacity(bytes.count + bytes.count / 4) }

            var expect = Expect.value
            var justOpened = false

            while true {
                // Skip insignificant whitespace.
                while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 {
                    i += 1
                }
                guard i < bytes.count else { break }
                let byte = bytes[i]

                switch byte {
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    guard expect == .value || expect == .valueOrClose else { return nil }
                    beginToken(&justOpened)
                    let isObject = byte == UInt8(ascii: "{")
                    if stack.isEmpty { topLevelIsObject = isObject }
                    noteMember()
                    stack.append(isObject)
                    emit(byte)
                    justOpened = true
                    expect = isObject ? .keyOrClose : .valueOrClose
                    i += 1

                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    let isObject = byte == UInt8(ascii: "}")
                    guard let open = stack.last, open == isObject else { return nil }
                    switch expect {
                    case .commaOrClose: break
                    case .keyOrClose where isObject: break
                    case .valueOrClose where !isObject: break
                    default: return nil
                    }
                    stack.removeLast()
                    if justOpened {
                        // Empty container: `{}` / `[]`, no line break inside.
                        justOpened = false
                    } else {
                        newline(depth: stack.count)
                    }
                    emit(byte)
                    expect = stack.isEmpty ? .end : .commaOrClose
                    i += 1

                case UInt8(ascii: ","):
                    guard expect == .commaOrClose, let open = stack.last else { return nil }
                    emit(byte)
                    newline(depth: stack.count)
                    expect = open ? .key : .value
                    i += 1

                case UInt8(ascii: ":"):
                    guard expect == .colon else { return nil }
                    emit(byte)
                    if case .pretty = style { emit(0x20) }
                    expect = .value
                    i += 1

                case UInt8(ascii: "\""):
                    let isKey = expect == .key || expect == .keyOrClose
                    guard isKey || expect == .value || expect == .valueOrClose else { return nil }
                    guard let end = Self.stringEnd(bytes, from: i) else { return nil }
                    beginToken(&justOpened)
                    if !isKey { noteMember() } else if stack.count == 1 { topLevelCount += 1 }
                    emit(bytes[i..<end])
                    i = end
                    expect = isKey ? .colon : (stack.isEmpty ? .end : .commaOrClose)

                case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                    guard expect == .value || expect == .valueOrClose else { return nil }
                    guard let end = Self.numberEnd(bytes, from: i) else { return nil }
                    beginToken(&justOpened)
                    noteMember()
                    emit(bytes[i..<end])
                    i = end
                    expect = stack.isEmpty ? .end : .commaOrClose

                case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
                    guard expect == .value || expect == .valueOrClose else { return nil }
                    let literal: [UInt8]
                    switch byte {
                    case UInt8(ascii: "t"): literal = Array("true".utf8)
                    case UInt8(ascii: "f"): literal = Array("false".utf8)
                    default: literal = Array("null".utf8)
                    }
                    let end = i + literal.count
                    guard end <= bytes.count, Array(bytes[i..<end]) == literal else { return nil }
                    beginToken(&justOpened)
                    noteMember()
                    emit(bytes[i..<end])
                    i = end
                    expect = stack.isEmpty ? .end : .commaOrClose

                default:
                    return nil
                }
            }

            guard expect == .end, stack.isEmpty else { return nil }
            let summary = topLevelIsObject.map { Summary(isObject: $0, count: topLevelCount) }
            return Result(output: output, summary: summary)
        }

        /// Counts values that sit directly inside the top-level array. Object
        /// members are counted by their key instead.
        private mutating func noteMember() {
            if stack.count == 1, stack[0] == false { topLevelCount += 1 }
        }

        /// The first token inside a container goes on its own line.
        private mutating func beginToken(_ justOpened: inout Bool) {
            if justOpened {
                newline(depth: stack.count)
                justOpened = false
            }
        }

        private mutating func newline(depth: Int) {
            guard case .pretty(let indent) = style else { return }
            output.append(0x0A)
            if indent > 0 {
                output.append(contentsOf: repeatElement(0x20, count: depth * indent))
            }
        }

        private mutating func emit(_ byte: UInt8) {
            if case .validate = style { return }
            output.append(byte)
        }

        private mutating func emit(_ slice: ArraySlice<UInt8>) {
            if case .validate = style { return }
            output.append(contentsOf: slice)
        }

        /// Index just past the closing quote, validating escapes on the way.
        private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int? {
            var i = start + 1
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") { return i + 1 }
                if byte < 0x20 { return nil }
                if byte == UInt8(ascii: "\\") {
                    guard i + 1 < bytes.count else { return nil }
                    switch bytes[i + 1] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                         UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                         UInt8(ascii: "r"), UInt8(ascii: "t"):
                        i += 2
                    case UInt8(ascii: "u"):
                        guard i + 5 < bytes.count,
                              bytes[(i + 2)...(i + 5)].allSatisfy(Self.isHexDigit) else { return nil }
                        i += 6
                    default:
                        return nil
                    }
                    continue
                }
                i += 1
            }
            return nil
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
        private static func numberEnd(_ bytes: [UInt8], from start: Int) -> Int? {
            var i = start
            func isDigit(_ index: Int) -> Bool {
                index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { return nil }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
            } else {
                while isDigit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard isDigit(i) else { return nil }
                while isDigit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard isDigit(i) else { return nil }
                while isDigit(i) { i += 1 }
            }
            // A number must end at a delimiter, or `12ab` would scan as `12`.
            if i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x0A, 0x0D, 0x09, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"):
                    break
                default:
                    return nil
                }
            }
            return i
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}
