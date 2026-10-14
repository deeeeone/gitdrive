import Foundation

/// One saved version of a file in the repo's git history.
public struct FileVersion: Identifiable, Sendable, Hashable {
    /// The commit that saved this version.
    public let id: String
    public let date: Date
    public let size: Int64
    /// Blob SHA for plain repos, content ID for encrypted ones.
    public let content: String
    public let isCurrent: Bool
}

extension SyncEngine {
    /// Earlier versions of a file, newest first. Each commit that changed the file is one version.
    public func versions(repo name: String, path: String, limit: Int = 30) async throws -> [FileVersion] {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        let current = try store.item(repo: name, path: path)?.sha
        var out: [FileVersion] = []
        if isVault(name) {
            // Every encrypted commit rewrites the index, so walk index snapshots and keep content changes.
            let commits = try await client.commits(owner: rec.owner, repo: name, path: Reserved.indexFile, limit: limit)
            var seen = Set<String>()
            for commit in commits {
                guard let snapshot = try? await vaultSnapshot(rec, commit: commit.sha),
                      let file = snapshot.index.files[path], seen.insert(file.c).inserted else { continue }
                out.append(FileVersion(id: commit.sha, date: commit.date, size: file.s, content: file.c, isCurrent: file.c == current))
            }
        } else {
            for commit in try await client.commits(owner: rec.owner, repo: name, path: path, limit: limit) {
                guard let file = try await client.fileAt(owner: rec.owner, repo: name, path: path, ref: commit.sha) else { continue }
                out.append(FileVersion(id: commit.sha, date: commit.date, size: file.size, content: file.sha, isCurrent: file.sha == current))
            }
        }
        return out
    }

    /// A version's contents in a temporary file.
    public func contents(of version: FileVersion, repo name: String) async throws -> URL {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        if isVault(name) {
            let snapshot = try await vaultSnapshot(rec, commit: version.id)
            return try await readContent(rec, sha: version.content, state: snapshot)
        }
        return try await client.downloadContents(owner: rec.owner, repo: name, sha: version.content)
    }

    /// Makes `version` the current contents of `path`, as a new commit. Works for deleted files too.
    public func restore(_ version: FileVersion, repo name: String, path: String) async throws {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        try await syncRepo(name)
        if isVault(name) {
            let url = try await contents(of: version, repo: name)
            defer { try? FileManager.default.removeItem(at: url) }
            let content = try stage(url, in: name)
            try await commit(repo: name, edits: [.put(path: path, sha: content)], claims: [:], dates: [path: Date()], message: "Update")
        } else {
            // The old blob is still in the repo, so nothing is uploaded. LFS pointers keep pointing at their object.
            var lfs: [String: LFSObject] = [:]
            if version.size < 1024, let data = try? await client.blobData(owner: rec.owner, repo: name, sha: version.content),
               let object = LFSObject.parse(pointer: data) {
                lfs[version.content] = object
            }
            try await commit(
                repo: name, edits: [.put(path: path, sha: version.content)], claims: [:],
                dates: [path: Date()], lfs: lfs, message: "Restore \(path)"
            )
        }
    }

    /// An encrypted folder as it was at `commit`: that commit's index and packs, opened with today's key.
    func vaultSnapshot(_ rec: RepoRecord, commit: String) async throws -> VaultState {
        guard let state = vaults[rec.name] else { throw VaultError.locked }
        let tree = try await client.treeSHA(owner: rec.owner, repo: rec.name, commit: commit)
        let entries = try await client.fullTree(owner: rec.owner, repo: rec.name, sha: tree)
        var snapshot = state
        snapshot.packBlobs = [:]
        for entry in entries where entry.type == .blob && entry.path.hasPrefix("p/") {
            snapshot.packBlobs[String(entry.path.split(separator: "/").last ?? "")] = entry.sha
        }
        guard let indexEntry = entries.first(where: { $0.path == Reserved.indexFile }) else { throw VaultError.corrupt("no index") }
        if indexEntry.sha != state.indexSHA {
            let sealed = try await client.blobData(owner: rec.owner, repo: rec.name, sha: indexEntry.sha)
            snapshot.index = try VaultIndex.decode(try state.key.openIndex(sealed))
            snapshot.indexSHA = indexEntry.sha
        }
        return snapshot
    }
}

/// A file removed in the last few weeks that can still be restored from history.
public struct DeletedFile: Identifiable, Sendable, Hashable {
    public var id: String { "\(repo):\(path):\(version.id)" }
    public let repo: String
    /// Top-level folder name shown to the user.
    public let folder: String
    public let path: String
    public let deletedAt: Date
    /// The last version before the delete.
    public let version: FileVersion
}

extension SyncEngine {
    /// Files deleted in the last `days` days, newest first. Files that exist again are left out.
    public func recentlyDeleted(days: Int = 30, repo only: String? = nil, commitLimit: Int = 30) async throws -> [DeletedFile] {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var out: [DeletedFile] = []
        for rec in try store.repos() where only == nil || rec.name == only {
            let folder = (try? store.item(repo: rec.name, path: "")?.filename) ?? rec.name
            let commits = (try? await client.commits(
                owner: rec.owner, repo: rec.name, path: isVault(rec.name) ? Reserved.indexFile : nil, since: since, limit: commitLimit
            )) ?? []
            if isVault(rec.name) {
                // Compare each index snapshot with the one before it.
                var newer: (commit: GitHubClient.CommitSummary, index: VaultIndex)?
                let chain = commits + (commits.last?.parents.first.map { [GitHubClient.CommitSummary(sha: $0, message: "", date: .distantPast, parents: [])] } ?? [])
                for commit in chain {
                    guard let snapshot = try? await vaultSnapshot(rec, commit: commit.sha) else { continue }
                    if let newer {
                        for (path, file) in snapshot.index.files where newer.index.files[path] == nil && !Reserved.isHidden(path: path) {
                            out.append(DeletedFile(
                                repo: rec.name, folder: folder, path: path, deletedAt: newer.commit.date,
                                version: FileVersion(id: commit.sha, date: Date(timeIntervalSince1970: file.m), size: file.s, content: file.c, isCurrent: false)
                            ))
                        }
                    }
                    newer = (commit, snapshot.index)
                }
            } else {
                for commit in commits {
                    guard let parent = commit.parents.first,
                          let files = try? await client.changedFiles(owner: rec.owner, repo: rec.name, commit: commit.sha) else { continue }
                    for file in files where file.status == "removed" && !Reserved.isHidden(path: file.filename) {
                        guard let old = try await client.fileAt(owner: rec.owner, repo: rec.name, path: file.filename, ref: parent) else { continue }
                        out.append(DeletedFile(
                            repo: rec.name, folder: folder, path: file.filename, deletedAt: commit.date,
                            version: FileVersion(id: parent, date: commit.date, size: old.size, content: old.sha, isCurrent: false)
                        ))
                    }
                }
            }
        }
        // Keep the most recent delete of each path, and only paths that are still gone.
        var latest: [String: DeletedFile] = [:]
        for file in out where try store.item(repo: file.repo, path: file.path) == nil {
            let key = "\(file.repo):\(file.path)"
            if latest[key].map({ $0.deletedAt < file.deletedAt }) ?? true { latest[key] = file }
        }
        return latest.values.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(_ deleted: DeletedFile) async throws {
        try await restore(deleted.version, repo: deleted.repo, path: deleted.path)
    }
}
