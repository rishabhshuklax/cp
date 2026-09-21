import Foundation

/// Paste-time transformations, offered per kind.
///
/// The point of typing clippings is that the action menu can be *short*. A URL
/// offers to drop its tracking parameters; JSON offers to minify; a colour offers
/// the other three notations. Nobody has to scroll past twenty irrelevant verbs to
/// reach the one that applies, which is what a flat list of text operations
/// degenerates into.
public struct Transform: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let apply: @Sendable (String) -> String

    public init(id: String, title: String, symbolName: String, apply: @escaping @Sendable (String) -> String) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.apply = apply
    }

    // MARK: - Catalogue

    public static func available(for kind: ClippingKind) -> [Transform] {
        var transforms: [Transform] = []

        switch kind {
        case .url:
            transforms.append(stripTrackingParameters)
            transforms.append(extractDomain)
            transforms.append(urlDecode)
        case .json:
            transforms.append(prettyJSON)
            transforms.append(minifyJSON)
        case .code:
            transforms.append(stripIndentation)
            transforms.append(joinLines)
        case .color:
            transforms.append(uppercase)
        case .richText:
            transforms.append(trim)
        case .text:
            transforms.append(trim)
            transforms.append(joinLines)
            transforms.append(lowercase)
            transforms.append(uppercase)
        case .file:
            transforms.append(basename)
        case .image:
            break
        }

        // Always last, always available: universal string hygiene.
        if kind != .image, !transforms.contains(where: { $0.id == trim.id }) {
            transforms.append(trim)
        }
        return transforms
    }

    // MARK: - Implementations

    public static let trim = Transform(id: "trim", title: "Trim whitespace", symbolName: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let lowercase = Transform(id: "lowercase", title: "Lowercase", symbolName: "textformat.size.smaller") {
        $0.lowercased()
    }

    public static let uppercase = Transform(id: "uppercase", title: "Uppercase", symbolName: "textformat.size.larger") {
        $0.uppercased()
    }

    public static let joinLines = Transform(id: "joinLines", title: "Join lines", symbolName: "arrow.down.right.and.arrow.up.left") { input in
        input.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Removes the common leading indentation, so a snippet lifted out of a deeply
    /// nested function pastes flush instead of drifting right.
    public static let stripIndentation = Transform(id: "dedent", title: "Strip indentation", symbolName: "decrease.indent") { input in
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        guard let common = indents.min(), common > 0 else { return input }
        return lines.map { String($0.dropFirst(min(common, $0.count))) }.joined(separator: "\n")
    }

    public static let basename = Transform(id: "basename", title: "Filenames only", symbolName: "doc.text") { input in
        input.split(separator: "\n")
            .map { ($0 as NSString).lastPathComponent }
            .joined(separator: "\n")
    }

    public static let extractDomain = Transform(id: "domain", title: "Domain only", symbolName: "globe") { input in
        URLComponents(string: input)?.host ?? input
    }

    public static let urlDecode = Transform(id: "urlDecode", title: "URL-decode", symbolName: "percent") { input in
        input.removingPercentEncoding ?? input
    }

    /// The analytics tail that gets appended to every link you copy off the web.
    static let trackingParameterPrefixes = ["utm_", "fbclid", "gclid", "mc_eid", "mc_cid", "igshid", "ref_src", "ref_url", "si", "_hsenc", "_hsmi", "vero_id", "yclid", "msclkid"]

    public static let stripTrackingParameters = Transform(id: "untrack", title: "Remove tracking", symbolName: "eye.slash") { input in
        guard var components = URLComponents(string: input) else { return input }
        guard let items = components.queryItems else { return input }

        let cleaned = items.filter { item in
            let name = item.name.lowercased()
            return !trackingParameterPrefixes.contains { name == $0 || name.hasPrefix($0) }
        }
        components.queryItems = cleaned.isEmpty ? nil : cleaned
        return components.string ?? input
    }

    public static let prettyJSON = Transform(id: "jsonPretty", title: "Pretty-print", symbolName: "text.alignleft") { input in
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: pretty, encoding: .utf8) else { return input }
        return text
    }

    public static let minifyJSON = Transform(id: "jsonMinify", title: "Minify", symbolName: "arrow.down.forward.and.arrow.up.backward") { input in
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let minified = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.withoutEscapingSlashes]
              ),
              let text = String(data: minified, encoding: .utf8) else { return input }
        return text
    }
}
