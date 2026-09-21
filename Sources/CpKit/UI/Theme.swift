import AppKit
import SwiftUI

/// The design tokens.
///
/// Two rules the rest of the UI is held to:
///
/// **Glass on the chrome, never behind a row.** The search capsule, the results
/// panel, the HUD, the chip and the toast are glass; everything inside them sits
/// on a light wash. Putting the material behind dense text puts a moving desktop
/// under what you are reading, which is the trap most "modernise it with glass"
/// redesigns fall into.
///
/// **One shape per surface.** Capsules for controls, 12pt rounded rects for rows,
/// 28pt for the panel. A control that wears a different shape reads as a mistake
/// before anyone reads its label.
public enum Theme {

    // MARK: - Metrics

    public enum Metric {
        /// The picker: a 56pt search capsule, a 10pt gap, a 508pt results panel.
        public static let pickerWidth: CGFloat = 720
        public static let searchHeight: CGFloat = 56
        public static let searchGap: CGFloat = 10
        public static let resultsHeight: CGFloat = 508
        public static let resultsCorner: CGFloat = 28
        public static var pickerHeight: CGFloat { searchHeight + searchGap + resultsHeight }
        /// Down from the top of the screen's visible frame.
        public static let pickerTopFraction: CGFloat = 0.18

        public static let heroHeight: CGFloat = 192
        public static let heroFooterHeight: CGFloat = 30
        public static let rowHeight: CGFloat = 38
        public static let rowCorner: CGFloat = 12
        public static let sectionHeight: CGFloat = 30
        public static let listTopPadding: CGFloat = 4
        public static let listBottomPadding: CGFloat = 10
        public static let listHorizontalPadding: CGFloat = 10
        public static let thumbSize: CGFloat = 22
        public static let capsuleHeight: CGFloat = 30

        public static let actionsWidth: CGFloat = 318
        public static let actionsTop: CGFloat = 176
        public static let actionRowHeight: CGFloat = 32

        public static let trayHeight: CGFloat = 46

        /// The quick-switch HUD.
        public static let cardSize: CGFloat = 148
        public static let cardCorner: CGFloat = 20
        public static let cardGap: CGFloat = 12
        public static let hudCorner: CGFloat = 36
        public static let hudPadding: CGFloat = 16
        public static let hudCards = 8

        /// The Library.
        public static let libraryWidth: CGFloat = 1_200
        public static let libraryHeight: CGFloat = 780
        public static let libraryMinWidth: CGFloat = 900
        public static let libraryMinHeight: CGFloat = 560
        public static let sidebarWidth: CGFloat = 236
        public static let inspectorWidth: CGFloat = 300
        public static let tileMinWidth: CGFloat = 190

        public static let settingsWidth: CGFloat = 520
        public static let settingsHeight: CGFloat = 560
    }

    // MARK: - Colour

