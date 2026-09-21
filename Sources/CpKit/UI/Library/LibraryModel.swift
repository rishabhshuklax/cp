import AppKit
import Observation

/// What the Library asks the app to do. Small on purpose: the Library never
/// pastes, because you are not holding a target app in your head when you are
/// browsing.
@MainActor
public protocol LibraryHost: AnyObject {
    func copyToClipboard(_ clipping: Clipping)
    func togglePin(_ clipping: Clipping)
    func delete(_ clipping: Clipping)
    func delete(_ ids: [UUID])
    func setPinned(_ ids: [UUID], pinned: Bool)
    func addToStack(_ ids: [UUID])
}

/// The Library's own state.
///
/// Deliberately not shared with the picker. One model driving both is how the
/// old build ended up with a browser that showed whatever the picker had last
/// searched for, and a picker that inherited a sidebar filter nobody set.
@Observable
@MainActor
public final class LibraryModel {

    public enum Filter: Hashable, Sendable {
        case all
        case pinned
        case kind(ClippingKind)
        case app(bundleID: String, name: String)

        public var title: String {
            switch self {
            case .all: return "All clips"
            case .pinned: return "Pinned"
            case .kind(let kind): return ClipFilter.kind(kind).label
            case .app(_, let name): return name
            }
        }
    }

    public struct Group: Identifiable {
        public let day: RelativeTime.Day
        public let clippings: [Clipping]
        public var id: String { day.rawValue }
    }

    public var filter: Filter = .all {
        didSet { if filter != oldValue { selection = [] } }
    }
    public var query: String = ""
    /// Ordered, so the last one clicked is the one the inspector shows.
    public private(set) var selection: [UUID] = []

    public let store: ClippingStore
    public let settings: Settings
    public let links: LinkPreviews
    @ObservationIgnored public weak var host: LibraryHost?

    public init(store: ClippingStore, settings: Settings, links: LinkPreviews) {
        self.store = store
        self.settings = settings
        self.links = links
    }

    // MARK: - Contents

    /// Reads `store.clippings` on every call, so the window follows new copies
    /// the moment they land — the old browser never did.
    public var clippings: [Clipping] {
        let filters: [ClipFilter]
        var scope = ClipScope.recent
        switch filter {
        case .all: filters = []
        case .pinned:
            filters = []
            scope = .pinned
        // Text is prose in any wrapping: rich text and JSON live under it too.
        case .kind(.text): filters = [.kind(.text), .kind(.json)]
        case .kind(let kind): filters = [.kind(kind)]
        case .app(let bundleID, let name): filters = [.app(bundleID: bundleID, name: name)]
        }
        return store.search(ClipQuery(text: query, filters: filters, scope: scope))
            .map(\.clipping)
            // A password is held for a minute in memory; a browsing window is
            // the last place it should turn up.
            .filter { !$0.isConcealed }
    }

    public var groups: [Group] {
        let now = Date()
        var order: [RelativeTime.Day] = []
        var byDay: [RelativeTime.Day: [Clipping]] = [:]
        for clipping in clippings {
            let day = RelativeTime.day(clipping.lastCopiedAt, now: now)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(clipping)
        }
        return order.map { Group(day: $0, clippings: byDay[$0] ?? []) }
    }

    public var isEmpty: Bool { clippings.isEmpty }

    // MARK: - Sidebar

    public struct SidebarItem: Identifiable {
        public let filter: Filter
        public let title: String
        public let symbolName: String
        public let bundleID: String?
        public let count: Int
        public var id: String { "\(filter)" }
    }

    public var sidebarTop: [SidebarItem] {
        let all = store.clippings.filter { !$0.isConcealed }
        return [
            SidebarItem(filter: .all, title: "All clips", symbolName: "list.clipboard",
                        bundleID: nil, count: all.count),
            SidebarItem(filter: .pinned, title: "Pinned", symbolName: "pin.fill",
                        bundleID: nil, count: all.filter(\.isPinned).count),
        ]
    }

    public static let sidebarKinds: [ClippingKind] = [.url, .image, .code, .color, .file, .text]

    public var sidebarKindItems: [SidebarItem] {
        let all = store.clippings.filter { !$0.isConcealed }
        return Self.sidebarKinds.map { kind in
            let count = all.filter {
                kind == .text ? ($0.kind == .text || $0.kind == .richText || $0.kind == .json) : $0.kind == kind
            }.count
            return SidebarItem(filter: .kind(kind), title: ClipFilter.kind(kind).label,
                               symbolName: kind.symbolName, bundleID: nil, count: count)
        }
    }

    public var sidebarApps: [SidebarItem] {
        store.sourceApps.prefix(8).map { app in
            SidebarItem(filter: .app(bundleID: app.bundleID, name: app.name), title: app.name,
                        symbolName: "app", bundleID: app.bundleID, count: app.count)
        }
    }

    // MARK: - Selection

    /// A plain click selects one; ⌘ or ⇧ adds and removes.
    public func select(_ id: UUID, extending: Bool) {
        if extending {
            if let index = selection.firstIndex(of: id) {
                selection.remove(at: index)
            } else {
                selection.append(id)
            }
        } else {
            selection = [id]
        }
    }

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    public func clearSelection() { selection = [] }

    /// The inspector follows the last thing you clicked; with nothing clicked
    /// it shows the newest clipping, so the pane is never empty for no reason.
    public var focus: Clipping? {
        if let id = selection.last, let clipping = store.clipping(withID: id) { return clipping }
        return clippings.first
    }

    public var selectedClippings: [Clipping] {
        selection.compactMap { store.clipping(withID: $0) }
    }

    /// How long this clipping has before history forgets it.
    public func keptUntil(_ clipping: Clipping) -> String {
        clipping.isPinned ? "You unpin it" : "History fills up"
    }

    public func height(for clipping: Clipping) -> CGFloat {
        switch clipping.kind {
        case .color: return 96
        case .image: return 150
        case .url: return 132
        default: return 132
        }
    }

    /// Colours and pictures say where they came from by being themselves.
    public func showsFooter(_ clipping: Clipping) -> Bool {
        clipping.kind != .color && clipping.kind != .image
    }
}
