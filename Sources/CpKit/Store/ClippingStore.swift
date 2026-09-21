import Foundation
import Observation

/// The in-memory index, and the only thing the UI reads from.
///
/// Everything lives in one array held in `lastCopiedAt` order. At the default
/// 2,000-item cap that is a few megabytes and a linear scan measured in
/// microseconds, which is well under the frame budget the picker actually has to
/// hit. See `ClippingArchive` for why this is not a database.
@Observable
@MainActor
public final class ClippingStore {

    public private(set) var clippings: [Clipping] = []

    private let archive: ClippingArchive?
    private let settings: Settings

    /// Content key to identity, so de-duplication is a dictionary hit rather than
    /// a scan on every single copy.
    private var indexByDedupeKey: [String: UUID] = [:]

    public init(archive: ClippingArchive?, settings: Settings) {
        self.archive = archive
        self.settings = settings
        if let archive {
            clippings = archive.load()
            rebuildIndex()
        }
    }

    // MARK: - Ingest

    /// Records a new capture, collapsing it onto an existing clipping when the
    /// content matches. Returns the clipping now at the head of the list.
    @discardableResult
    public func ingest(_ incoming: Clipping) -> Clipping {
        if let existingID = indexByDedupeKey[incoming.dedupeKey],
           let index = clippings.firstIndex(where: { $0.id == existingID }) {
            var existing = clippings[index]
            existing.lastCopiedAt = incoming.lastCopiedAt
            existing.copyCount += 1
            // Re-copying from a different app should update the cue, not keep the
            // stale one: the app you last copied from is the one you'll remember.
            existing.sourceBundleID = incoming.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = incoming.sourceAppName ?? existing.sourceAppName

            clippings.remove(at: index)
            clippings.insert(existing, at: 0)
            archive?.append(existing)
            return existing
        }

        clippings.insert(incoming, at: 0)
        indexByDedupeKey[incoming.dedupeKey] = incoming.id
        archive?.append(incoming)
        trimIfNeeded()
        return incoming
    }

    // MARK: - Mutation

    public func togglePin(_ id: UUID) {
        guard let index = clippings.firstIndex(where: { $0.id == id }) else { return }
        clippings[index].isPinned.toggle()
        archive?.append(clippings[index])
    }

    public func delete(_ id: UUID) {
        guard let index = clippings.firstIndex(where: { $0.id == id }) else { return }
        let removed = clippings.remove(at: index)
        if indexByDedupeKey[removed.dedupeKey] == removed.id {
            indexByDedupeKey[removed.dedupeKey] = nil
        }
        archive?.remove(id: removed.id, assetFilename: removed.assetFilename)
    }

    /// Clears unpinned history. Pins survive — losing them to a stray ⌘⇧⌫ is the
    /// kind of thing people only forgive once.
    public func clearUnpinned() {
        let removed = clippings.filter { !$0.isPinned }
        clippings.removeAll { !$0.isPinned }
        rebuildIndex()
        for clipping in removed {
            archive?.remove(id: clipping.id, assetFilename: clipping.assetFilename)
        }
        archive?.compact(liveClippings: clippings)
    }

    /// Replaces a clipping in place — used when a link title resolves.
    public func update(_ clipping: Clipping) {
        guard let index = clippings.firstIndex(where: { $0.id == clipping.id }) else { return }
        clippings[index] = clipping
        archive?.append(clipping)
    }

    public func clipping(withID id: UUID) -> Clipping? {
        clippings.first { $0.id == id }
    }

    // MARK: - Housekeeping

    private func trimIfNeeded() {
        let limit = max(50, settings.historyLimit)
        guard clippings.count > limit else {
            if let archive, archive.needsCompaction(liveCount: clippings.count) {
                archive.compact(liveClippings: clippings)
            }
            return
        }

        // Pins are exempt from the cap; they are the one thing the user said to keep.
        var kept: [Clipping] = []
        var dropped: [Clipping] = []
        var budget = limit
        for clipping in clippings {
            if clipping.isPinned {
                kept.append(clipping)
            } else if budget > 0 {
                kept.append(clipping)
                budget -= 1
            } else {
                dropped.append(clipping)
            }
        }

        clippings = kept
        rebuildIndex()
        for clipping in dropped {
            archive?.remove(id: clipping.id, assetFilename: clipping.assetFilename)
        }
        archive?.compact(liveClippings: clippings)
    }

    private func rebuildIndex() {
        indexByDedupeKey.removeAll(keepingCapacity: true)
        for clipping in clippings where indexByDedupeKey[clipping.dedupeKey] == nil {
            indexByDedupeKey[clipping.dedupeKey] = clipping.id
        }
    }
}
