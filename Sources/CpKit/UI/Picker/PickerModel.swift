import AppKit
import Observation
import SwiftUI

/// What the picker asks the app to do. The model decides *what* happens on a
/// key; the controller knows how to paste, delete and open things.
@MainActor
public protocol PickerHost: AnyObject {
    /// False when cp may not press ⌘V for you, which changes what the primary
    /// button says.
    var canPaste: Bool { get }
    func paste(_ clipping: Clipping, as format: PasteFormat)
    func pasteStackInOrder()
    func closePicker()
    func openSettings()
    func openLink(_ clipping: Clipping)
    func openSource(_ clipping: Clipping)
    func revealInFinder(_ clipping: Clipping)
    func saveImageToDesktop(_ clipping: Clipping)
    func togglePin(_ clipping: Clipping)
    func delete(_ clipping: Clipping)
    func forget(_ clipping: Clipping)
    func undoDelete()
    func requestPastePermission()
}

/// One entry in the list: a day label or a clipping.
public enum PickerItem: Identifiable, Equatable {
    case section(RelativeTime.Day)
    case hit(ClipHit)

    public var id: String {
        switch self {
        case .section(let day): return "section-\(day.rawValue)"
        case .hit(let hit): return hit.id.uuidString
        }
    }

    public var hit: ClipHit? {
        if case .hit(let hit) = self { return hit }
        return nil
    }

    public static func == (lhs: PickerItem, rhs: PickerItem) -> Bool {
        switch (lhs, rhs) {
        case (.section(let a), .section(let b)): return a == b
        case (.hit(let a), .hit(let b)): return a.id == b.id && a.score == b.score
        default: return false
        }
    }
}

/// One row of the ⌘K list.
public struct PickerAction: Identifiable, Equatable {
    public enum Kind: Equatable {
        case format(PasteFormat)
        case stack
        case pin
        case openLink
        case openSource
        case reveal
        case saveImage
        case delete
        case forget
    }

    public let kind: Kind
    public let label: String
    public let key: String?
    public let isDanger: Bool
    /// True for the first row under the separator — the things that are not
    /// "paste as…".
    public let startsGroup: Bool

    public var id: String { label }
}

/// Where the list should scroll to, and why. The token makes two requests for
/// the same row distinguishable, so a view can act on every one.
public struct ScrollTarget: Equatable {
    public let id: UUID
    public let anchor: ScrollAnchor
    public let token: Int
}

/// One invocation of the picker: what is typed, what is filtered, what is
/// selected, and what each key does about it.
@Observable
@MainActor
public final class PickerModel {

    // MARK: - Published state

    public var query: String {
        get { storedQuery }
        set {
            guard newValue != storedQuery else { return }
            storedQuery = newValue
            isLookOpen = false
            refresh(selecting: .top)
        }
    }

    public private(set) var tokens: [ClipFilter] = []
    public private(set) var scope: ClipScope = .recent
    public private(set) var hits: [ClipHit] = []
    public private(set) var items: [PickerItem] = []
    /// Row numbers, for the ⌘1…⌘9 keycaps, without a scan per row.
    @ObservationIgnored private var rowNumbers: [UUID: Int] = [:]
    public private(set) var selectedID: UUID?
    public private(set) var suggestion: ClipFilter?
    public private(set) var scrollTarget: ScrollTarget?

    /// Look: the hero fills the panel and the list goes away.
    public var isLookOpen = false
    public private(set) var isActionsOpen = false
    public private(set) var actionIndex = 0
    public var actionQuery: String = "" {
        didSet {
            guard actionQuery != oldValue else { return }
            actionIndex = 0
        }
    }

    /// ⌘ held down: the rows trade their times for ⌘1…⌘9.
    public private(set) var isCommandHeld = false
    /// Bumped to put the caret back in the search field.
    public private(set) var focusToken = 0

    public let store: ClippingStore
    public let settings: Settings
    public let links: LinkPreviews
    public let stack: PasteStack

