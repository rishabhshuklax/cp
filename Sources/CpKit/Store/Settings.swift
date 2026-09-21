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
    }

    @ObservationIgnored private let defaults: UserDefaults

    private var storedHistoryLimit: Int
    private var storedIgnoredBundleIDs: Set<String>
    private var storedResolveLinkTitles: Bool
    private var storedPasteAutomatically: Bool
    private var storedAdaptiveImageGrid: Bool

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
    }
}
