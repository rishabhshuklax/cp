import Foundation
import Observation

/// A deleted clipping, held by whoever offers "Undo". Its files wait in the
/// archive's trash until the next launch, so restoring it brings them back.
public struct DeletedClipping: Sendable {
    public let clipping: Clipping
}

/// The in-memory index, and the only thing the UI reads from.
///
/// Everything lives in one array held newest first by `lastCopiedAt` — pinned
/// clippings stay where their date puts them. At the default 2,000-item cap
/// that is a few megabytes; search folds each clipping once and then costs a
/// byte scan per keystroke. See `ClippingArchive` for why this is not a
/// database.
@Observable
@MainActor
public final class ClippingStore {

    public typealias DeletedClipping = CpKit.DeletedClipping

    public private(set) var clippings: [Clipping] = []
    /// Bumps on every change, so a view can tell "something changed" cheaply.
    public private(set) var version = 0

    @ObservationIgnored private let archive: ClippingArchive?
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let recognizer: TextRecognizer?

    /// Content key to identity, so de-duplication is a dictionary hit rather than
    /// a scan on every single copy.
    @ObservationIgnored private var indexByDedupeKey: [String: UUID] = [:]
    /// The text of concealed clippings. Memory only; it goes when the clipping
    /// does.
    @ObservationIgnored private var vault: [UUID: String] = [:]
    @ObservationIgnored private var expiries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let searchIndex = SearchIndex()
    /// Records appended to the log since it was last written whole.
    @ObservationIgnored private var recordsInLog = 0
    @ObservationIgnored private var recognizing: Set<UUID> = []
    @ObservationIgnored private var appsCache: (version: Int, apps: [(bundleID: String, name: String, count: Int)])?

    public init(archive: ClippingArchive?, settings: Settings, recognizer: TextRecognizer? = TextRecognizer()) {
        self.archive = archive
        self.settings = settings
        self.recognizer = recognizer
        if let archive {
            clippings = archive.load()
            recordsInLog = archive.loadedRecordCount
            rebuildDedupeIndex()
        }
        observeHistoryLimit()
        backfillImageFacts()
    }

    // MARK: - Ingest

    /// Records a new capture, collapsing it onto an existing clipping when the
    /// content matches. Returns the clipping now standing for it. A concealed
    /// capture's text goes in `secret`, never in the payload.
    @discardableResult
    public func ingest(_ incoming: Clipping, secret: String? = nil) -> Clipping {
        if incoming.isConcealed { return ingestConcealed(incoming, secret: secret) }

        if let existingID = indexByDedupeKey[incoming.dedupeKey], let index = position(of: existingID) {
            var existing = clippings[index]
            existing.lastCopiedAt = incoming.lastCopiedAt
            existing.copyCount += 1
            // Re-copying from a different app should update the cue, not keep the
            // stale one: the app you last copied from is the one you'll remember.
            existing.sourceBundleID = incoming.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = incoming.sourceAppName ?? existing.sourceAppName
            existing.sourceURL = incoming.sourceURL ?? existing.sourceURL
            if existing.pixelWidth == nil {
                existing.pixelWidth = incoming.pixelWidth
                existing.pixelHeight = incoming.pixelHeight
            }
            // The same image again: its bytes are already on disk under the first
            // copy's name, so the second file would be an orphan.
            var redundant: [String] = []
            if let file = incoming.assetFilename, file != existing.assetFilename { redundant.append(file) }
            // The same words with newer formatting: keep the newer formatting.
            if let rich = incoming.richAssetFilename, rich != existing.richAssetFilename {
                if let old = existing.richAssetFilename { redundant.append(old) }
                existing.richAssetFilename = rich
            }
            archive?.deleteAssets(redundant)
            replace(at: index, with: existing)
            recognizeText(in: existing)
            return existing
        }

        insert(incoming)
        persist([incoming])
        trimIfNeeded()
        recognizeText(in: incoming)
        return incoming
    }