    /// A colour that resolves per appearance — the macOS-native way, and far less
    /// error-prone than branching on `@Environment(\.colorScheme)` in every view.
    public static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    private static func hex(_ value: UInt32, _ alpha: Double = 1) -> NSColor {
        rgba(Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF), alpha)
    }

    /// Ink, four steps. Anything dimmer than `ink4` is invisible on glass.
    public static let ink = dynamic(light: rgba(0, 0, 0, 0.88), dark: rgba(255, 255, 255, 0.93))
    public static let ink2 = dynamic(light: rgba(60, 60, 67, 0.70), dark: rgba(235, 235, 245, 0.64))
    public static let ink3 = dynamic(light: rgba(60, 60, 67, 0.46), dark: rgba(235, 235, 245, 0.42))
    public static let ink4 = dynamic(light: rgba(60, 60, 67, 0.16), dark: rgba(235, 235, 245, 0.16))

    /// The wash content sits on, so glass never has to carry text itself.
    public static let wash = dynamic(light: rgba(0, 0, 0, 0.035), dark: rgba(255, 255, 255, 0.055))
    public static let hover = dynamic(light: rgba(0, 0, 0, 0.05), dark: rgba(255, 255, 255, 0.07))
    public static let line = dynamic(light: rgba(0, 0, 0, 0.085), dark: rgba(255, 255, 255, 0.085))
    /// The inner hairline that makes a glass edge read as an edge.
    public static let edge = dynamic(light: rgba(255, 255, 255, 0.72), dark: rgba(255, 255, 255, 0.13))

    public static let selection = dynamic(light: rgba(0, 122, 255, 0.16), dark: rgba(10, 132, 255, 0.34))
    public static let selectionEdge = dynamic(light: rgba(0, 122, 255, 0.40), dark: rgba(116, 172, 255, 0.50))
    public static let accent = dynamic(light: hex(0x007AFF), dark: hex(0x0A84FF))
    public static let onAccent = Color.white

    /// Search highlight, and the box drawn over text found inside an image.
    public static let mark = dynamic(light: rgba(255, 204, 0, 0.45), dark: rgba(255, 214, 10, 0.36))
    public static let markEdge = dynamic(light: hex(0xFFCC00), dark: hex(0xFFD60A))
    /// The tracking parameters "Paste without tracking" would remove.
    public static let tracking = dynamic(light: hex(0xC25E00), dark: hex(0xFF9F0A))
    public static let link = dynamic(light: hex(0x0A66D8), dark: hex(0x6AABFF))
    public static let danger = dynamic(light: hex(0xD70015), dark: hex(0xFF6961))
    public static let positive = dynamic(light: hex(0x1F9D45), dark: hex(0x30D158))
    public static let paused = dynamic(light: hex(0xC25E00), dark: hex(0xFF9F0A))

    /// Cards and tiles — the one opaque surface, because a card is content.
    public static let card = dynamic(light: hex(0xFFFFFF), dark: hex(0x2A2A2F))
    public static let cardInk = dynamic(light: rgba(0, 0, 0, 0.86), dark: rgba(255, 255, 255, 0.90))
    /// The ring around the selected card in the HUD.
    public static let ring = dynamic(light: rgba(0, 0, 0, 0.80), dark: rgba(255, 255, 255, 0.95))
    /// Denser glass, for surfaces that float over other glass (menus, trays).
    public static let scrim = dynamic(light: rgba(250, 250, 252, 0.92), dark: rgba(30, 30, 35, 0.86))
    public static let windowBackground = dynamic(light: hex(0xFBFBFD), dark: hex(0x1D1D20))

    /// Syntax colours. Code is the one content type where
    /// colour carries meaning rather than decoration.
    public enum Code {
        public static let keyword = dynamic(light: hex(0xAD3DA4), dark: hex(0xFF7AB2))
        public static let type = dynamic(light: hex(0x703DAA), dark: hex(0xDABAFF))
        public static let string = dynamic(light: hex(0xC41A16), dark: hex(0xFF8170))
        public static let number = dynamic(light: hex(0x1C00CF), dark: hex(0xD9C97C))
        public static let function = dynamic(light: hex(0x3E8087), dark: hex(0x67D8EF))
        public static let comment = dynamic(light: hex(0x707F8C), dark: hex(0x7F8C98))
        public static let key = dynamic(light: hex(0x0F68A0), dark: hex(0x9ECBFF))
    }

    // MARK: - Typography

    public enum Font {
        public static let search = SwiftUI.Font.system(size: 21)
        public static let heroText = SwiftUI.Font.system(size: 18)
        public static let heroTextLook = SwiftUI.Font.system(size: 19)
        public static let heroTitle = SwiftUI.Font.system(size: 21, weight: .semibold)
        public static let heroTitleLook = SwiftUI.Font.system(size: 26, weight: .semibold)
        public static let heroName = SwiftUI.Font.system(size: 19, weight: .semibold)
        public static let heroFileName = SwiftUI.Font.system(size: 20, weight: .semibold)
        public static let heroMono = SwiftUI.Font.system(size: 13, design: .monospaced)
        public static let heroMonoLook = SwiftUI.Font.system(size: 14.5, design: .monospaced)
        public static let heroURL = SwiftUI.Font.system(size: 12.5, design: .monospaced)
        public static let heroDots = SwiftUI.Font.system(size: 26, weight: .semibold, design: .monospaced)

        public static let row = SwiftUI.Font.system(size: 14)
        public static let rowMono = SwiftUI.Font.system(size: 12.5, design: .monospaced)
        public static let rowTime = SwiftUI.Font.system(size: 12)
        public static let section = SwiftUI.Font.system(size: 11.5, weight: .semibold)
        public static let keycap = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let capsule = SwiftUI.Font.system(size: 13, weight: .medium)
        public static let capsuleKey = SwiftUI.Font.system(size: 12)
        public static let meta = SwiftUI.Font.system(size: 12.5)
        public static let label = SwiftUI.Font.system(size: 11.5, weight: .semibold)
        public static let action = SwiftUI.Font.system(size: 13.5)
        public static let caption = SwiftUI.Font.system(size: 13)

        public static let cardText = SwiftUI.Font.system(size: 12.5)
        public static let cardMono = SwiftUI.Font.system(size: 10.5, design: .monospaced)
        public static let cardTitle = SwiftUI.Font.system(size: 13.5, weight: .semibold)

        public static let windowTitle = SwiftUI.Font.system(size: 17, weight: .bold)
        public static let settingsRow = SwiftUI.Font.system(size: 13.5)
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
        guard lower.hasPrefix("rgb") || lower.hasPrefix("hsl"),
              let open = lower.firstIndex(of: "("), lower.hasSuffix(")") else { return nil }
        let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
        let parts = inner
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard parts.count >= 3 else { return nil }

        if lower.hasPrefix("hsl") {
            let (red, green, blue) = ColorFormats.hslToRGB(
                hue: parts[0], saturation: parts[1] / 100, lightness: parts[2] / 100
            )
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: parts.count > 3 ? min(parts[3], 1) : 1)
        }
        return Color(
            .sRGB,
            red: parts[0] / 255,
            green: parts[1] / 255,
            blue: parts[2] / 255,
            opacity: parts.count > 3 ? min(parts[3], 1) : 1
        )
    }

    /// Ink that stays legible on a swatch: a plain luminance rule.
    public static func ink(on payload: String) -> Color {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nsColor = color(from: trimmed).map(NSColor.init)?.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * nsColor.redComponent + 0.587 * nsColor.greenComponent + 0.114 * nsColor.blueComponent
        return luminance > 0.63 ? Color.black.opacity(0.78) : Color.white.opacity(0.95)
    }
}
