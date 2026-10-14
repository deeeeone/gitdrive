import Foundation

/// What the engine keeps in memory for one unlocked encrypted folder.
struct VaultState: Sendable {
    var key: FolderKey
    /// Blob SHA of `.gitdrive/vault.json`, so the key is only unwrapped again if the header changes.
    var headerSHA: String
    var index: VaultIndex
    var indexSHA: String?
    /// Pack ID to its git blob SHA.
    var packBlobs: [String: String]
}

/// File contents chunked and sealed locally, waiting to be packed into the next commit.
struct StagedFile: Sendable {
    let chunks: [String]
    let size: Int64
}

/// Recently downloaded packs, so reading several files from one pack downloads it once.
struct PackCache: Sendable {
    private var packs: [String: Data] = [:]
    private var order: [String] = []
    private var bytes = 0
    let limit = 96 * 1024 * 1024

    func get(_ id: String) -> Data? { packs[id] }

    mutating func put(_ id: String, _ data: Data) {
        guard packs[id] == nil else { return }
        packs[id] = data
        order.append(id)
        bytes += data.count
        while bytes > limit, order.count > 1 {
            let oldest = order.removeFirst()
            bytes -= packs.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}

/// Packs fill up to about this size before a new one starts. Well under GitHub's 100 MB file limit.
let targetPackSize = 8 * 1024 * 1024

extension SyncEngine {
    func isVault(_ repo: String) -> Bool {
        vaults[repo] != nil || lockedRepos.contains(repo)
    }

    /// Whether a top-level folder is encrypted, for showing a lock in the UI.
    public func isEncrypted(repo: String) -> Bool { isVault(repo) }

    // MARK: Reading

    /// Unlocks the folder if needed, reads the index, and shows its files as if they were a git tree.
    func refreshVault(_ rec: RepoRecord, head: String?, entries: [TreeEntry], claims: [String: String], commitDate: Date) async throws {
        guard let headerEntry = entries.first(where: { $0.path == Reserved.vaultFile }) else { return }
        var state = vaults[rec.name]
        if state == nil || state?.headerSHA != headerEntry.sha {
            do {
                state = try await unlock(rec, headerSHA: headerEntry.sha)
            } catch let error as VaultError where error == .locked || error == .wrongKey {
                log.notice("\(rec.name, privacy: .public) is encrypted and can't be unlocked on this Mac")
                vaults[rec.name] = nil
                lockedRepos.insert(rec.name)
                try apply(repo: rec, head: head, entries: [], claims: [:], displayName: "Locked folder \(rec.name.suffix(6))")
                return
            }
        }
        guard var state else { return }
        lockedRepos.remove(rec.name)

        if let indexEntry = entries.first(where: { $0.path == Reserved.indexFile }), indexEntry.sha != state.indexSHA {
            let sealed = try await client.blobData(owner: rec.owner, repo: rec.name, sha: indexEntry.sha)
            state.index = try VaultIndex.decode(try state.key.openIndex(sealed))
            state.indexSHA = indexEntry.sha
        }
        state.packBlobs = [:]
        for entry in entries where entry.type == .blob && entry.path.hasPrefix("p/") {
            state.packBlobs[String(entry.path.split(separator: "/").last ?? "")] = entry.sha
        }
        vaults[rec.name] = state
        try apply(
            repo: rec, head: head, entries: state.index.treeEntries, claims: claims,
            meta: DriveMeta(modified: state.index.dates), fallbackDate: commitDate, displayName: state.index.name
        )
    }

    private func unlock(_ rec: RepoRecord, headerSHA: String) async throws -> VaultState {
        guard let identity = identity() else { throw VaultError.locked }
        let data = try await client.blobData(owner: rec.owner, repo: rec.name, sha: headerSHA)
        guard let header = try? JSONDecoder().decode(VaultHeader.self, from: data) else { throw VaultError.corrupt("vault header") }
        let key = try identity.unwrap(header)
        return VaultState(key: key, headerSHA: headerSHA, index: VaultIndex(name: ""), indexSHA: nil, packBlobs: [:])
    }

    /// The real bytes of a file, for plain repos (following LFS pointers) and encrypted ones.
    /// Pass `state` to read from an older snapshot of an encrypted folder.
    func readContent(_ rec: RepoRecord, sha: String, state snapshot: VaultState? = nil) async throws -> URL {
        guard isVault(rec.name) else {
            return try await client.downloadContents(owner: rec.owner, repo: rec.name, sha: sha)
        }
        guard let state = snapshot ?? vaults[rec.name] else { throw VaultError.locked }
        guard let file = state.index.file(withContent: sha) else { throw DriveError.noSuchItem }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for id in file.k {
            guard let location = state.index.chunks[id] else { throw VaultError.corrupt("missing chunk") }
            let pack = try await packData(rec, state: state, id: location.p)
            guard location.o + location.l <= pack.count else { throw VaultError.corrupt("chunk outside its pack") }
            let sealed = pack.subdata(in: location.o..<(location.o + location.l))
            try handle.write(contentsOf: try state.key.openChunk(sealed, id: id))
        }
        return url
    }

    private func packData(_ rec: RepoRecord, state: VaultState, id: String) async throws -> Data {
        if let cached = packCache.get(id) { return cached }
        guard let sha = state.packBlobs[id] else { throw VaultError.corrupt("missing pack") }
        let data = try await client.blobData(owner: rec.owner, repo: rec.name, sha: sha)
        packCache.put(id, data)
        return data
    }

    /// Files (and the folders they imply) plus dates, for either kind of repo.
    func listing(of rec: RepoRecord) async throws -> ([TreeEntry], DriveMeta) {
        if isVault(rec.name) {
            guard let state = vaults[rec.name] else { throw VaultError.locked }
            return (state.index.treeEntries, DriveMeta(modified: state.index.dates))
        }
        let head = try await client.headSHA(owner: rec.owner, repo: rec.name, branch: rec.branch)
        let tree = try await client.treeSHA(owner: rec.owner, repo: rec.name, commit: head)
        let entries = try await client.fullTree(owner: rec.owner, repo: rec.name, sha: tree)
        return (entries, await loadMeta(rec, entries: entries))
    }

    // MARK: Writing

    /// Chunks, compresses and encrypts a file locally. Nothing leaves the Mac until the commit,
    /// and then only as sealed chunks inside packs. Returns the content ID used as the blob SHA.
    func stage(_ file: URL, in repo: String) throws -> String {
        try stage(data: try Data(contentsOf: file, options: .mappedIfSafe), in: repo)
    }

    func stage(data: Data, in repo: String) throws -> String {
        guard let state = vaults[repo] else { throw VaultError.locked }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDriveStaging", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ids: [String] = []
        for range in state.key.chunker.chunks(of: data) {
            let (id, sealed) = try state.key.sealChunk(data.subdata(in: range))
            ids.append(id)
            if state.index.chunks[id] == nil, stagedChunks[repo]?[id] == nil {
                let url = dir.appendingPathComponent(id)
                try sealed.write(to: url)
                stagedChunks[repo, default: [:]][id] = url
            }
        }
        let content = VaultIndex.contentID(chunks: ids, size: Int64(data.count))
        stagedFiles[repo, default: [:]][content] = StagedFile(chunks: ids, size: Int64(data.count))
        return content
    }

    /// Same queue and conflict handling as plain repos, but the commit only ever adds sealed packs
    /// and a new sealed index, and its message never names a file.
    func performVaultCommit(repo name: String, batch: [PendingCommit]) async throws {
        for attempt in 1...3 {
            guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
            let head = try await client.headSHA(owner: rec.owner, repo: name, branch: rec.branch)
            if head != rec.head { try await refresh(name) }
            guard let state = vaults[name] else { throw VaultError.locked }

            var claims: [String: String] = [:]
            var dates: [String: Date] = [:]
            for p in batch {
                claims.merge(p.claims) { _, new in new }
                dates.merge(p.dates) { _, new in new }
            }
            let changes = try expand(
                batch.flatMap(\.edits), remote: state.index.treeEntries, repo: name,
                claims: &claims, dates: &dates, meta: DriveMeta(modified: state.index.dates)
            )
            if changes.isEmpty { return }

            var index = state.index
            for change in changes {
                guard let content = change.sha else {
                    index.files[change.path] = nil
                    continue
                }
                let previous = index.files[change.path].map { Date(timeIntervalSince1970: $0.m) }
                let date = (dates[change.path] ?? previous ?? Date()).wholeSeconds.timeIntervalSince1970
                if let staged = stagedFiles[name]?[content] {
                    index.files[change.path] = .init(c: content, s: staged.size, m: date, k: staged.chunks)
                } else if let existing = state.index.file(withContent: content) {
                    index.files[change.path] = .init(c: content, s: existing.s, m: date, k: existing.k)
                } else {
                    throw VaultError.corrupt("contents for \(change.path) went missing before saving")
                }
            }

            do {
                let (commit, tree, updated) = try await writeVault(rec, head: head, state: state, index: index)
                vaults[name] = updated
                try await refresh(name, knownHead: (commit, tree), claims: claims)
                clearStaging(name, keeping: changes)
                return
            } catch let e as GitHubError where e.kind == .conflict && attempt < 3 {
                log.notice("\(name, privacy: .public) moved during commit, retrying (\(attempt))")
            }
        }
    }

    /// Packs every chunk the new index needs that GitHub doesn't have yet, drops packs nothing uses
    /// any more, seals the index and commits. Returns the new commit, its tree and the updated state.
    private func writeVault(
        _ rec: RepoRecord, head: String, state: VaultState, index newIndex: VaultIndex
    ) async throws -> (String, String, VaultState) {
        var index = newIndex
        var state = state
        var changes: [TreeChange] = []

        var needed: [String] = []
        var seen = Set<String>()
        for file in index.files.values {
            for id in file.k where index.chunks[id] == nil && seen.insert(id).inserted { needed.append(id) }
        }

        // Group chunks into packs of about targetPackSize, in order.
        var groups: [[String]] = [[]]
        var groupSize = 0
        var sealedSizes: [String: Int] = [:]
        for id in needed {
            guard let url = stagedChunks[rec.name]?[id] else { throw VaultError.corrupt("a chunk went missing before saving") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sealedSizes[id] = size
            if groupSize >= targetPackSize { groups.append([]); groupSize = 0 }
            groups[groups.count - 1].append(id)
            groupSize += size
        }
        for group in groups where !group.isEmpty {
            var pack = Data()
            var locations: [(String, Int, Int)] = []
            for id in group {
                let sealed = try Data(contentsOf: stagedChunks[rec.name]![id]!)
                locations.append((id, pack.count, sealed.count))
                pack.append(sealed)
            }
            // Random padding is indistinguishable from ciphertext, so only the padded size shows.
            let padded = padme(pack.count)
            if padded > pack.count { pack.append(randomBytes(padded - pack.count)) }
            let packID = randomToken(bytes: 16)
            let sha = try await client.createBlob(owner: rec.owner, repo: rec.name, data: pack)
            changes.append(TreeChange(path: VaultIndex.packPath(packID), sha: sha))
            state.packBlobs[packID] = sha
            for (id, offset, length) in locations { index.chunks[id] = .init(p: packID, o: offset, l: length) }
            packCache.put(packID, pack)
        }

        index.pruneChunks()
        let live = index.livePacks
        for (packID, _) in state.packBlobs where !live.contains(packID) {
            changes.append(TreeChange(path: VaultIndex.packPath(packID), sha: nil))
            state.packBlobs[packID] = nil
        }

        let sealedIndex = try state.key.sealIndex(try index.encoded())
        let indexSHA = try await client.createBlob(owner: rec.owner, repo: rec.name, data: sealedIndex)
        changes.append(TreeChange(path: Reserved.indexFile, sha: indexSHA))

        let baseTree = try await client.treeSHA(owner: rec.owner, repo: rec.name, commit: head)
        let tree = try await client.createTree(owner: rec.owner, repo: rec.name, base: baseTree, changes: changes)
        let commit = try await client.createCommit(owner: rec.owner, repo: rec.name, message: "Update", tree: tree, parents: [head])
        try await client.updateRef(owner: rec.owner, repo: rec.name, branch: rec.branch, sha: commit)
        state.index = index
        state.indexSHA = indexSHA
        return (commit, tree, state)
    }

    private func clearStaging(_ repo: String, keeping changes: [TreeChange]) {
        guard let state = vaults[repo] else { return }
        for change in changes { if let sha = change.sha { stagedFiles[repo]?[sha] = nil } }
        for (id, url) in stagedChunks[repo] ?? [:] where state.index.chunks[id] != nil {
            try? FileManager.default.removeItem(at: url)
            stagedChunks[repo]?[id] = nil
        }
    }

    /// Renaming an encrypted top-level folder only changes the name inside the sealed index.
    func renameVault(_ name: String, to newName: String) async throws {
        try await locks.withLock(name) {
            try await self.renameVaultLocked(name, to: newName)
        }
    }

    private func renameVaultLocked(_ name: String, to newName: String) async throws {
        for attempt in 1...3 {
            guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
            let head = try await client.headSHA(owner: rec.owner, repo: name, branch: rec.branch)
            if head != rec.head { try await refresh(name) }
            guard let state = vaults[name] else { throw VaultError.locked }
            var index = state.index
            index.name = newName
            do {
                let (commit, tree, updated) = try await writeVault(rec, head: head, state: state, index: index)
                vaults[name] = updated
                try await refresh(name, knownHead: (commit, tree))
                return
            } catch let e as GitHubError where e.kind == .conflict && attempt < 3 {
                continue
            }
        }
    }

    /// Creates a new encrypted top-level folder in a repo with a random name.
    func createVaultFolder(named displayName: String) async throws -> ItemRecord {
        guard let identity = identity() else { throw VaultError.locked }
        let repo = try await client.createDriveRepo(folderName: randomToken(bytes: 6))
        let key = FolderKey.random()
        let header = try identity.wrap(key)
        let index = VaultIndex(name: displayName)

        let owner = repo.owner.login
        let branch = repo.defaultBranch ?? "main"
        let head = try await client.headSHA(owner: owner, repo: repo.name, branch: branch)
        let base = try await client.treeSHA(owner: owner, repo: repo.name, commit: head)
        let headerSHA = try await client.createBlob(owner: owner, repo: repo.name, data: try header.encoded())
        let indexSHA = try await client.createBlob(owner: owner, repo: repo.name, data: try key.sealIndex(try index.encoded()))
        let tree = try await client.createTree(owner: owner, repo: repo.name, base: base, changes: [
            TreeChange(path: Reserved.vaultFile, sha: headerSHA),
            TreeChange(path: Reserved.indexFile, sha: indexSHA),
        ])
        let commit = try await client.createCommit(owner: owner, repo: repo.name, message: "Update", tree: tree, parents: [head])
        try await client.updateRef(owner: owner, repo: repo.name, branch: branch, sha: commit)

        vaults[repo.name] = VaultState(key: key, headerSHA: headerSHA, index: index, indexSHA: indexSHA, packBlobs: [:])
        try reconcileRepos(try await client.driveRepos())
        try await syncRepo(repo.name)
        guard let item = try store.item(repo: repo.name, path: "") else { throw DriveError.noSuchItem }
        return item
    }

    /// Copies a plain top-level folder into a new encrypted one, then deletes the plain repo so no
    /// readable copy stays on GitHub. Returns the new repo's name.
    public func encrypt(repo name: String, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> String {
        try await syncRepoListIfStale(maxAge: 0)
        try await syncRepo(name)
        guard !isVault(name), let rec = try store.repo(named: name), let root = try store.item(repo: name, path: "") else {
            throw DriveError.noSuchItem
        }
        let target = try await createVaultFolder(named: root.filename)
        let items = try store.descendants(of: root)
        let files = items.filter { !$0.isDirectory }
        let emptyFolders = items.filter { folder in folder.isDirectory && !items.contains { $0.parentID == folder.id } }

        var edits: [Edit] = []
        var dates: [String: Date] = [:]
        var done = 0
        for file in files {
            let url = try await readContent(rec, sha: file.sha ?? "")
            let content = try stage(url, in: target.repo)
            try? FileManager.default.removeItem(at: url)
            edits.append(.put(path: file.path, sha: content))
            dates[file.path] = file.modified
            done += 1
            progress(done, files.count)
            if edits.count >= 200 {
                let batch = edits, batchDates = dates
                edits = []
                dates = [:]
                try await commit(repo: target.repo, edits: batch, claims: [:], dates: batchDates, message: "Update")
            }
        }
        for folder in emptyFolders {
            edits.append(.put(path: joinPath(folder.path, Reserved.keepFile), sha: try stage(data: Data(), in: target.repo)))
        }
        if !edits.isEmpty {
            let batch = edits, batchDates = dates
            try await commit(repo: target.repo, edits: batch, claims: [:], dates: batchDates, message: "Update")
        }

        try await client.deleteRepo(owner: rec.owner, name: rec.name)
        try reconcileRepos(try await client.driveRepos())
        return target.repo
    }
}

extension SyncEngine {
    /// Turns an encrypted folder back into a normal readable repo, then deletes the encrypted repo.
    /// Returns the new repo's name. GitHub turns characters it doesn't allow in repo names into "-".
    public func decrypt(repo name: String, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> String {
        try await syncRepoListIfStale(maxAge: 0)
        try await syncRepo(name)
        guard vaults[name] != nil, let rec = try store.repo(named: name), let root = try store.item(repo: name, path: "") else {
            throw lockedRepos.contains(name) ? VaultError.locked : DriveError.noSuchItem
        }
        let items = try store.descendants(of: root)
        let files = items.filter { !$0.isDirectory }
        if lfsThreshold() == nil, let big = files.first(where: { $0.size > maxFileSize }) {
            throw DriveError.tooLarge(big.filename)
        }
        let emptyFolders = items.filter { folder in folder.isDirectory && !items.contains { $0.parentID == folder.id } }

        let created = try await client.createDriveRepo(folderName: root.filename)
        try reconcileRepos(try await client.driveRepos())
        try await syncRepo(created.name)
        guard let target = try store.repo(named: created.name) else { throw DriveError.noSuchItem }

        var edits: [Edit] = []
        var dates: [String: Date] = [:]
        var lfs: [String: LFSObject] = [:]
        var done = 0
        for file in files {
            let url = try await readContent(rec, sha: file.sha ?? "")
            let (sha, objects) = try await upload(url, to: target, name: file.filename)
            try? FileManager.default.removeItem(at: url)
            edits.append(.put(path: file.path, sha: sha))
            dates[file.path] = file.modified
            lfs.merge(objects) { a, _ in a }
            done += 1
            progress(done, files.count)
            if edits.count >= 200 {
                let batch = edits, batchDates = dates, batchLFS = lfs
                edits = []
                dates = [:]
                lfs = [:]
                try await commit(repo: target.name, edits: batch, claims: [:], dates: batchDates, lfs: batchLFS, message: "Add files")
            }
        }
        for folder in emptyFolders {
            edits.append(.put(path: joinPath(folder.path, Reserved.keepFile), sha: try await emptyBlob(in: target)))
        }
        if !edits.isEmpty {
            let batch = edits, batchDates = dates, batchLFS = lfs
            try await commit(repo: target.name, edits: batch, claims: [:], dates: batchDates, lfs: batchLFS, message: "Add files")
        }

        try await client.deleteRepo(owner: rec.owner, name: rec.name)
        vaults[name] = nil
        try reconcileRepos(try await client.driveRepos())
        return target.name
    }
}

private func randomBytes(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    return data
}
