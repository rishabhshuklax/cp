import Foundation

/// On-disk persistence: an append-only JSONL log plus a directory of binary assets.
///
/// Not a database, on purpose. A clipboard manager sees a few hundred copies a day
/// against a capped history, which is small enough to hold entirely in memory and
/// scan linearly — the search is bounded by rendering, not by lookup. What an
/// append-only log buys instead is that a copy costs one `write(2)` on a background
/// queue and a crash can lose at most the last line. Compaction rewrites the file
/// once it accumulates more tombstones than live records.
///
/// If history ever needs to outgrow memory, this is the seam to swap for SQLite:
/// `load()` and `append(_:)` are the entire contract.
public final class ClippingArchive: @unchecked Sendable {

    public enum ArchiveError: Error {
        case directoryUnavailable
    }

    private enum Record: Codable {
        case upsert(Clipping)
        case delete(UUID)
    }

    private let directory: URL
    private let logURL: URL
    private let assetsURL: URL
    private let queue = DispatchQueue(label: "dev.cp.archive", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Records written since the last compaction, live or tombstone.
    private var writtenRecords = 0

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

        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public var assetsDirectory: URL { assetsURL }

    public func assetURL(for filename: String) -> URL {
        assetsURL.appendingPathComponent(filename)
    }

    // MARK: - Reading

    /// Replays the log into the last-writer-wins state it represents.
    /// Malformed lines are skipped rather than aborting the load: a truncated final
    /// line after a hard crash should cost one clipping, not the whole history.
    public func load() -> [Clipping] {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var byID: [UUID: Clipping] = [:]
        var order: [UUID] = []
        var records = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: lineData) else { continue }
            records += 1

            switch record {
            case .upsert(let clipping):
                if byID[clipping.id] == nil { order.append(clipping.id) }
                byID[clipping.id] = clipping
            case .delete(let id):
                byID[id] = nil
            }
        }

        queue.async { [weak self] in self?.writtenRecords = records }
        return order.compactMap { byID[$0] }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    // MARK: - Writing

    public func append(_ clipping: Clipping) {
        // Concealed clippings live for the session and never touch disk. That is the
        // whole point of the concealed flag; writing them "just for consistency"
        // would defeat it.
        guard !clipping.isConcealed else { return }
        write(.upsert(clipping))
    }

    public func remove(id: UUID, assetFilename: String?) {
        if let assetFilename {
            let url = assetURL(for: assetFilename)
            queue.async { try? FileManager.default.removeItem(at: url) }
        }
        write(.delete(id))
    }

    private func write(_ record: Record) {
        queue.async { [self] in
            guard var data = try? encoder.encode(record) else { return }
            data.append(0x0A)  // newline

            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
            writtenRecords += 1
        }
    }

    /// Rewrites the log as one upsert per live clipping and deletes orphaned assets.
    /// Call after trimming to the history cap.
    public func compact(liveClippings: [Clipping]) {
        queue.async { [self] in
            var buffer = Data()
            for clipping in liveClippings where !clipping.isConcealed {
                guard var data = try? encoder.encode(Record.upsert(clipping)) else { continue }
                data.append(0x0A)
                buffer.append(data)
            }
            try? buffer.write(to: logURL, options: .atomic)
            writtenRecords = liveClippings.count

            let referenced = Set(liveClippings.compactMap(\.assetFilename))
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: assetsURL, includingPropertiesForKeys: nil
            )) ?? []
            for url in contents where !referenced.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// True once the log holds meaningfully more records than live clippings.
    public func needsCompaction(liveCount: Int) -> Bool {
        queue.sync { writtenRecords > max(256, liveCount * 2) }
    }

    public func storeAsset(_ data: Data, filename: String) -> Bool {
        let url = assetURL(for: filename)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
