import Foundation

public enum ColorNotation: String, Sendable, CaseIterable {
    case hex
    case rgb
    case hsl
    case swiftUI
}

/// A colour clipping in each notation someone might paste it as.
///
/// The notation it was copied in comes back exactly as copied, so the default
/// paste never changes what you copied; the others are converted.
/// `ColorParser` stays the source of the SwiftUI `Color` for swatches.
public enum ColorFormats {

    public static func strings(for payload: String) -> [ColorNotation: String] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let color = parse(trimmed) else { return [:] }
        var result: [ColorNotation: String] = [
            .hex: hex(color),
            .rgb: rgb(color),
            .hsl: hsl(color),
            .swiftUI: swiftUI(color),
        ]
        result[color.notation] = trimmed
        return result
    }

    /// The notation a colour was written in, if it parses.
    public static func notation(of payload: String) -> ColorNotation? {
        parse(payload.trimmingCharacters(in: .whitespacesAndNewlines))?.notation
    }

    // MARK: - Parsing

    struct RGBA: Equatable {
        var red: Double    // 0…1
        var green: Double
        var blue: Double
        var alpha: Double
        var notation: ColorNotation
    }

    static func parse(_ text: String) -> RGBA? {
        let lower = text.lowercased()
        if lower.hasPrefix("#") { return parseHex(String(lower.dropFirst())) }

        for function in ["rgba", "rgb", "hsla", "hsl"] where lower.hasPrefix(function + "(") && lower.hasSuffix(")") {
            let inner = lower.dropFirst(function.count + 1).dropLast()
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let alpha = parts.count == 4 ? component(parts[3], percentScale: 1, plainScale: 1) : 1
            guard let alpha else { return nil }
            if function.hasPrefix("rgb") {
                guard let red = component(parts[0], percentScale: 1, plainScale: 255),
                      let green = component(parts[1], percentScale: 1, plainScale: 255),
                      let blue = component(parts[2], percentScale: 1, plainScale: 255) else { return nil }
                return RGBA(red: red, green: green, blue: blue, alpha: alpha, notation: .rgb)
            }
            guard let hue = Double(parts[0]),
                  let saturation = component(parts[1], percentScale: 1, plainScale: 100),
                  let lightness = component(parts[2], percentScale: 1, plainScale: 100) else { return nil }
            let (red, green, blue) = hslToRGB(hue: hue, saturation: saturation, lightness: lightness)
            return RGBA(red: red, green: green, blue: blue, alpha: alpha, notation: .hsl)
        }
        return nil
    }

    private static func parseHex(_ digits: String) -> RGBA? {
        var digits = Array(digits)
        if digits.count == 3 || digits.count == 4 { digits = digits.flatMap { [$0, $0] } }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(String(digits), radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shifted = hasAlpha ? value >> 8 : value
        return RGBA(
            red: Double((shifted >> 16) & 0xFF) / 255,
            green: Double((shifted >> 8) & 0xFF) / 255,
            blue: Double(shifted & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1,
            notation: .hex
        )
    }

    /// `50%` → 0.5; a bare number is divided by `plainScale`.
    private static func component(_ text: String, percentScale: Double, plainScale: Double) -> Double? {
        if text.hasSuffix("%") {
            guard let value = Double(text.dropLast()) else { return nil }
            return min(max(value / 100 * percentScale, 0), 1)
        }
        guard let value = Double(text) else { return nil }
        return min(max(value / plainScale, 0), 1)
    }

    // MARK: - Writing

    private static func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }

    private static func hex(_ color: RGBA) -> String {
        var result = String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
        if color.alpha < 1 { result += String(format: "%02X", byte(color.alpha)) }
        return result
    }

    private static func rgb(_ color: RGBA) -> String {
        let channels = "\(byte(color.red)), \(byte(color.green)), \(byte(color.blue))"
        return color.alpha < 1 ? "rgba(\(channels), \(trim(color.alpha)))" : "rgb(\(channels))"
    }

    private static func hsl(_ color: RGBA) -> String {
        let (hue, saturation, lightness) = rgbToHSL(red: color.red, green: color.green, blue: color.blue)
        let channels = "\(Int(hue.rounded()) % 360), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return color.alpha < 1 ? "hsla(\(channels), \(trim(color.alpha)))" : "hsl(\(channels))"
    }

    private static func swiftUI(_ color: RGBA) -> String {
        var result = "Color(red: \(String(format: "%.2f", color.red)), green: \(String(format: "%.2f", color.green)), blue: \(String(format: "%.2f", color.blue))"
        if color.alpha < 1 { result += ", opacity: \(String(format: "%.2f", color.alpha))" }
        return result + ")"
    }

    /// `0.5`, not `0.500000`.
    private static func trim(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Double, Double, Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case ..<1: (r, g, b) = (chroma, second, 0)
        case ..<2: (r, g, b) = (second, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, second)
        case ..<4: (r, g, b) = (0, second, chroma)
        case ..<5: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        let match = lightness - chroma / 2
        return (r + match, g + match, b + match)
    }

    static func rgbToHSL(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let lightness = (high + low) / 2
        let delta = high - low
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }
}