    @ObservationIgnored public weak var host: PickerHost?
    @ObservationIgnored private var storedQuery = ""
    @ObservationIgnored private var lastPointer: CGPoint = .zero
    @ObservationIgnored private var scrollToken = 0
    @ObservationIgnored private var viewportTop: CGFloat = 0
    @ObservationIgnored private var viewportHeight: CGFloat = 0
    @ObservationIgnored private var layout = ListLayout(itemHeights: [])
    @ObservationIgnored private var now = Date()

    public init(store: ClippingStore, settings: Settings, links: LinkPreviews, stack: PasteStack) {
        self.store = store
        self.settings = settings
        self.links = links
        self.stack = stack
        observeStore()
    }

    // MARK: - Opening

    /// Called every time the panel comes up. The newest clip is selected — the
    /// one ⌘V would paste — never a pin for being a pin.
    public func open(pointer: CGPoint = NSEvent.mouseLocation) {
        storedQuery = ""
        tokens = []
        scope = .recent
        isLookOpen = false
        isCommandHeld = false
        closeActions()
        lastPointer = pointer
        now = Date()
        refresh(selecting: .top)
        focusToken += 1
    }

    public func close() {
        isLookOpen = false
        closeActions()
        isCommandHeld = false
        host?.closePicker()
    }

    // MARK: - Query, tokens, scope

    public func addToken(_ filter: ClipFilter) {
        guard !tokens.contains(filter) else { return }
        tokens.append(filter)
        refresh(selecting: .top)
    }

    public func removeToken(at index: Int) {
        guard tokens.indices.contains(index) else { return }
        tokens.remove(at: index)
        refresh(selecting: .top)
    }

    public func setScope(_ newScope: ClipScope) {
        guard scope != newScope else { return }
        scope = newScope
        refresh(selecting: .top)
    }

    public func toggleScope() {
        setScope(scope == .recent ? .pinned : .recent)
    }

    /// Turns the last word typed into the filter it was offering.
    public func acceptSuggestion() {
        guard let suggestion else { return }
        var words = storedQuery.split(separator: " ", omittingEmptySubsequences: false)
        if !words.isEmpty { words.removeLast() }
        storedQuery = words.joined(separator: " ")
        if !storedQuery.isEmpty, !storedQuery.hasSuffix(" ") { storedQuery += " " }
        if !tokens.contains(suggestion) { tokens.append(suggestion) }
        refresh(selecting: .top)
        focusToken += 1
    }

    // MARK: - Results

    private enum Selecting {
        case top
        case keep
    }

    private func refresh(selecting: Selecting) {
        hits = store.search(ClipQuery(text: storedQuery, filters: tokens, scope: scope))
        rebuildItems()
        suggestion = storedQuery.isEmpty ? nil : store.suggestion(for: storedQuery).flatMap { tokens.contains($0) ? nil : $0 }

        switch selecting {
        case .top:
            select(hits.first?.id, scroll: true)
        case .keep:
            if let selectedID, hits.contains(where: { $0.id == selectedID }) { return }
            select(hits.first?.id, scroll: false)
        }
    }

    /// Day labels only on an unfiltered Recent list. Once you have typed, the
    /// order is relevance and a date header would hide the best match.
    private func rebuildItems() {
        var items: [PickerItem] = []
        var heights: [CGFloat] = []
        rowNumbers = [:]
        let sectioned = storedQuery.isEmpty && scope == .recent
        var currentDay: RelativeTime.Day?
        for hit in hits {
            if sectioned {
                let day = RelativeTime.day(hit.clipping.lastCopiedAt, now: now)
                if day != currentDay {
                    currentDay = day
                    items.append(.section(day))
                    heights.append(Theme.Metric.sectionHeight)
                }
            }
            rowNumbers[hit.id] = rowNumbers.count
            items.append(.hit(hit))
            heights.append(Theme.Metric.rowHeight)
        }
        self.items = items
        layout = ListLayout(
            itemHeights: heights,
            topPadding: Theme.Metric.listTopPadding,
            bottomPadding: Theme.Metric.listBottomPadding
        )
    }