    /// Concealed clippings are never written, never deduped, and forgotten —
    /// row and text together — after `settings.secretLifetime`.
    private func ingestConcealed(_ incoming: Clipping, secret: String?) -> Clipping {
        let lifetime = settings.secretLifetime
        // Zero keeps nothing: no text, and no row pointing at text that isn't there.
        guard lifetime > 0 else { return incoming }

        var concealed = incoming
        concealed.payload = ""
        concealed.lineCount = 0
        concealed.wordCount = 0
        concealed.expiresAt = Date().addingTimeInterval(lifetime)
        insert(concealed)
        if let secret, !secret.isEmpty { vault[concealed.id] = secret }

        let id = concealed.id
        expiries[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.forget(id)
        }
        return concealed
    }

    // MARK: - Mutation

    /// Replaces a clipping in place — for a resolved link title, recognized text,
    /// or anything else learned after capture.
    public func update(_ clipping: Clipping) {
        guard let index = position(of: clipping.id) else { return }
        replace(at: index, with: clipping)
    }

    public func togglePin(_ id: UUID) {
        guard let index = position(of: id) else { return }
        var clipping = clippings[index]
        clipping.isPinned.toggle()
        replace(at: index, with: clipping)
    }

    public func setPinned(_ ids: [UUID], _ pinned: Bool) {
        let wanted = Set(ids)
        var changed: [Clipping] = []
        for index in clippings.indices where wanted.contains(clippings[index].id) && clippings[index].isPinned != pinned {
            clippings[index].isPinned = pinned
            changed.append(clippings[index])
        }
        guard !changed.isEmpty else { return }
        persist(changed)
        version += 1
    }

    /// Deletes one clipping and returns what `restore` needs to undo it. A
    /// concealed clipping is forgotten instead, and there is nothing to undo:
    /// its text must not outlive it.
    @discardableResult
    public func delete(_ id: UUID) -> DeletedClipping? {
        guard let index = position(of: id) else { return nil }
        guard !clippings[index].isConcealed else {
            forget(id)
            return nil
        }
        let removed = clippings.remove(at: index)
        removeFromIndexes(removed)
        archive?.remove([removed], keepAssets: true)
        recordsInLog += 1
        version += 1
        return DeletedClipping(clipping: removed)
    }

    /// Deletes several at once, for good.
    public func delete(_ ids: [UUID]) {
        let wanted = Set(ids)
        for clipping in clippings where wanted.contains(clipping.id) && clipping.isConcealed {
            forget(clipping.id)
        }
        let removed = clippings.filter { wanted.contains($0.id) }
        guard !removed.isEmpty else { return }
        clippings.removeAll { wanted.contains($0.id) }
        removed.forEach(removeFromIndexes)
        archive?.remove(removed, keepAssets: false)
        recordsInLog += removed.count
        version += 1
        compactIfNeeded()
    }

    public func restore(_ deleted: DeletedClipping) {
        let clipping = deleted.clipping
        guard position(of: clipping.id) == nil else { return }
        // Copied again since it was deleted: that copy already stands in for it.
        if let existingID = indexByDedupeKey[clipping.dedupeKey], position(of: existingID) != nil {
            if clipping.isPinned { setPinned([existingID], true) }
            return
        }
        archive?.restoreAssets(of: clipping)
        insert(clipping)
        persist([clipping])
    }

    /// Clears unpinned history. Pins survive — losing them to a stray ⌘⇧⌫ is the
    /// kind of thing people only forgive once.
    public func clearUnpinned() {
        let removed = clippings.filter { !$0.isPinned }
        guard !removed.isEmpty else { return }
        for clipping in removed where clipping.isConcealed {
            expiries.removeValue(forKey: clipping.id)?.cancel()
            vault[clipping.id] = nil
        }
        clippings.removeAll { !$0.isPinned }
        removed.forEach { searchIndex.invalidate($0.id) }
        rebuildDedupeIndex()
        archive?.deleteAssets(removed.flatMap { [$0.assetFilename, $0.richAssetFilename].compactMap { $0 } })
        archive?.compact(liveClippings: clippings)
        recordsInLog = clippings.filter { !$0.isConcealed }.count
        version += 1
    }

