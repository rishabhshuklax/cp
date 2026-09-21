import Foundation

/// On-disk persistence: an append-only JSONL log plus a directory of binary assets.
///
/// Not a database, on purpose. A clipboard manager sees a few hundred copies a day
/// against a capped history, which is small enough to hold entirely in memory and
/// scan linearly. What an append-only log buys instead is that a copy costs one
/// `write(2)` on a background queue and a crash can lose at most the last line.
/// The store asks for a compaction once the log holds more than twice as many
/// records as there are live clippings.
///
/// If history ever needs to outgrow memory, this is the seam to swap for SQLite:
/// `load()` and `append(_:)` are the entire contract.
public final class ClippingArchive: @unchecked Sendable {

    public enum ArchiveError: Error {
        case directoryUnavailable
    }

    /// The line format since the first build: `{"upsert":{"_0":{…}}}` and
    /// `{"delete":{"_0":"<uuid>"}}`. Changing this enum changes the file.
    private enum Record: Codable {
        case upsert(Clipping)
        case delete(UUID)
    }

    private let directory: URL
    private let logURL: URL
    private let assetsURL: URL
    /// Assets of deleted clippings wait here until the next launch, so undoing a
    /// delete brings the image back too.
    private let trashURL: URL
    private let queue = DispatchQueue(label: "dev.cp.archive", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Records in the log when it was loaded. The store counts on from here to
    /// decide when to compact.
    public private(set) var loadedRecordCount = 0

    // Confined to `queue`.
    private var writtenRecords = 0
    private var checkedTail = false

    public init(directory: URL? = nil) throws {
        let resolved: URL
        if let directory {
            resolved = directory
        } else {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { throw ArchiveError.directoryUnavailable }
            resolved = support.appendingPathComponent("cp", isDirectory: true)
        }

        self.directory = resolved
        self.logURL = resolved.appendingPathComponent("history.jsonl")
        self.assetsURL = resolved.appendingPathComponent("assets", isDirectory: true)
        self.trashURL = resolved.appendingPathComponent("trash", isDirectory: true)

        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        // Fractional seconds, so two copies in the same second keep their order
        // across a relaunch. Lines from before the redesign have whole seconds.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ClippingArchive.encode(date))
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? ClippingArchive.fractionalDates.parse(string) { return date }
            if let date = try? ClippingArchive.wholeSecondDates.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(string)")
        }
    }

    static let fractionalDates = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let wholeSecondDates = Date.ISO8601FormatStyle()

    /// `2026-09-21T13:32:34.658123Z`: ISO 8601 to the microsecond. The format
    /// style stops at milliseconds, and two records a few microseconds apart
    /// (a restore right after a copy) should still come back in order.
    static func encode(_ date: Date) -> String {
        var seconds = date.timeIntervalSinceReferenceDate.rounded(.down)
        var micros = Int(((date.timeIntervalSinceReferenceDate - seconds) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            seconds += 1
            micros -= 1_000_000
        }
        let whole = Date(timeIntervalSinceReferenceDate: seconds).formatted(wholeSecondDates)
        let digits = String(micros)
        return whole.dropLast() + "." + String(repeating: "0", count: 6 - digits.count) + digits + "Z"
    }

    public var assetsDirectory: URL { assetsURL }

    public func assetURL(for filename: String) -> URL {
        assetsURL.appendingPathComponent(filename)
    }

    // MARK: - Reading

    /// Replays the log into the last-writer-wins state it represents, newest
    /// first. Malformed lines are skipped rather than aborting the load: a
    /// truncated final line after a hard crash should cost one clipping, not the
    /// whole history.
    public func load() -> [Clipping] {
        guard let data = try? Data(contentsOf: logURL) else {
            loadedRecordCount = 0
            return []
        }

        var byID: [UUID: Clipping] = [:]
        var position: [UUID: Int] = [:]
        var records = 0

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }
            records += 1
            switch record {
            case .upsert(let clipping):
                byID[clipping.id] = clipping
                position[clipping.id] = records
            case .delete(let id):
                byID[id] = nil
            }
        }

        loadedRecordCount = records
        let live = byID.values.sorted { lhs, rhs in
            if lhs.lastCopiedAt != rhs.lastCopiedAt { return lhs.lastCopiedAt > rhs.lastCopiedAt }
            // Same instant: the one written later is the newer copy.
            return position[lhs.id, default: 0] > position[rhs.id, default: 0]
        }