    /// The store changed under us — a copy landed, a title resolved, a delete
    /// was undone. The list follows; the selection stays where it was.
    private func observeStore() {
        withObservationTracking {
            _ = store.version
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh(selecting: .keep)
                self.observeStore()
            }
        }
    }

    public func index(of id: UUID) -> Int? { rowNumbers[id] }

    /// The words typed, for highlighting a preview the search index has no
    /// ranges for.
    public var queryWords: [String] {
        storedQuery.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
    }

    // MARK: - Selection

    public var selected: Clipping? {
        guard let selectedID else { return nil }
        return hits.first { $0.id == selectedID }?.clipping
    }

    public var selectedHit: ClipHit? {
        guard let selectedID else { return nil }
        return hits.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return hits.firstIndex { $0.id == selectedID }
    }

    public func select(_ id: UUID?, scroll: Bool) {
        guard selectedID != id else { return }
        selectedID = id
        if isActionsOpen { closeActions() }
        if let id, let clipping = hits.first(where: { $0.id == id })?.clipping {
            links.request(clipping)
        }
        guard scroll, let id else { return }
        requestScroll(to: id)
    }

    public func moveSelection(by offset: Int) {
        guard !hits.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + offset, 0), hits.count - 1)
        guard next != current || selectedID == nil else { return }
        select(hits[next].id, scroll: true)
    }

    /// The pointer only selects a row once it has actually moved. A row sliding
    /// under a still pointer — which is what scrolling does — must not change
    /// what ↩ pastes.
    public func pointerMoved(to point: CGPoint, over id: UUID?) {
        guard point != lastPointer else { return }
        lastPointer = point
        guard let id else { return }
        // Never scrolls: hover follows the pointer, the list does not.
        select(id, scroll: false)
    }

    /// Reported by the list as it lays out and scrolls.
    public func viewportChanged(top: CGFloat, height: CGFloat) {
        viewportTop = top
        viewportHeight = height
    }

    private func requestScroll(to id: UUID) {
        guard let index = items.firstIndex(where: { $0.hit?.id == id }) else { return }
        guard let anchor = layout.anchor(for: index, viewportTop: viewportTop, viewportHeight: viewportHeight) else { return }
        scrollToken += 1
        scrollTarget = ScrollTarget(id: id, anchor: anchor, token: scrollToken)
    }

    // MARK: - Keys

    public func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.command)
        guard held != isCommandHeld else { return }
        isCommandHeld = held
    }

    /// Returns true when the picker owns the key. False means it goes on to the
    /// search field, which is the only reason typing still works.
    public func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            modifiersChanged(event.modifierFlags)
            return false
        }
        if isActionsOpen {
            guard let key = ActionKeys.key(for: event) else { return false }
            handleAction(key)
            return true
        }
        guard let key = PickerKeys.key(for: event) else { return false }
        return handle(key)
    }

    @discardableResult
    public func handle(_ key: PickerKey) -> Bool {
        switch key {
        case .up:
            moveSelection(by: -1)
        case .down:
            moveSelection(by: 1)
        case .paste:
            pasteSelected()
        case .pastePlain:
            guard let clipping = selected else { return true }
            host?.paste(clipping, as: .plainText)
        case .stackToggle:
            guard let clipping = selected else { return true }
            stack.toggle(clipping.id)
        case .stackPaste:
            if stack.isEmpty { pasteSelected() } else { host?.pasteStackInOrder() }
        case .escape:
            escape()
        case .tab:
            if suggestion != nil { acceptSuggestion() } else { toggleScope() }
        case .space:
            guard storedQuery.isEmpty else { return false }
            isLookOpen.toggle()
        case .look:
            isLookOpen.toggle()
        case .actions:
            openActions()
        case .pin:
            guard let clipping = selected else { return true }
            host?.togglePin(clipping)
        case .delete:
            guard let clipping = selected else { return true }
            host?.delete(clipping)
        case .undo:
            host?.undoDelete()
        case .row(let number):
            guard hits.indices.contains(number - 1) else { return true }
            let clipping = hits[number - 1].clipping
            host?.paste(clipping, as: PasteFormats.defaultFormat(for: clipping, settings: settings))
        case .backspace:
            guard storedQuery.isEmpty, !tokens.isEmpty else { return false }
            tokens.removeLast()
            refresh(selecting: .top)
        case .settings:
            host?.openSettings()
        }
        return true
    }

    /// Pastes a clipping in whatever format it is meant to have — what a click
    /// on its row, or ↩ on it, does.
    public func paste(_ clipping: Clipping) {
        host?.paste(clipping, as: PasteFormats.defaultFormat(for: clipping, settings: settings))
    }

    public func paste(_ clipping: Clipping, as format: PasteFormat) {
        host?.paste(clipping, as: format)
    }

    public func setActionIndex(_ index: Int) {
        guard actions.indices.contains(index), actionIndex != index else { return }
        actionIndex = index
    }

    /// True only when pasting is on but not permitted — "Copy only" is a
    /// choice, not a problem to offer a fix for.
    public var needsPastePermission: Bool {
        settings.pasteAutomatically && !(host?.canPaste ?? true)
    }

    public func pasteSelected() {
        guard let clipping = selected else { return }
        host?.paste(clipping, as: PasteFormats.defaultFormat(for: clipping, settings: settings))
    }

    /// esc walks back out the way you came in: the actions list, then Look,
    /// then what you typed, then the picker itself.
    private func escape() {
        if isActionsOpen { closeActions(); return }
        if isLookOpen { isLookOpen = false; return }
        if !storedQuery.isEmpty || !tokens.isEmpty {
            storedQuery = ""
            tokens = []
            refresh(selecting: .top)
            focusToken += 1
            return
        }
        close()
    }

    // MARK: - Actions list

    public func openActions() {
        guard selected != nil else { return }
        isActionsOpen = true
        actionQuery = ""
        actionIndex = 0
    }

    public func closeActions() {
        guard isActionsOpen else {
            isActionsOpen = false
            return
        }
        isActionsOpen = false
        actionQuery = ""
        focusToken += 1
    }

    public func toggleActions() {
        isActionsOpen ? closeActions() : openActions()
    }

    public var actions: [PickerAction] {
        guard let clipping = selected else { return [] }
        let all = Self.actions(for: clipping, settings: settings, inStack: stack.contains(clipping.id))
        let filter = actionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !filter.isEmpty else { return all }
        return all.filter { $0.label.lowercased().contains(filter) }
    }

    /// Paste formats first, then the things you can do with the clipping
    /// itself. Only what applies: a link offers the browser, a file offers
    /// Finder, a password offers neither.
    public static func actions(for clipping: Clipping, settings: Settings, inStack: Bool) -> [PickerAction] {
        var actions: [PickerAction] = []
        if clipping.isConcealed {
            actions.append(PickerAction(kind: .format(.original), label: "Paste password", key: "↩",
                                        isDanger: false, startsGroup: false))
            actions.append(PickerAction(kind: .forget, label: "Forget now", key: nil, isDanger: true, startsGroup: true))
            return actions
        }

        for (index, format) in PasteFormats.menu(for: clipping, settings: settings).enumerated() {
            actions.append(PickerAction(
                kind: .format(format),
                label: format.menuLabel(for: clipping),
                key: index == 0 ? "↩" : nil,
                isDanger: false,
                startsGroup: false
            ))
        }
        if clipping.kind == .url {
            actions.append(PickerAction(kind: .openLink, label: "Open in browser", key: nil,
                                        isDanger: false, startsGroup: false))
        }
        if clipping.kind == .file {
            actions.append(PickerAction(kind: .reveal, label: "Show in Finder", key: nil,
                                        isDanger: false, startsGroup: false))
        }
        if clipping.kind == .image {
            actions.append(PickerAction(kind: .saveImage, label: "Save to Desktop", key: nil,
                                        isDanger: false, startsGroup: false))
        }
        if clipping.sourceURL != nil {
            actions.append(PickerAction(kind: .openSource, label: "Open where you copied it", key: nil,
                                        isDanger: false, startsGroup: false))
        }
        actions.append(PickerAction(
            kind: .stack,
            label: inStack ? "Take out of the stack" : "Add to the stack",
            key: "⇧↩", isDanger: false, startsGroup: true
        ))
        actions.append(PickerAction(kind: .pin, label: clipping.isPinned ? "Unpin" : "Pin", key: "⌘P",
                                    isDanger: false, startsGroup: false))
        actions.append(PickerAction(kind: .delete, label: "Delete", key: "⌘⌫", isDanger: true, startsGroup: false))
        return actions
    }

    public func handleAction(_ key: ActionKey) {
        let rows = actions
        switch key {
        case .up:
            guard !rows.isEmpty else { return }
            actionIndex = (actionIndex - 1 + rows.count) % rows.count
        case .down:
            guard !rows.isEmpty else { return }
            actionIndex = (actionIndex + 1) % rows.count
        case .run:
            guard rows.indices.contains(actionIndex) else { return }
            run(rows[actionIndex])
        case .close:
            closeActions()
        }
    }

    public func run(_ action: PickerAction) {
        guard let clipping = selected else { return }
        closeActions()
        switch action.kind {
        case .format(let format): host?.paste(clipping, as: format)
        case .stack: stack.toggle(clipping.id)
        case .pin: host?.togglePin(clipping)
        case .openLink: host?.openLink(clipping)
        case .openSource: host?.openSource(clipping)
        case .reveal: host?.revealInFinder(clipping)
        case .saveImage: host?.saveImageToDesktop(clipping)
        case .delete: host?.delete(clipping)
        case .forget: host?.forget(clipping)
        }
    }

    // MARK: - The hero's contextual capsule

    /// The one thing worth offering beside "More" and "Paste", per kind. Nil
    /// when there is nothing a second button would add.
    public var heroAction: PickerAction? {
        guard let clipping = selected else { return nil }
        if clipping.isConcealed {
            return PickerAction(kind: .forget, label: "Forget", key: nil, isDanger: false, startsGroup: false)
        }
        switch clipping.kind {
        case .url:
            let format: PasteFormat = URLTracking.hasTracking(clipping.payload) ? .cleanLink : .markdown
            let label = format == .cleanLink ? "Clean link" : "Markdown"
            return PickerAction(kind: .format(format), label: label, key: nil, isDanger: false, startsGroup: false)
        case .code:
            return PickerAction(kind: .format(.codeBlock), label: "Code block", key: nil, isDanger: false, startsGroup: false)
        case .json:
            return PickerAction(kind: .format(.jsonMinified), label: "One line", key: nil, isDanger: false, startsGroup: false)
        case .image:
            guard !(clipping.ocrText ?? "").isEmpty else { return nil }
            return PickerAction(kind: .format(.imageText), label: "Paste text", key: nil, isDanger: false, startsGroup: false)
        case .file:
            return PickerAction(kind: .format(.filePath), label: "Path", key: nil, isDanger: false, startsGroup: false)
        case .richText:
            return PickerAction(kind: .format(.plainText), label: "Plain text", key: nil, isDanger: false, startsGroup: false)
        case .text, .color:
            return nil
        }
    }

    /// What the primary button says. Without permission cp can only put the
    /// clipping on the clipboard, and says so instead of pretending.
    public var canPaste: Bool {
        settings.pasteAutomatically && (host?.canPaste ?? true)
    }
}
