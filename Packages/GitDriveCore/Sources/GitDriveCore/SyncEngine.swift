import Foundation
import os

public enum DriveError: Error, Sendable, Equatable, CustomStringConvertible {
    case noSuchItem
    case filenameCollision
    case filesNotAllowedInRoot
    case unsupportedMove(String)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .noSuchItem: "The item no longer exists"
        case .filenameCollision: "An item with that name already exists"
        case .filesNotAllowedInRoot: "Put files inside a folder. Each top-level folder is its own GitHub repo."
        case let .unsupportedMove(why): why
        case let .tooLarge(name): "\(name) is larger than GitHub's 100 MB file limit. Turn on Git LFS in GitDrive Settings to store it."
        }
    }
}

/// What happens on GitHub when a top-level folder is deleted in Finder.
public enum RepoDeletion: String, Sendable, CaseIterable {
    /// Deletes the repo permanently. Needs a token with the `delete_repo` scope.
    case delete
    /// Archives the repo so it can be restored from GitHub.
    case archive
}

/// A path-level edit. Folder edits are expanded against the real remote tree at commit time,
/// so hidden placeholder files move and delete along with their folders.
public enum Edit: Sendable, Equatable {
    case put(path: String, sha: String, mode: String = "100644", baseSHA: String? = nil)
    case delete(path: String)
    case deleteFolder(path: String)
    case moveFolder(from: String, to: String)
}

