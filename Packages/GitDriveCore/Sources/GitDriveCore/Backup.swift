import Foundation

/// What one backup run did.
public struct BackupResult: Sendable, Equatable {
    public var repo: String
    public var uploaded = 0
    public var deleted = 0
    public var unchanged = 0
    /// Files too large to store without Git LFS.
    public var skipped = 0
}

extension SyncEngine {
    /// Mirrors a Mac folder into a top-level GitDrive folder. Git history keeps every earlier version,
    /// so this is a versioned backup. Creates the target on first run (encrypted when a key exists).
    public func backup(
        _ folder: URL, into repo: String?, name: String, encrypt: Bool,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> BackupResult {
        try await syncRepoListIfStale(maxAge: 0)
        var target = repo.flatMap { try? store.repo(named: $0) }
        if target == nil {
            let created: ItemRecord
            if encrypt, identity() != nil {
                created = try await createVaultFolder(named: "Backup of \(name)")
            } else {
                created = try await createFolder(parentID: ItemStore.rootID, name: "Backup of \(name)")
            }
            target = try store.repo(named: created.repo)
        }
        guard let target else { throw DriveError.noSuchItem }
        try await syncRepo(target.name)

        var result = BackupResult(repo: target.name)
        let existing = Dictionary(
            (try store.items(inRepo: target.name)).filter { !$0.isDirectory && !$0.path.isEmpty }.map { ($0.path, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var seen = Set<String>()
        var edits: [Edit] = []
        var dates: [String: Date] = [:]
        var lfs: [String: LFSObject] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let base = folder.standardizedFileURL.path

        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            guard !path.isEmpty, !Reserved.isIgnored(filename: url.lastPathComponent) else { continue }
            seen.insert(path)
            let size = Int64(values.fileSize ?? 0)
            let modified = (values.contentModificationDate ?? Date()).wholeSeconds
            if let old = existing[path], old.size == size, old.modified.wholeSeconds == modified {
                result.unchanged += 1
                continue
            }
            do {
                let (sha, objects) = try await upload(url, to: target, name: url.lastPathComponent)
                edits.append(.put(path: path, sha: sha))
                dates[path] = modified
                lfs.merge(objects) { a, _ in a }
                result.uploaded += 1
                progress(result.uploaded)
            } catch DriveError.tooLarge {
                result.skipped += 1
            }
            if edits.count >= 200 {
                let batch = edits, batchDates = dates, batchLFS = lfs
                edits = []
                dates = [:]
                lfs = [:]
                try await commit(repo: target.name, edits: batch, claims: [:], dates: batchDates, lfs: batchLFS, message: "Backup")
            }
        }
        for path in existing.keys where !seen.contains(path) && !Reserved.isHidden(path: path) {
            edits.append(.delete(path: path))
            result.deleted += 1
        }
        if !edits.isEmpty {
            let batch = edits, batchDates = dates, batchLFS = lfs
            try await commit(repo: target.name, edits: batch, claims: [:], dates: batchDates, lfs: batchLFS, message: "Backup")
        }
        return result
    }
}
