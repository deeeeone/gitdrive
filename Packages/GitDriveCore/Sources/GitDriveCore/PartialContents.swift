import Foundation

extension SyncEngine {
    /// Smallest download for a partial read, so Quick Look's many small reads don't each hit the network.
    static let minimumPartialRead: Int64 = 1024 * 1024
    /// Files smaller than this are always downloaded whole.
    static let partialThreshold: Int64 = 4 * 1024 * 1024

    /// Fetches at least `offset..<offset+length` of a plain file into a sparse file, aligned to `alignment`.
    /// Returns nil when only a full download works: encrypted folders, LFS files and small files.
    public func partialContents(id: String, offset: Int64, length: Int64, alignment: Int64) async throws -> (url: URL, item: ItemRecord, offset: Int64, length: Int64)? {
        guard let item = try store.item(id: id), let rec = try store.repo(named: item.repo), let head = rec.head,
              !isVault(item.repo), currentMeta[item.repo]?.lfs[item.path] == nil, item.size >= Self.partialThreshold else { return nil }
        let align = max(alignment, 1)
        let start = (offset / align) * align
        let wanted = max(offset + length, start + Self.minimumPartialRead)
        let end = min(item.size, ((wanted + align - 1) / align) * align)
        guard start < end else { return nil }

        let (data, partial) = try await client.rawRange(owner: rec.owner, repo: rec.name, ref: head, path: item.path, range: start..<end)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if !partial {
            try data.write(to: url)
            return (url, item, 0, Int64(data.count))
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(end))
        try handle.seek(toOffset: UInt64(start))
        try handle.write(contentsOf: data)
        return (url, item, start, Int64(data.count))
    }
}