/// Keeps the local index in step with GitHub and turns local edits into commits.
public actor SyncEngine {
    public nonisolated let client: GitHubClient
    public nonisolated let store: ItemStore
    let log = Logger(subsystem: "com.diwan.gitdrive", category: "sync")
    let locks = KeyedLock()
    var lastRepoList: Date?
    var emptyBlobs: [String: String] = [:]
    /// Parsed meta files by blob SHA. Blobs never change, so entries never go stale.
    var metaCache: [String: DriveMeta] = [:]
    /// Each plain repo's meta file as of its last refresh.
    var currentMeta: [String: DriveMeta] = [:]

    let repoDeletion: @Sendable () -> RepoDeletion
    let lfsThreshold: @Sendable () -> Int64?
    let identity: @Sendable () -> VaultIdentity?
    let encryptNewFolders: @Sendable () -> Bool

    // Encrypted folders. See SyncEngine+Vault.swift.
    var vaults: [String: VaultState] = [:]
    var lockedRepos: Set<String> = []
    var stagedFiles: [String: [String: StagedFile]] = [:]
    var stagedChunks: [String: [String: URL]] = [:]
    var packCache = PackCache()

    /// Settings are closures read at use time, so changes apply right away.
    /// `lfsThreshold` is the size in bytes above which files go to Git LFS, or nil to never use LFS.
    public init(
        client: GitHubClient,
        store: ItemStore,
        repoDeletion: @escaping @Sendable () -> RepoDeletion = { .archive },
        lfsThreshold: @escaping @Sendable () -> Int64? = { nil },
        identity: @escaping @Sendable () -> VaultIdentity? = { nil },
        encryptNewFolders: @escaping @Sendable () -> Bool = { false }
    ) {
        self.client = client
        self.store = store
        self.repoDeletion = repoDeletion
        self.lfsThreshold = lfsThreshold
        self.identity = identity
        self.encryptNewFolders = encryptNewFolders
    }

    // MARK: Remote to local

    /// Refreshes the repo list and every repo whose head moved.
    public func syncAll() async throws {
        let remote = try await client.driveRepos()
        try reconcileRepos(remote)
        lastRepoList = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for repo in remote {
                group.addTask { try await self.syncRepo(repo.name) }
            }
            try await group.waitForAll()
        }
    }

    /// Lists repos only if the last listing is older than `maxAge`.
    public func syncRepoListIfStale(maxAge: TimeInterval = 30) async throws {
        if let lastRepoList, Date().timeIntervalSince(lastRepoList) < maxAge, try !store.repos().isEmpty { return }
        let remote = try await client.driveRepos()
        try reconcileRepos(remote)
        lastRepoList = Date()
    }

    public func syncRepo(_ name: String) async throws {
        try await locks.withLock(name) { try await self.refresh(name) }
    }

    func reconcileRepos(_ remote: [Repo]) throws {
        try store.write { w in
            for repo in remote {
                let existing = try w.item(repo: repo.name, path: "")
                let old = try w.repo(named: repo.name)
                try w.saveRepo(RepoRecord(
                    name: repo.name,
                    owner: repo.owner.login,
                    branch: repo.defaultBranch ?? "main",
                    head: old?.head,
                    sizeKB: repo.size
                ))
                if existing == nil {
                    try w.upsert(ItemRecord(
                        id: UUID().uuidString, repo: repo.name, path: "", parentID: ItemStore.rootID,
                        isDirectory: true, sha: nil, size: 0, modified: Date(), seq: 0
                    ))
                }
            }
            let names = Set(remote.map(\.name))
            for gone in try w.repos().map(\.name) where !names.contains(gone) {
                for item in try w.items(inRepo: gone) { try w.delete(item) }
                try w.deleteRepo(named: gone)
            }
        }
    }

    /// Fetches the remote tree if the head moved and applies it. Caller holds the repo lock.
    func refresh(_ name: String, knownHead: (commit: String, tree: String)? = nil, claims: [String: String] = [:]) async throws {
        guard let rec = try store.repo(named: name) else { return }
        let head: String
        let treeSHA: String
        var commitDate = Date()
        if let knownHead {
            (head, treeSHA) = knownHead
        } else {
            do {
                head = try await client.headSHA(owner: rec.owner, repo: name, branch: rec.branch)
            } catch let e as GitHubError where e.kind == .emptyRepo {
                try apply(repo: rec, head: nil, entries: [], claims: claims)
                return
            }
            if head == rec.head, claims.isEmpty { return }
            let info = try await client.commitInfo(owner: rec.owner, repo: name, commit: head)
            treeSHA = info.tree
            if let date = info.date { commitDate = date }
        }
        let entries = try await client.fullTree(owner: rec.owner, repo: name, sha: treeSHA)
        if entries.contains(where: { $0.path == Reserved.vaultFile }) {
            try await refreshVault(rec, head: head, entries: entries, claims: claims, commitDate: commitDate)
            return
        }
        vaults[name] = nil
        lockedRepos.remove(name)
        let meta = await loadMeta(rec, entries: entries)
        currentMeta[name] = meta
        try apply(repo: rec, head: head, entries: entries, claims: claims, meta: meta, fallbackDate: commitDate)
    }

    /// Reads `.gitdrive/meta.json` from a tree. A missing or unreadable file just means no stored dates.
    func loadMeta(_ rec: RepoRecord, entries: [TreeEntry]) async -> DriveMeta {
        guard let entry = entries.first(where: { $0.path == Reserved.metaFile && $0.type == .blob }) else { return DriveMeta() }
        if let cached = metaCache[entry.sha] { return cached }
        guard let data = try? await client.blobData(owner: rec.owner, repo: rec.name, sha: entry.sha) else { return DriveMeta() }
        let meta = DriveMeta.decode(data)
        metaCache[entry.sha] = meta
        return meta
    }

    /// Makes the store match `entries`. `claims` maps a path to the item ID that should own it,
    /// which is how renames, moves and new local items keep their IDs.
    /// Dates come from the meta file. Files it doesn't list (added outside GitDrive) get `fallbackDate`,
    /// the commit date, when their contents change.
    func apply(
        repo rec: RepoRecord, head: String?, entries: [TreeEntry], claims: [String: String],
        meta: DriveMeta = DriveMeta(), fallbackDate: Date = Date(), displayName: String? = nil
    ) throws {
        struct Remote { let isDirectory: Bool; let sha: String?; let size: Int64 }
        var remote: [String: Remote] = [:]
        for e in entries {
            switch e.type {
            case .commit:
                continue
            case .tree:
                if !Reserved.isHidden(path: e.path) { remote[e.path] = Remote(isDirectory: true, sha: nil, size: 0) }
            case .blob:
                if !Reserved.isHidden(path: e.path) {
                    remote[e.path] = Remote(isDirectory: false, sha: e.sha, size: meta.lfs[e.path]?.size ?? e.size ?? 0)
                }
            }
        }
        let now = fallbackDate

        try store.write { w in
            guard var root = try w.item(repo: rec.name, path: "") else { return }
            if root.displayName != displayName {
                root.displayName = displayName
                try w.upsert(root)
            }
            let claimedIDs = Set(claims.values)

            // Ordered by depth so parents always exist before their children.
            let paths = remote.keys.sorted {
                let (a, b) = ($0.split(separator: "/").count, $1.split(separator: "/").count)
                return a == b ? $0 < $1 : a < b
            }
            for path in paths {
                let r = remote[path]!
                let parent = parentPath(of: path)
                let parentID = parent.isEmpty ? root.id : (try w.item(repo: rec.name, path: parent)?.id ?? root.id)
                let atPath = try w.item(repo: rec.name, path: path)

                if let claimedID = claims[path], var item = try w.item(id: claimedID) {
                    if let atPath, atPath.id != claimedID, !claimedIDs.contains(atPath.id) {
                        try w.delete(atPath)
                    }
                    if let date = meta.modified[path] { item.modified = date } else if item.sha != r.sha { item.modified = now }
                    item.repo = rec.name
                    item.path = path
                    item.parentID = parentID
                    item.isDirectory = r.isDirectory
                    item.sha = r.sha
                    item.size = r.size
                    try w.upsert(item)
                } else if var item = atPath, !claimedIDs.contains(item.id) {
                    let modified = meta.modified[path] ?? (item.sha != r.sha ? now : item.modified)
                    guard item.sha != r.sha || item.isDirectory != r.isDirectory || item.parentID != parentID
                        || item.size != r.size || item.modified != modified else { continue }
                    item.modified = modified
                    item.sha = r.sha
                    item.size = r.size
                    item.isDirectory = r.isDirectory
                    item.parentID = parentID
                    try w.upsert(item)
                } else {
                    // A claim for an ID the store doesn't have yet is a brand new local item.
                    if let atPath, claims[path] != nil { try w.delete(atPath) }
                    try w.upsert(ItemRecord(
                        id: claims[path] ?? UUID().uuidString, repo: rec.name, path: path, parentID: parentID,
                        isDirectory: r.isDirectory, sha: r.sha, size: r.size, modified: meta.modified[path] ?? now, seq: 0
                    ))
                }
            }

            for item in try w.items(inRepo: rec.name) where !item.path.isEmpty && remote[item.path] == nil {
                try w.delete(item)
            }

            var updated = rec
            updated.head = head
            if let current = try w.repo(named: rec.name) { updated.sizeKB = current.sizeKB }
            try w.saveRepo(updated)
        }
    }

    // MARK: Local to remote

    public func download(id: String) async throws -> (URL, ItemRecord) {
        guard let item = try store.item(id: id), let sha = item.sha, let rec = try store.repo(named: item.repo) else {
            throw DriveError.noSuchItem
        }
        return (try await readContent(rec, sha: sha), item)
    }

    public func createFolder(parentID: String, name: String) async throws -> ItemRecord {
        if parentID == ItemStore.rootID {
            if try store.children(of: ItemStore.rootID).contains(where: { $0.filename == name }) { throw DriveError.filenameCollision }
            if encryptNewFolders() { return try await createVaultFolder(named: name) }
            if try store.repo(named: Reserved.repoPrefix + name) != nil { throw DriveError.filenameCollision }
            let repo = try await client.createDriveRepo(folderName: name)
            try reconcileRepos(try await client.driveRepos())
            try await syncRepo(repo.name)
            guard let item = try store.item(repo: repo.name, path: "") else { throw DriveError.noSuchItem }
            return item
        }
        let (repo, dir) = try location(of: parentID)
        let path = joinPath(dir, name)
        if try store.item(repo: repo.name, path: path) != nil { throw DriveError.filenameCollision }
        let id = UUID().uuidString
        let keep = try await emptyBlob(in: repo)
        try await commit(
            repo: repo.name,
            edits: [.put(path: joinPath(path, Reserved.keepFile), sha: keep)],
            claims: [path: id],
            message: "Add folder \(path)"
        )
        guard let item = try store.item(id: id) else { throw DriveError.noSuchItem }
        return item
    }

    public func createFile(parentID: String, name: String, contents: URL, modified: Date? = nil) async throws -> ItemRecord {
        if parentID == ItemStore.rootID { throw DriveError.filesNotAllowedInRoot }
        let (repo, dir) = try location(of: parentID)
        let path = joinPath(dir, name)
        if let existing = try store.item(repo: repo.name, path: path) {
            // The system re-creates items it already knows after a reimport. Treat that as an edit.
            return try await modify(id: existing.id, newName: nil, newParentID: nil, contents: contents, modified: modified)
        }
        let (sha, lfs) = try await upload(contents, to: repo, name: name)
        let id = UUID().uuidString
        try await commit(
            repo: repo.name, edits: [.put(path: path, sha: sha)], claims: [path: id],
            dates: [path: modified ?? Date()], lfs: lfs, message: "Add \(path)"
        )
        guard let item = try store.item(id: id) else { throw DriveError.noSuchItem }
        return item
    }

    /// Applies a rename, a move, new contents, or any mix of them.
    public func modify(id: String, newName: String?, newParentID: String?, contents: URL?, modified: Date? = nil) async throws -> ItemRecord {
        guard let item = try store.item(id: id), let repo = try store.repo(named: item.repo) else { throw DriveError.noSuchItem }

        if item.path.isEmpty {
            return try await modifyRepoFolder(item, repo: repo, newName: newName, newParentID: newParentID)
        }

        let targetParentID = newParentID ?? item.parentID
        if targetParentID == ItemStore.rootID { throw DriveError.filesNotAllowedInRoot }
        let (targetRepo, targetDir) = try location(of: targetParentID)
        let targetPath = joinPath(targetDir, newName ?? item.filename)

        if targetRepo.name != item.repo {
            return try await moveAcrossRepos(
                item, from: repo, to: targetRepo, path: targetPath, contents: contents, modified: modified ?? item.modified
            )
        }

        var edits: [Edit] = []
        var claims: [String: String] = [:]
        var dates: [String: Date] = [:]
        var lfs: [String: LFSObject] = [:]
        let moved = targetPath != item.path
        if moved, try store.item(repo: repo.name, path: targetPath) != nil { throw DriveError.filenameCollision }

        if item.isDirectory {
            guard moved else { return item }
            if targetPath.hasPrefix(item.path + "/") { throw DriveError.unsupportedMove("A folder can't be moved inside itself") }
            edits.append(.moveFolder(from: item.path, to: targetPath))
            claims[targetPath] = item.id
            for child in try store.descendants(of: item) {
                claims[targetPath + child.path.dropFirst(item.path.count)] = child.id
            }
        } else {
            var sha = item.sha ?? ""
            if let contents { (sha, lfs) = try await upload(contents, to: repo, name: item.filename) }
            if moved { edits.append(.delete(path: item.path)) }
            edits.append(.put(path: targetPath, sha: sha, baseSHA: contents == nil ? nil : item.sha))
            claims[targetPath] = item.id
            dates[targetPath] = modified ?? (contents == nil ? item.modified : Date())
            if !moved, contents == nil { return item }
        }

        let verb = moved ? "Move \(item.path) to \(targetPath)" : "Update \(item.path)"
        try await commit(repo: repo.name, edits: edits, claims: claims, dates: dates, lfs: lfs, message: verb)
        guard let updated = try store.item(id: id) else { throw DriveError.noSuchItem }
        return updated
    }

    public func delete(id: String) async throws {
        guard let item = try store.item(id: id), let repo = try store.repo(named: item.repo) else { return }
        if item.path.isEmpty {
            switch repoDeletion() {
            case .delete:
                log.notice("Deleting repo \(repo.name, privacy: .public)")
                try await client.deleteRepo(owner: repo.owner, name: repo.name)
            case .archive:
                try await client.archiveRepo(owner: repo.owner, name: repo.name)
            }
            try reconcileRepos(try await client.driveRepos())
            return
        }
        let edit: Edit = item.isDirectory ? .deleteFolder(path: item.path) : .delete(path: item.path)
        try await commit(repo: repo.name, edits: [edit], claims: [:], message: "Delete \(item.path)")
    }

    func modifyRepoFolder(_ item: ItemRecord, repo: RepoRecord, newName: String?, newParentID: String?) async throws -> ItemRecord {
        if let newParentID, newParentID != ItemStore.rootID {
            throw DriveError.unsupportedMove("Top-level folders are GitHub repos and must stay at the top level")
        }
        guard let newName, newName != item.filename else { return item }
        if isVault(repo.name) {
            try await renameVault(repo.name, to: newName)
            guard let updated = try store.item(id: item.id) else { throw DriveError.noSuchItem }
            return updated
        }
        let newRepoName = Reserved.repoPrefix + newName
        if try store.repo(named: newRepoName) != nil { throw DriveError.filenameCollision }
        _ = try await client.renameRepo(owner: repo.owner, name: repo.name, to: newRepoName)
        try store.write { try $0.renameRepo(repo.name, to: newRepoName) }
        guard let updated = try store.item(id: item.id) else { throw DriveError.noSuchItem }
        return updated
    }

    func moveAcrossRepos(
        _ item: ItemRecord, from: RepoRecord, to: RepoRecord, path: String, contents: URL?, modified: Date
    ) async throws -> ItemRecord {
        if item.isDirectory {
            return try await moveFolderAcrossRepos(item, from: from, to: to, path: path)
        }
        let source: URL
        if let contents {
            source = contents
        } else {
            source = try await readContent(from, sha: item.sha ?? "")
        }
        if try store.item(repo: to.name, path: path) != nil { throw DriveError.filenameCollision }
        let (sha, lfs) = try await upload(source, to: to, name: item.filename)
        try await commit(
            repo: to.name, edits: [.put(path: path, sha: sha)], claims: [path: item.id],
            dates: [path: modified], lfs: lfs, message: "Add \(path)"
        )
        try await commit(repo: from.name, edits: [.delete(path: item.path)], claims: [:], message: "Move \(item.path) to \(to.name)")
        guard let updated = try store.item(id: item.id) else { throw DriveError.noSuchItem }
        return updated
    }

    /// Copies every file under a folder into another repo, commits there, and only then deletes the
    /// folder from the source repo. A failure before the delete leaves the original untouched.
    func moveFolderAcrossRepos(_ item: ItemRecord, from: RepoRecord, to: RepoRecord, path targetPath: String) async throws -> ItemRecord {
        if try store.item(repo: to.name, path: targetPath) != nil { throw DriveError.filenameCollision }

        let (entries, meta) = try await listing(of: from)
        let blobs = entries.filter { $0.type == .blob && $0.path.hasPrefix(item.path + "/") }

        // Blobs belong to one repo, so each file is downloaded and uploaded again. Four at a time.
        var edits: [Edit] = []
        var dates: [String: Date] = [:]
        var lfs: [String: LFSObject] = [:]
        for start in stride(from: 0, to: blobs.count, by: 4) {
            let chunk = blobs[start..<min(start + 4, blobs.count)]
            let copied = try await withThrowingTaskGroup(of: (TreeEntry, String, [String: LFSObject]).self) { group in
                for blob in chunk {
                    group.addTask {
                        let file = try await self.readContent(from, sha: blob.sha)
                        defer { try? FileManager.default.removeItem(at: file) }
                        let (sha, lfs) = try await self.upload(file, to: to, name: blob.path)
                        return (blob, sha, lfs)
                    }
                }
                var results: [(TreeEntry, String, [String: LFSObject])] = []
                for try await result in group { results.append(result) }
                return results
            }
            for (blob, sha, objects) in copied {
                lfs.merge(objects) { a, _ in a }
                let newPath = targetPath + blob.path.dropFirst(item.path.count)
                edits.append(.put(path: newPath, sha: sha, mode: blob.mode))
                if let date = meta.modified[blob.path] { dates[newPath] = date }
            }
        }
        if edits.isEmpty {
            edits.append(.put(path: joinPath(targetPath, Reserved.keepFile), sha: try await emptyBlob(in: to)))
        }

        var claims = [targetPath: item.id]
        for child in try store.descendants(of: item) {
            claims[targetPath + child.path.dropFirst(item.path.count)] = child.id
        }
        try await commit(repo: to.name, edits: edits, claims: claims, dates: dates, lfs: lfs, message: "Add \(targetPath) from \(from.name)")
        try await commit(repo: from.name, edits: [.deleteFolder(path: item.path)], claims: [:], message: "Move \(item.path) to \(to.name)")
        guard let moved = try store.item(id: item.id) else { throw DriveError.noSuchItem }
        return moved
    }

    // MARK: Commits

    struct PendingCommit {
        let edits: [Edit]
        let claims: [String: String]
        let dates: [String: Date]
        /// Pointer blob SHA to the LFS object it points at, for files uploaded in this commit.
        let lfs: [String: LFSObject]
        let message: String
        let continuation: CheckedContinuation<Void, Error>
    }

    var pending: [String: [PendingCommit]] = [:]
    var draining: Set<String> = []

    /// Queues edits for a repo. Edits that arrive while a commit is in flight are batched into the next one.
    func commit(
        repo: String, edits: [Edit], claims: [String: String], dates: [String: Date] = [:],
        lfs: [String: LFSObject] = [:], message: String
    ) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending[repo, default: []].append(
                PendingCommit(edits: edits, claims: claims, dates: dates, lfs: lfs, message: message, continuation: c)
            )
            if !draining.contains(repo) {
                draining.insert(repo)
                Task { await self.drain(repo) }
            }
        }
    }

    func drain(_ repo: String) async {
        while let batch = pending[repo], !batch.isEmpty {
            pending[repo] = []
            do {
                try await locks.withLock(repo) { try await self.performCommit(repo: repo, batch: batch) }
                batch.forEach { $0.continuation.resume() }
            } catch {
                log.error("Commit to \(repo, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                batch.forEach { $0.continuation.resume(throwing: error) }
            }
        }
        draining.remove(repo)
    }

    /// Builds one commit from a batch and fast-forwards the branch. Retries on top of new remote commits.
    func performCommit(repo name: String, batch: [PendingCommit]) async throws {
        if isVault(name) {
            try await performVaultCommit(repo: name, batch: batch)
            return
        }
        for attempt in 1...3 {
            guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
            let head = try await client.headSHA(owner: rec.owner, repo: name, branch: rec.branch)
            if head != rec.head { try await refresh(name) }
            let baseTree = try await client.treeSHA(owner: rec.owner, repo: name, commit: head)
            let remoteEntries = try await client.fullTree(owner: rec.owner, repo: name, sha: baseTree)

            var claims: [String: String] = [:]
            var dates: [String: Date] = [:]
            var newLFS: [String: LFSObject] = [:]
            for p in batch {
                claims.merge(p.claims) { _, new in new }
                dates.merge(p.dates) { _, new in new }
                newLFS.merge(p.lfs) { _, new in new }
            }
            let oldMeta = await loadMeta(rec, entries: remoteEntries)
            var changes = try expand(
                batch.flatMap(\.edits), remote: remoteEntries, repo: name, claims: &claims, dates: &dates, meta: oldMeta
            )
            if changes.isEmpty { return }

            // LFS objects are tracked by pointer blob SHA, so they follow renames, moves and conflict copies.
            var lfsBySHA = newLFS
            let remoteSHA = Dictionary(remoteEntries.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
            for (path, object) in oldMeta.lfs { if let sha = remoteSHA[path] { lfsBySHA[sha] = lfsBySHA[sha] ?? object } }

            var meta = oldMeta
            for change in changes {
                guard let sha = change.sha else {
                    meta.modified[change.path] = nil
                    meta.lfs[change.path] = nil
                    continue
                }
                if let date = dates[change.path] { meta.modified[change.path] = date.wholeSeconds }
                meta.lfs[change.path] = lfsBySHA[sha]
            }
            if Set(meta.lfs.keys) != Set(oldMeta.lfs.keys) {
                var existing = ""
                if let entry = remoteEntries.first(where: { $0.path == Reserved.attributesFile && $0.type == .blob }),
                   let data = try? await client.blobData(owner: rec.owner, repo: name, sha: entry.sha) {
                    existing = String(decoding: data, as: UTF8.self)
                }
                let updated = GitAttributes.update(existing, lfsPaths: Array(meta.lfs.keys))
                if updated.isEmpty {
                    if remoteSHA[Reserved.attributesFile] != nil { changes.append(TreeChange(path: Reserved.attributesFile, sha: nil)) }
                } else {
                    let blob = try await client.createBlob(owner: rec.owner, repo: name, data: Data(updated.utf8))
                    changes.append(TreeChange(path: Reserved.attributesFile, sha: blob))
                }
            }
            if meta != oldMeta {
                let blob = try await client.createBlob(owner: rec.owner, repo: name, data: try meta.encoded())
                metaCache[blob] = meta
                changes.append(TreeChange(path: Reserved.metaFile, sha: blob))
            }

            let message = batch.count == 1 ? batch[0].message : "Update \(batch.count) items from GitDrive"
            let tree = try await client.createTree(owner: rec.owner, repo: name, base: baseTree, changes: changes)
            let commit = try await client.createCommit(owner: rec.owner, repo: name, message: message, tree: tree, parents: [head])
            do {
                try await client.updateRef(owner: rec.owner, repo: name, branch: rec.branch, sha: commit)
            } catch let e as GitHubError where e.kind == .conflict && attempt < 3 {
                log.notice("\(name, privacy: .public) moved during commit, retrying (\(attempt))")
                continue
            }
            try await refresh(name, knownHead: (commit, tree), claims: claims)
            return
        }
    }

    /// Turns edits into tree changes. A `put` whose base no longer matches GitHub becomes a conflict copy.
    /// Dates follow their files: to the conflict copy, and to the new paths of a moved folder.
    func expand(
        _ edits: [Edit], remote: [TreeEntry], repo: String, claims: inout [String: String],
        dates: inout [String: Date], meta: DriveMeta = DriveMeta()
    ) throws -> [TreeChange] {
        let blobs = remote.filter { $0.type == .blob }
        let remoteSHA = Dictionary(blobs.map { ($0.path, $0.sha) }, uniquingKeysWith: { a, _ in a })
        var out: [TreeChange] = []
        for edit in edits {
            switch edit {
            case let .put(path, sha, mode, base):
                if let base, let current = remoteSHA[path], current != base, current != sha {
                    let copy = conflictPath(for: path)
                    log.notice("Conflict on \(path, privacy: .private), saving local copy")
                    claims[path] = nil
                    dates[copy] = dates.removeValue(forKey: path)
                    out.append(TreeChange(path: copy, sha: sha, mode: mode))
                } else {
                    out.append(TreeChange(path: path, sha: sha, mode: mode))
                }
            case let .delete(path):
                if remoteSHA[path] != nil { out.append(TreeChange(path: path, sha: nil)) }
            case let .deleteFolder(path):
                for b in blobs where b.path.hasPrefix(path + "/") {
                    out.append(TreeChange(path: b.path, sha: nil, mode: b.mode))
                }
            case let .moveFolder(from, to):
                for b in blobs where b.path.hasPrefix(from + "/") {
                    let newPath = to + b.path.dropFirst(from.count)
                    out.append(TreeChange(path: b.path, sha: nil, mode: b.mode))
                    out.append(TreeChange(path: newPath, sha: b.sha, mode: b.mode))
                    if let date = meta.modified[b.path] { dates[newPath] = date }
                }
            }
        }
        return out
    }

    // MARK: Helpers

    func location(of folderID: String) throws -> (RepoRecord, String) {
        guard let folder = try store.item(id: folderID), folder.isDirectory,
              let repo = try store.repo(named: folder.repo) else { throw DriveError.noSuchItem }
        return (repo, folder.path)
    }

    /// Uploads file contents and returns the blob to commit. Files over the LFS threshold go to LFS
    /// storage and the blob is their pointer; the returned map links that pointer to its object.
    func upload(_ file: URL, to repo: RepoRecord, name: String) async throws -> (String, [String: LFSObject]) {
        if isVault(repo.name) { return (try stage(file, in: repo.name), [:]) }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let threshold = lfsThreshold(), size > threshold {
            let object = try await client.lfsUpload(owner: repo.owner, repo: repo.name, file: file)
            let sha = try await client.createBlob(owner: repo.owner, repo: repo.name, data: object.pointer)
            return (sha, [sha: object])
        }
        if size > maxFileSize { throw DriveError.tooLarge(name) }
        return (try await client.createBlob(owner: repo.owner, repo: repo.name, contentsOf: file), [:])
    }

    func emptyBlob(in repo: RepoRecord) async throws -> String {
        if isVault(repo.name) { return try stage(data: Data(), in: repo.name) }
        if let sha = emptyBlobs[repo.name] { return sha }
        let sha = try await client.createBlob(owner: repo.owner, repo: repo.name, data: Data())
        emptyBlobs[repo.name] = sha
        return sha
    }
}

/// Serializes async work per key without blocking threads.
actor KeyedLock {
    var busy: Set<String> = []
    var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(_ key: String, _ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    func acquire(_ key: String) async {
        if busy.insert(key).inserted { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.resume()
        } else {
            busy.remove(key)
        }
    }
}
