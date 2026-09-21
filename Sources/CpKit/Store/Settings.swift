import Carbon.HIToolbox
import Foundation
import Observation

/// User-facing preferences, persisted in `UserDefaults`.
///
/// Each setting is a computed property over a tracked stored one, rather than a
/// stored property with a `didSet`. The `@Observable` macro rewrites stored
/// properties into computed ones, so a property observer on a tracked property is
/// at best fragile and at worst silently dropped — writing the accessors out means
/// the persistence side-effect is guaranteed to run on every write.
@Observable
@MainActor
public final class Settings {

    private enum Key {
        static let historyLimit = "history.limit"
        static let ignoredBundleIDs = "privacy.ignoredBundleIDs"
        static let resolveLinkTitles = "links.resolveTitles"
        static let pasteAutomatically = "paste.automatic"
        static let adaptiveImageGrid = "ui.adaptiveImageGrid"
        static let recognizeText = "images.recognizeText"
        static let secretLifetime = "privacy.secretLifetime"
        static let holdToSwitch = "picker.holdToSwitch"
        static let hotKey = "picker.hotKey"
        static let pasteRichAsPlain = "paste.richAsPlain"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private var storedHistoryLimit: Int
    private var storedIgnoredBundleIDs: Set<String>
    private var storedResolveLinkTitles: Bool
    private var storedPasteAutomatically: Bool
    private var storedAdaptiveImageGrid: Bool
    private var storedRecognizeText: Bool
    private var storedSecretLifetime: TimeInterval
    private var storedHoldToSwitch: Bool
    private var storedHotKey: HotKeyCombo
    private var storedPasteRichAsPlain: Bool

    public var historyLimit: Int {
        get { storedHistoryLimit }
        set {
            storedHistoryLimit = newValue
            defaults.set(newValue, forKey: Key.historyLimit)
        }
    }

    /// Apps whose copies are never captured. Password managers belong here, and
    /// `PrivacyFilter` seeds the well-known ones on first launch so the safe
    /// default does not depend on anybody reading the settings screen.
    public var ignoredBundleIDs: Set<String> {
        get { storedIgnoredBundleIDs }
        set {
            storedIgnoredBundleIDs = newValue
            defaults.set(Array(newValue), forKey: Key.ignoredBundleIDs)
        }
    }

    /// Opt-in, and deliberately so: resolving a page title means an outbound
    /// request for something you merely copied. Off by default, and even when on,
    /// resolution happens lazily on selection rather than eagerly at capture, so
    /// copying fifty links costs zero requests until you go looking for one.
    public var resolveLinkTitles: Bool {
        get { storedResolveLinkTitles }
        set {
            storedResolveLinkTitles = newValue
            defaults.set(newValue, forKey: Key.resolveLinkTitles)
        }
    }

    /// Synthesise ⌘V into the previously frontmost app after choosing. Requires
    /// Accessibility permission; falls back to copy-only when not granted.
    public var pasteAutomatically: Bool {
        get { storedPasteAutomatically }
        set {
            storedPasteAutomatically = newValue
            defaults.set(newValue, forKey: Key.pasteAutomatically)
        }
    }

    /// Flip the list to a thumbnail grid when the filtered set is mostly images.
    /// A list row gives an image 40pt and wastes the one thing images are good at.
    public var adaptiveImageGrid: Bool {
        get { storedAdaptiveImageGrid }
        set {
            storedAdaptiveImageGrid = newValue
            defaults.set(newValue, forKey: Key.adaptiveImageGrid)
        }
    }

    /// Read the text in copied images so search can find a screenshot by what it
    /// says. On-device (Vision), off the main thread, after the copy lands.
    public var recognizeText: Bool {
        get { storedRecognizeText }
        set {
            storedRecognizeText = newValue
            defaults.set(newValue, forKey: Key.recognizeText)
        }
    }

    /// How long a concealed clipping, and its text, is kept in memory. Zero means
    /// the text is never kept and nothing is shown.
    public var secretLifetime: TimeInterval {
        get { storedSecretLifetime }
        set {
            storedSecretLifetime = max(0, newValue)
            defaults.set(storedSecretLifetime, forKey: Key.secretLifetime)
        }
    }

    /// Hold ⇧⌘ and tap V to step through recent clippings, release to paste.
    public var holdToSwitch: Bool {
        get { storedHoldToSwitch }
        set {
            storedHoldToSwitch = newValue
            defaults.set(newValue, forKey: Key.holdToSwitch)
        }
    }

    /// The shortcut that opens the picker.
    public var hotKey: HotKeyCombo {
        get { storedHotKey }
        set {
            storedHotKey = newValue
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.hotKey)
        }
    }

    /// Paste rich text without its formatting unless asked otherwise.
    public var pasteRichAsPlain: Bool {
        get { storedPasteRichAsPlain }
        set {
            storedPasteRichAsPlain = newValue
            defaults.set(newValue, forKey: Key.pasteRichAsPlain)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedLimit = defaults.integer(forKey: Key.historyLimit)
        self.storedHistoryLimit = storedLimit > 0 ? storedLimit : 2_000

        if let stored = defaults.array(forKey: Key.ignoredBundleIDs) as? [String] {
            self.storedIgnoredBundleIDs = Set(stored)
        } else {
            self.storedIgnoredBundleIDs = PrivacyFilter.defaultIgnoredBundleIDs
        }

        self.storedResolveLinkTitles = defaults.bool(forKey: Key.resolveLinkTitles)
        // `object(forKey:)` rather than `bool(forKey:)` so an unset default reads as
        // "not yet chosen" instead of false.
        self.storedPasteAutomatically = defaults.object(forKey: Key.pasteAutomatically) as? Bool ?? true
        self.storedAdaptiveImageGrid = defaults.object(forKey: Key.adaptiveImageGrid) as? Bool ?? true
        self.storedRecognizeText = defaults.object(forKey: Key.recognizeText) as? Bool ?? true
        self.storedSecretLifetime = max(0, defaults.object(forKey: Key.secretLifetime) as? Double ?? 60)
        self.storedHoldToSwitch = defaults.object(forKey: Key.holdToSwitch) as? Bool ?? true
        self.storedHotKey = defaults.data(forKey: Key.hotKey)
            .flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .shiftCommandV
        self.storedPasteRichAsPlain = defaults.object(forKey: Key.pasteRichAsPlain) as? Bool ?? false
    }
}

/// A global shortcut in Carbon's terms: a virtual key code and Carbon modifier
/// flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), which is what
/// `RegisterEventHotKey` takes.
public struct HotKeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⇧⌘V — the shortcut every clipboard manager on the platform has trained
    /// people to reach for.
    public static let shiftCommandV = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// "⇧⌘V", modifiers in the order menus draw them: ⌃⌥⇧⌘.
    public var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// Names for the keys on an ANSI layout. Letters are named by position,
    /// which is what the virtual key code means.
    private static let keyNames: [UInt32: String] = {
        let pairs: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_Escape, "⎋"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt32($0.0), $0.1) })
    }()
}
