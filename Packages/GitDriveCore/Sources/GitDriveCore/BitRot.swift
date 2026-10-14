import CryptoKit
import Foundation

public struct BitRotReport: Sendable, Equatable {
    public var checked = 0
    /// Files not downloaded to this Mac, so there's nothing local to check.
    public var skipped = 0
    /// Local files whose contents no longer match what's stored on GitHub.
    public var damaged: [URL] = []

    public init() {}
}

extension SyncEngine {
    /// Hashes downloaded files under the drive's root folder and compares them with git's record.
    /// Files that aren't downloaded are skipped unless `requireDownloaded` is false (used by tests).
    public func checkForBitRot(root: URL, requireDownloaded: Bool = true) async -> BitRotReport {
        var report = BitRotReport()
        guard let items = try? store.allItems() else { return report }
        let folders = Dictionary(items.filter { $0.path.isEmpty }.map { ($0.repo, $0.filename) }, uniquingKeysWith: { a, _ in a })
        for item in items where !item.isDirectory && !item.path.isEmpty {
            guard let folder = folders[item.repo], let expected = item.sha else { continue }
            let url = root.appendingPathComponent(folder).appendingPathComponent(item.path)
            if requireDownloaded {
                let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
                guard status == .current else { report.skipped += 1; continue }
            }
            guard FileManager.default.fileExists(atPath: url.path), let matches = try? fileMatches(url, item: item, expected: expected) else {
                report.skipped += 1
                continue
            }
            report.checked += 1
            if !matches { report.damaged.append(url) }
        }
        return report
    }

    private func fileMatches(_ url: URL, item: ItemRecord, expected: String) throws -> Bool {
        if let state = vaults[item.repo] {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let ids = state.key.chunker.chunks(of: data).map { state.key.chunkID(data.subdata(in: $0)) }
            return VaultIndex.contentID(chunks: ids, size: Int64(data.count)) == expected
        }
        if let object = currentMeta[item.repo]?.lfs[item.path] {
            return try GitHubClient.lfsObject(for: url).oid == object.oid
        }
        return try Self.gitBlobSHA(of: url) == expected
    }

    /// Git's object name for a file: SHA-1 of "blob <size>\0" followed by the contents.
    static func gitBlobSHA(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
