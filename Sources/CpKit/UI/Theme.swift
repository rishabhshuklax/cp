import AppKit
import SwiftUI

/// Design tokens.
///
/// Two rules the rest of the UI is held to:
///
/// **Density.** Rows are 56pt, not 22pt. Eight rows you can read beat twenty you
/// have to squint at, and the picker is a thing you glance at, not a spreadsheet.
///
/// **Glass on the container, never behind the list.** `.glassEffect` and friends
/// look superb on chrome and are a legibility disaster behind dense text, because
/// the blurred desktop underneath moves while you read. The panel background and
/// the search field get the material; rows sit on an opaque surface.
public enum Theme {

    // MARK: - Metrics

    public enum Metric {
        public static let rowHeight: CGFloat = 56
        public static let rowCornerRadius: CGFloat = 10
        public static let rowInsetHorizontal: CGFloat = 10
        public static let accentBarWidth: CGFloat = 3
        public static let appIconSize: CGFloat = 15
        public static let thumbnailSize: CGFloat = 40

        /// Wide enough for a list *and* a live preview side by side. The narrow,
        /// menu-bar-anchored popover is what forces every other clipboard manager
        /// into hover-delayed previews; going wide is what buys the preview pane.
        public static let panelWidth: CGFloat = 720
        public static let panelHeight: CGFloat = 460
        public static let listFraction: CGFloat = 0.42

        public static let searchBarHeight: CGFloat = 44
        public static let footerHeight: CGFloat = 28
        public static let gridItemSize: CGFloat = 104
    }

    // MARK: - Motion

    public enum Motion {
        /// Everything in this app is hit dozens of times a day. Nothing is allowed
        /// to feel like it is playing an animation at you.
        public static let selection = Animation.easeOut(duration: 0.12)
        public static let listUpdate = Animation.spring(response: 0.28, dampingFraction: 0.86)
        public static let chrome = Animation.easeInOut(duration: 0.18)
    }

    // MARK: - Colour

    /// A colour that resolves per appearance. The macOS-native way to do this —
    /// far less error-prone than branching on `@Environment(\.colorScheme)` in
    /// every view that needs a tint.
    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    /// The accent bar colour, per kind. Hues are spaced far enough apart to be
    /// distinguishable in peripheral vision, which is the whole job: you should be
    /// able to find "the code one" without reading a single row.
    public static func accent(for kind: ClippingKind) -> Color {
        switch kind {
        case .url:      return dynamic(light: rgb(0, 113, 227),   dark: rgb(92, 165, 255))
        case .color:    return dynamic(light: rgb(214, 51, 132),  dark: rgb(247, 118, 182))
        case .image:    return dynamic(light: rgb(142, 68, 214),  dark: rgb(186, 133, 255))
        case .file:     return dynamic(light: rgb(201, 120, 12),  dark: rgb(240, 173, 78))
        case .code:     return dynamic(light: rgb(24, 146, 94),   dark: rgb(92, 209, 148))
        case .json:     return dynamic(light: rgb(13, 141, 160),  dark: rgb(84, 202, 218))
        case .richText: return dynamic(light: rgb(88, 86, 214),   dark: rgb(141, 139, 244))
        case .text:     return dynamic(light: rgb(124, 130, 140), dark: rgb(152, 158, 168))
        }
    }

    public static let rowSurface = dynamic(
        light: NSColor.white.withAlphaComponent(0.6),
        dark: NSColor.white.withAlphaComponent(0.04)
    )

    public static let selectedSurface = dynamic(
        light: rgb(0, 113, 227).withAlphaComponent(0.10),
        dark: rgb(92, 165, 255).withAlphaComponent(0.16)
    )

    public static let selectedBorder = dynamic(
        light: rgb(0, 113, 227).withAlphaComponent(0.45),
        dark: rgb(92, 165, 255).withAlphaComponent(0.55)
    )

    public static let separator = dynamic(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.08)
    )

    public static let highlight = dynamic(
        light: rgb(255, 214, 10).withAlphaComponent(0.45),
        dark: rgb(255, 214, 10).withAlphaComponent(0.30)
    )

    // MARK: - Typography

    public enum Font {
        public static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        public static let rowBody = SwiftUI.Font.system(size: 12)
        public static let rowBodyMono = SwiftUI.Font.system(size: 11.5, design: .monospaced)
        public static let metadata = SwiftUI.Font.system(size: 10.5)
        public static let sectionHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
        public static let badge = SwiftUI.Font.system(size: 9.5, weight: .semibold, design: .rounded)
        public static let search = SwiftUI.Font.system(size: 15)
        public static let previewBody = SwiftUI.Font.system(size: 12.5)
        public static let previewMono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
}

/// Parses a colour clipping's payload back into something renderable, so a hex
/// string can be shown as the swatch it actually is.
public enum ColorParser {
    public static func color(from text: String) -> Color? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("#") {
            var digits = Array(trimmed.dropFirst())
            // Expand shorthand: #abc -> #aabbcc, #abcd -> #aabbccdd.
            if digits.count == 3 || digits.count == 4 {
                digits = digits.flatMap { [$0, $0] }
            }
            guard digits.count == 6 || digits.count == 8,
                  let value = UInt64(String(digits), radix: 16) else { return nil }

            let hasAlpha = digits.count == 8
            let red, green, blue, alpha: Double
            if hasAlpha {
                red   = Double((value >> 24) & 0xFF) / 255
                green = Double((value >> 16) & 0xFF) / 255
                blue  = Double((value >> 8) & 0xFF) / 255
                alpha = Double(value & 0xFF) / 255
            } else {
                red   = Double((value >> 16) & 0xFF) / 255
                green = Double((value >> 8) & 0xFF) / 255
                blue  = Double(value & 0xFF) / 255
                alpha = 1
            }
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        }

        let lower = trimmed.lowercased()
        guard lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        let parts = inner
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard parts.count >= 3 else { return nil }

        return Color(
            .sRGB,
            red: parts[0] / 255,
            green: parts[1] / 255,
            blue: parts[2] / 255,
            opacity: parts.count > 3 ? min(parts[3], 1) : 1
        )
    }
}
