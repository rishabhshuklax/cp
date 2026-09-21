import AppKit
import Observation
import SwiftUI

/// State for one invocation of the picker.
///
/// Recomputes the ranked list on any input change. At the default 2,000-item cap
/// this is a linear pass with a fuzzy match per row, which lands comfortably inside
/// a frame — the cost that actually matters is rendering, which is why the list is
/// lazy and the previews are cached.
@Observable
@MainActor
public final class PickerModel {

    public private(set) var results: [ScoredClipping] = []
    public var selectedID: UUID?

    /// Computed over tracked storage rather than stored with a `didSet`: the
    /// `@Observable` macro rewrites stored properties into computed ones, so a
    /// property observer on a tracked property cannot be relied on to fire. Doing
    /// it by hand means re-ranking happens no matter which view drives the change.
    public var searchText: String {
        get { storedSearchText }
        set {
            guard newValue != storedSearchText else { return }
            storedSearchText = newValue
            refresh()
        }
    }

    public var committedFilters: [SearchQuery.Filter] {
        get { storedFilters }
        set {
            guard newValue != storedFilters else { return }
            storedFilters = newValue
            refresh()
        }
    }

    private var storedSearchText: String = ""
    private var storedFilters: [SearchQuery.Filter] = []

    /// Resolved link titles, keyed by clipping id. Populated lazily as rows are
    /// selected, never at capture time.
    public private(set) var resolvedTitles: [UUID: String] = [:]
    public private(set) var favicons: [UUID: NSImage] = [:]

    private let store: ClippingStore
    private let settings: Settings
    private let linkResolver: LinkResolver
    private var ranker = Ranker()
    private var resolveTask: Task<Void, Never>?

    public init(store: ClippingStore, settings: Settings, linkResolver: LinkResolver) {
        self.store = store
        self.settings = settings
        self.linkResolver = linkResolver
    }

    public var selected: Clipping? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }?.clipping
    }

    /// True when the filtered set is mostly images, which is when a list of rows is
    /// the wrong shape — a thumbnail grid shows twelve at a glance where the list
    /// shows five.
    public var shouldUseGrid: Bool {
        guard settings.adaptiveImageGrid, results.count >= 4 else { return false }
        let images = results.filter { $0.clipping.kind == .image }.count
        return Double(images) / Double(results.count) >= 0.7
    }

    // MARK: - Lifecycle

    /// Called each time the panel opens. Captures the app being pasted *into*, which
    /// is what drives the affinity nudge in the ranker.
    public func prepare(targetBundleID: String?) {
        ranker = Ranker(targetBundleID: targetBundleID, now: Date())
        // Reset through the backing storage so this is one re-rank, not three.
        storedSearchText = ""
        storedFilters = []
        refresh()
        selectedID = results.first?.id
    }

    public func refresh() {
        let query = SearchQuery(
            filters: committedFilters,
            text: searchText.trimmingCharacters(in: .whitespaces)
        )
        results = ranker.rank(store.clippings, query: query)

        // Keep the selection if it survived the filter; otherwise fall to the top.
        if let selectedID, results.contains(where: { $0.id == selectedID }) { return }
        selectedID = results.first?.id
    }

    // MARK: - Keyboard navigation

    public func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        guard let selectedID, let current = results.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = results.first?.id
            return
        }
        let next = min(max(current + offset, 0), results.count - 1)
        self.selectedID = results[next].id
        resolveLinkIfNeeded()
    }

    public func selectFirst() {
        selectedID = results.first?.id
        resolveLinkIfNeeded()
    }

    public func selectLast() {
        selectedID = results.last?.id
        resolveLinkIfNeeded()
    }

    /// `⌥1` … `⌥9` jump straight to a row.
    public func clipping(atShortcut index: Int) -> Clipping? {
        guard index >= 1, index <= results.count, index <= 9 else { return nil }
        return results[index - 1].clipping
    }

    // MARK: - Link resolution

    /// Fires only for the selected row, only when the setting is on, and only once
    /// per clipping. See `LinkResolver` for why this is lazy rather than eager.
    public func resolveLinkIfNeeded() {
        guard settings.resolveLinkTitles else { return }
        guard let clipping = selected, clipping.kind == .url else { return }
        guard resolvedTitles[clipping.id] == nil else { return }

        let id = clipping.id
        let payload = clipping.payload

        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            guard let resolved = await self.linkResolver.resolve(urlString: payload) else { return }
            guard !Task.isCancelled else { return }

            if let title = resolved.title {
                self.resolvedTitles[id] = title
            }
            if let data = resolved.faviconData, let image = NSImage(data: data) {
                image.size = NSSize(width: 16, height: 16)
                self.favicons[id] = image
            }
        }
    }

    public func title(for clipping: Clipping) -> String? {
        resolvedTitles[clipping.id]
    }

    public func favicon(for clipping: Clipping) -> NSImage? {
        favicons[clipping.id]
    }

    // MARK: - Grouping

    /// Groups the ranked results into time buckets for the section headers.
    /// Only applied to an unfiltered list: once you are searching, relevance order
    /// is the point and chopping it into date sections just hides the best match.
    public func sections() -> [(bucket: TimeBucket, items: [ScoredClipping])] {
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        guard !isSearching else { return [(bucket: .now, items: results)] }

        let now = Date()
        var grouped: [TimeBucket: [ScoredClipping]] = [:]
        for scored in results {
            let bucket = TimeBucket.bucket(for: scored.clipping, now: now)
            grouped[bucket, default: []].append(scored)
        }
        return TimeBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }
}