    // MARK: - Reading

    public func clipping(withID id: UUID) -> Clipping? {
        clippings.first { $0.id == id }
    }

    /// The text of a concealed clipping, while it lives.
    public func secret(for id: UUID) -> String? {
        vault[id]
    }

    /// Removes a concealed clipping and its text now, instead of at expiry.
    public func forget(_ id: UUID) {
        expiries.removeValue(forKey: id)?.cancel()
        vault[id] = nil
        guard let index = position(of: id), clippings[index].isConcealed else { return }
        let removed = clippings.remove(at: index)
        removeFromIndexes(removed)
        version += 1
    }

    public func assetURL(_ filename: String) -> URL? {
        archive?.assetURL(for: filename)
    }

    public func search(_ query: ClipQuery) -> [ClipHit] {
        searchIndex.search(query, in: clippings)
    }

    /// A filter the last word typed could stand for — "links", "yesterday",
    /// "fig" for Figma — to offer, never to apply on its own.
    public func suggestion(for text: String) -> ClipFilter? {
        ClipSearch.suggestion(for: text, apps: sourceApps)
    }

    /// Every app something was copied from, most used first.
    public var sourceApps: [(bundleID: String, name: String, count: Int)] {
        if let appsCache, appsCache.version == version { return appsCache.apps }
        var counts: [String: (name: String, count: Int)] = [:]
        // Newest first, so the first name seen for an app is its current one.
        for clipping in clippings where !clipping.isConcealed {
            guard let bundleID = clipping.sourceBundleID, !bundleID.isEmpty else { continue }
            let name = counts[bundleID]?.name ?? clipping.sourceAppName ?? bundleID
            counts[bundleID] = (name, (counts[bundleID]?.count ?? 0) + 1)
        }
        let apps = counts
            .map { (bundleID: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        appsCache = (version, apps)
        return apps
    }

    // MARK: - Bookkeeping

    private func position(of id: UUID) -> Int? {
        clippings.firstIndex { $0.id == id }
    }

    /// Where a clipping copied at `date` belongs, newest first. Ties go in front,
    /// so of two copies in the same instant the later insert is the newer.
    private func insertionIndex(for date: Date) -> Int {
        var low = 0
        var high = clippings.count
        while low < high {
            let mid = (low + high) / 2
            if clippings[mid].lastCopiedAt > date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func insert(_ clipping: Clipping) {
        clippings.insert(clipping, at: insertionIndex(for: clipping.lastCopiedAt))
        if indexByDedupeKey[clipping.dedupeKey] == nil {
            indexByDedupeKey[clipping.dedupeKey] = clipping.id
        }
        version += 1
    }

    /// Swaps in a new value for a clipping, moving it if its date changed, and
    /// keeps every index in step.
    private func replace(at index: Int, with clipping: Clipping) {
        let old = clippings[index]
        if old.dedupeKey != clipping.dedupeKey {
            if indexByDedupeKey[old.dedupeKey] == old.id { indexByDedupeKey[old.dedupeKey] = nil }
            if indexByDedupeKey[clipping.dedupeKey] == nil { indexByDedupeKey[clipping.dedupeKey] = clipping.id }
        }
        if old.lastCopiedAt == clipping.lastCopiedAt {
            clippings[index] = clipping
        } else {
            clippings.remove(at: index)
            clippings.insert(clipping, at: insertionIndex(for: clipping.lastCopiedAt))
        }
        searchIndex.invalidate(clipping.id)
        persist([clipping])
        version += 1
    }

    private func removeFromIndexes(_ clipping: Clipping) {
        if indexByDedupeKey[clipping.dedupeKey] == clipping.id {
            indexByDedupeKey[clipping.dedupeKey] = nil
        }
        searchIndex.invalidate(clipping.id)
    }

    private func rebuildDedupeIndex() {
        indexByDedupeKey.removeAll(keepingCapacity: true)
        for clipping in clippings where indexByDedupeKey[clipping.dedupeKey] == nil {
            indexByDedupeKey[clipping.dedupeKey] = clipping.id
        }
    }

    private func persist(_ changed: [Clipping]) {
        let stored = changed.filter { !$0.isConcealed }
        guard let archive, !stored.isEmpty else { return }
        archive.append(stored)
        recordsInLog += stored.count
    }

    // MARK: - History limit

    /// A new limit applies at once, not on the next copy.
    private func observeHistoryLimit() {
        withObservationTracking {
            _ = settings.historyLimit
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.trimIfNeeded()
                self?.observeHistoryLimit()
            }
        }
    }

    /// Drops the oldest unpinned clippings beyond the limit. Pins are exempt —
    /// they are the one thing the user said to keep — and concealed clippings
    /// expire on their own. Dropping appends tombstones; the log is only
    /// rewritten once it has grown to twice the live history, instead of on
    /// every copy once the history is full.
    private func trimIfNeeded() {
        var budget = max(50, settings.historyLimit)
        var dropped: [Clipping] = []
        for clipping in clippings where !clipping.isPinned && !clipping.isConcealed {
            if budget > 0 {
                budget -= 1
            } else {
                dropped.append(clipping)
            }
        }
        guard !dropped.isEmpty else {
            compactIfNeeded()
            return
        }
        let droppedIDs = Set(dropped.map(\.id))
        clippings.removeAll { droppedIDs.contains($0.id) }
        dropped.forEach(removeFromIndexes)
        archive?.remove(dropped, keepAssets: false)
        recordsInLog += dropped.count
        version += 1
        compactIfNeeded()
    }

    private func compactIfNeeded() {
        guard let archive else { return }
        let live = clippings.reduce(0) { $0 + ($1.isConcealed ? 0 : 1) }
        guard recordsInLog > max(256, live * 2) else { return }
        archive.compact(liveClippings: clippings)
        recordsInLog = live
    }

    // MARK: - Images

    /// Reads the text in a new image off the main thread, then records it. An
    /// empty result is recorded too, so the image is not read twice.
    private func recognizeText(in clipping: Clipping) {
        guard settings.recognizeText, let recognizer, clipping.kind == .image, clipping.ocrText == nil,
              let file = clipping.assetFilename, let url = archive?.assetURL(for: file),
              !recognizing.contains(clipping.id) else { return }
        let id = clipping.id
        recognizing.insert(id)
        Task { [weak self] in
            let result = await recognizer.recognize(pngAt: url)
            guard let self else { return }
            self.recognizing.remove(id)
            guard var current = self.clipping(withID: id) else { return }
            current.ocrText = result?.text ?? ""
            current.ocrLines = result?.lines ?? []
            self.update(current)
        }
    }

    /// Images captured before hashes and pixel sizes were recorded get both,
    /// read off the main thread, so they dedupe like new ones.
    private func backfillImageFacts() {
        guard let archive else { return }
        let pending: [(UUID, URL)] = clippings.compactMap { clipping in
            guard clipping.kind == .image, clipping.contentHash == nil || clipping.pixelWidth == nil,
                  let file = clipping.assetFilename else { return nil }
            return (clipping.id, archive.assetURL(for: file))
        }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var facts: [(id: UUID, hash: String, width: Int, height: Int)] = []
            for (id, url) in pending {
                if let read = ImageFacts.read(fileAt: url) {
                    facts.append((id, read.hash, read.pixelWidth, read.pixelHeight))
                }
            }
            guard !facts.isEmpty else { return }
            await self?.applyImageFacts(facts)
        }
    }

    private func applyImageFacts(_ facts: [(id: UUID, hash: String, width: Int, height: Int)]) {
        for fact in facts {
            guard let index = position(of: fact.id) else { continue }
            var clipping = clippings[index]
            clipping.contentHash = clipping.contentHash ?? fact.hash
            clipping.pixelWidth = fact.width
            clipping.pixelHeight = fact.height
            replace(at: index, with: clipping)
        }
    }
}