        let referenced = Set(live.flatMap { [$0.assetFilename, $0.richAssetFilename].compactMap { $0 } })
        let loadedAt = Date()
        queue.async { [self] in
            writtenRecords = records
            try? FileManager.default.removeItem(at: trashURL)
            sweepOrphans(keeping: referenced, olderThan: loadedAt)
        }
        return live
    }

    // MARK: - Writing

    public func append(_ clipping: Clipping) {
        append([clipping])
    }

    /// Concealed clippings live for the session and never touch disk. That is the
    /// whole point of the concealed flag; writing them "just for consistency"
    /// would defeat it.
    public func append(_ clippings: [Clipping]) {
        let records = clippings.filter { !$0.isConcealed }.map(Record.upsert)
        guard !records.isEmpty else { return }
        write(records)
    }

    /// Writes a tombstone and deletes the clipping's files.
    public func remove(id: UUID, assetFilename: String?) {
        write([.delete(id)])
        if let assetFilename { deleteAssets([assetFilename]) }
    }

    /// Writes tombstones for all of them in one append. With `keepAssets`, their
    /// files move to the trash so `restoreAssets` can bring them back.
    public func remove(_ clippings: [Clipping], keepAssets: Bool = false) {
        let stored = clippings.filter { !$0.isConcealed }
        if !stored.isEmpty { write(stored.map { .delete($0.id) }) }
        let files = clippings.flatMap { [$0.assetFilename, $0.richAssetFilename].compactMap { $0 } }
        guard !files.isEmpty else { return }
        if keepAssets {
            queue.async { [self] in
                try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
                for file in files {
                    try? FileManager.default.moveItem(at: assetURL(for: file), to: trashURL.appendingPathComponent(file))
                }
            }
        } else {
            deleteAssets(files)
        }
    }

    /// Moves a deleted clipping's files back from the trash.
    public func restoreAssets(of clipping: Clipping) {
        let files = [clipping.assetFilename, clipping.richAssetFilename].compactMap { $0 }
        guard !files.isEmpty else { return }
        queue.async { [self] in
            for file in files where !FileManager.default.fileExists(atPath: assetURL(for: file).path) {
                try? FileManager.default.moveItem(at: trashURL.appendingPathComponent(file), to: assetURL(for: file))
            }
        }
    }

    /// Deletes files on the archive queue, after every write queued before them.
    public func deleteAssets(_ filenames: [String]) {
        guard !filenames.isEmpty else { return }
        queue.async { [self] in
            for file in filenames {
                try? FileManager.default.removeItem(at: assetURL(for: file))
            }
        }
    }

    private func write(_ records: [Record]) {
        queue.async { [self] in
            var data = Data()
            for record in records {
                guard let line = try? encoder.encode(record) else { continue }
                data.append(line)
                data.append(0x0A)
            }
            guard !data.isEmpty else { return }
            appendToLog(data)
            writtenRecords += records.count
        }
    }

    /// A crash mid-write leaves a last line with no newline. Gluing the next
    /// record onto it would lose that record too, so the first append after a
    /// launch finishes the torn line first.
    private func appendToLog(_ data: Data) {
        guard let handle = try? FileHandle(forUpdating: logURL) else {
            try? data.write(to: logURL, options: .atomic)
            checkedTail = true
            return
        }
        defer { try? handle.close() }
        var data = data
        let end = (try? handle.seekToEnd()) ?? 0
        if !checkedTail {
            checkedTail = true
            if end > 0 {
                try? handle.seek(toOffset: end - 1)
                if let last = try? handle.read(upToCount: 1), last.first != 0x0A {
                    data.insert(0x0A, at: 0)
                }
                _ = try? handle.seekToEnd()
            }
        }
        try? handle.write(contentsOf: data)
    }

    /// Rewrites the log as one upsert per live clipping.
    ///
    /// Deliberately leaves the assets alone: a PNG written by a capture that
    /// is still on its way to the store is referenced by nothing yet, and an
    /// orphan sweep here used to delete it. Files go away when their clipping
    /// does, and at launch.
    public func compact(liveClippings: [Clipping]) {
        queue.async { [self] in
            var buffer = Data()
            var count = 0
            for clipping in liveClippings where !clipping.isConcealed {
                guard let line = try? encoder.encode(Record.upsert(clipping)) else { continue }
                buffer.append(line)
                buffer.append(0x0A)
                count += 1
            }
            try? buffer.write(to: logURL, options: .atomic)
            writtenRecords = count
            checkedTail = true
        }
    }

    /// True once the log holds meaningfully more records than live clippings.
    /// Waits for queued writes; the store keeps its own count instead of asking.
    public func needsCompaction(liveCount: Int) -> Bool {
        queue.sync { writtenRecords > max(256, liveCount * 2) }
    }

    /// Blocks until every queued write has landed.
    public func flush() {
        queue.sync {}
    }

    /// Writes a file into the assets directory, synchronously, from any thread.
    public func storeAsset(_ data: Data, filename: String) -> Bool {
        do {
            try data.write(to: assetURL(for: filename), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Files nothing references, left by a crash between writing an image and
    /// recording its clipping. Only files from before this launch are touched,
    /// so a capture already in flight keeps its image.
    private func sweepOrphans(keeping referenced: Set<String>, olderThan cutoff: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: assetsURL, includingPropertiesForKeys: keys
        )) ?? []
        for url in contents where !referenced.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantFuture
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
