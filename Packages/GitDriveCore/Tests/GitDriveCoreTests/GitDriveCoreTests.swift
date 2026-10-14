import Foundation
import Testing
@testable import GitDriveCore

@Suite("Models")
struct ModelTests {
    @Test func conflictNameKeepsExtensionAndFolder() {
        let date = Date(timeIntervalSince1970: 0)
        let name = conflictPath(for: "docs/notes.txt", date: date)
        #expect(name.hasPrefix("docs/notes (conflict from Mac "))
        #expect(name.hasSuffix(").txt"))
        #expect(conflictPath(for: "Makefile", date: date).hasPrefix("Makefile (conflict from Mac "))
        #expect(conflictPath(for: "Makefile", date: date).hasSuffix(")"))
    }

    @Test func conflictCopiesPointBackToTheOriginal() {
        let copy = conflictPath(for: "docs/notes.txt", date: Date(timeIntervalSince1970: 0))
        #expect(isConflictCopy((copy as NSString).lastPathComponent))
        #expect(originalPath(ofConflictCopy: copy) == "docs/notes.txt")
        #expect(!isConflictCopy("notes.txt"))
    }

    @Test func hiddenPaths() {
        #expect(Reserved.isHidden(path: "a/.gitdrive-keep"))
        #expect(Reserved.isHidden(path: ".gitdrive/meta.json"))
        #expect(!Reserved.isHidden(path: "a/b.txt"))
    }

    @Test func deleteEncodesExplicitNull() throws {
        let data = try JSONEncoder().encode(TreeChange(path: "a.txt", sha: nil))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"sha\":null"))
    }

    @Test func repoDisplayName() {
        #expect(Repo(name: "drive-photos", owner: "o", defaultBranch: "main", size: 0).displayName == "photos")
    }
}

@Suite("Sync engine", .serialized)
struct SyncEngineTests {
    let fake = FakeGitHub()
    let engine: SyncEngine
    let store: ItemStore

    init() throws {
        store = try ItemStore(url: nil)
        let client = GitHubClient(token: "test", session: FakeProtocol.session(for: fake))
        engine = SyncEngine(client: client, store: store, repoDeletion: { .delete })
    }

    private func id(_ repo: String, _ path: String) throws -> String {
        try #require(try store.item(repo: repo, path: path)).id
    }

    private func temp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func initialSyncBuildsTreeAndHidesPlaceholders() async throws {
        fake.seed(repo: "drive-docs", files: ["a.txt": "A", "sub/b.txt": "B", "empty/.gitdrive-keep": ""])
        fake.seed(repo: "not-a-drive", files: ["x": "x"])
        try await engine.syncAll()

        let root = try store.children(of: ItemStore.rootID)
        #expect(root.map(\.filename) == ["docs"])
        let docs = root[0]
        #expect(Set(try store.children(of: docs.id).map(\.filename)) == ["a.txt", "sub", "empty"])
        #expect(try store.children(of: id("drive-docs", "empty")).isEmpty)
    }

    @Test func createEditRenameDelete() async throws {
        fake.seed(repo: "drive-docs", files: [".gitdrive-keep": ""])
        try await engine.syncAll()
        let rootFolder = try id("drive-docs", "")

        let file = try await engine.createFile(parentID: rootFolder, name: "n.txt", contents: temp("one"))
        #expect(fake.files(repo: "drive-docs")["n.txt"] == "one")

        let edited = try await engine.modify(id: file.id, newName: nil, newParentID: nil, contents: temp("two"))
        #expect(edited.id == file.id)
        #expect(fake.files(repo: "drive-docs")["n.txt"] == "two")

        let folder = try await engine.createFolder(parentID: rootFolder, name: "f")
        let moved = try await engine.modify(id: file.id, newName: "m.txt", newParentID: folder.id, contents: nil)
        #expect(moved.id == file.id)
        #expect(moved.path == "f/m.txt")
        #expect(fake.files(repo: "drive-docs")["n.txt"] == nil)
        #expect(fake.files(repo: "drive-docs")["f/m.txt"] == "two")

        try await engine.delete(id: folder.id)
        #expect(fake.files(repo: "drive-docs").keys.sorted() == [".gitdrive-keep", Reserved.metaFile])
        #expect(try store.item(id: file.id) == nil)
    }

    @Test func folderRenameKeepsChildIDs() async throws {
        fake.seed(repo: "drive-docs", files: ["old/a.txt": "A", "old/deep/b.txt": "B", "old/.gitdrive-keep": ""])
        try await engine.syncAll()
        let folder = try id("drive-docs", "old")
        let child = try id("drive-docs", "old/deep/b.txt")

        _ = try await engine.modify(id: folder, newName: "new", newParentID: nil, contents: nil)
        #expect(try store.item(id: child)?.path == "new/deep/b.txt")
        #expect(Set(fake.files(repo: "drive-docs").keys) == ["new/a.txt", "new/deep/b.txt", "new/.gitdrive-keep"])
    }

    @Test func remoteChangeAppearsAfterAnchor() async throws {
        fake.seed(repo: "drive-docs", files: ["a.txt": "A"])
        try await engine.syncAll()
        let anchor = try store.currentAnchor()

        fake.remoteEdit(repo: "drive-docs", path: "a.txt", text: "A2")
        try await engine.syncAll()
        let changes = try store.changes(since: anchor)
        #expect(changes.updated.map(\.path) == ["a.txt"])
        #expect(changes.anchor > anchor)
    }

    @Test func editOnBothSidesMakesConflictCopy() async throws {
        fake.seed(repo: "drive-docs", files: ["a.txt": "base"])
        try await engine.syncAll()
        let a = try id("drive-docs", "a.txt")

        fake.remoteEdit(repo: "drive-docs", path: "a.txt", text: "theirs")
        _ = try await engine.modify(id: a, newName: nil, newParentID: nil, contents: temp("mine"))

        let files = fake.files(repo: "drive-docs")
        #expect(files["a.txt"] == "theirs")
        let copy = try #require(files.first { $0.key.contains("conflict from Mac") })
        #expect(copy.value == "mine")
        #expect(try store.item(id: a)?.path == "a.txt")
        #expect(await engine.takeConflict(id: a))
        #expect(await !engine.takeConflict(id: a))

        // Saving contents GitHub already has makes no commit.
        let before = fake.commitCount(repo: "drive-docs")
        _ = try await engine.modify(id: a, newName: nil, newParentID: nil, contents: temp("theirs"))
        #expect(fake.commitCount(repo: "drive-docs") == before)
    }

    @Test func modificationDatesSurviveSyncAndRename() async throws {
        fake.seed(repo: "drive-docs", files: [".gitdrive-keep": "", "old.txt": "from github"])
        try await engine.syncAll()
        let folder = try id("drive-docs", "")
        // Files GitDrive didn't write fall back to the commit date.
        #expect(try store.item(repo: "drive-docs", path: "old.txt")?.modified == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))

        let made = Date(timeIntervalSince1970: 1_700_000_000.75)
        let file = try await engine.createFile(parentID: folder, name: "a.txt", contents: temp("x"), modified: made)
        #expect(file.modified == made.wholeSeconds)
        #expect(fake.files(repo: "drive-docs")[Reserved.metaFile]?.contains("2023-11-14T22:13:20Z") == true)

        let renamed = try await engine.modify(id: file.id, newName: "b.txt", newParentID: nil, contents: nil)
        #expect(renamed.modified == made.wholeSeconds)

        // A second Mac with an empty index reads the same dates from the repo.
        let otherStore = try ItemStore(url: nil)
        let other = SyncEngine(client: engine.client, store: otherStore)
        try await other.syncAll()
        #expect(try otherStore.item(repo: "drive-docs", path: "b.txt")?.modified == made.wholeSeconds)
        #expect(try otherStore.item(repo: "drive-docs", path: Reserved.metaFile) == nil)

        try await engine.delete(id: file.id)
        #expect(fake.files(repo: "drive-docs")[Reserved.metaFile]?.contains("b.txt") == false)
    }

    @Test func folderMovesBetweenRepos() async throws {
        let date = ISO8601DateFormatter().date(from: "2025-05-01T12:00:00Z")!
        fake.seed(repo: "drive-photos", files: [".gitdrive-keep": "", "holiday/beach.jpg": "sand", "holiday/day2/sea.jpg": "water"])
        fake.seed(repo: "drive-documents", files: [".gitdrive-keep": ""])
        try await engine.syncAll()
        let holiday = try id("drive-photos", "holiday")
        let sea = try id("drive-photos", "holiday/day2/sea.jpg")
        let docs = try id("drive-documents", "")
        _ = try await engine.modify(id: sea, newName: nil, newParentID: nil, contents: temp("water"), modified: date)

        let moved = try await engine.modify(id: holiday, newName: nil, newParentID: docs, contents: nil)
        #expect(moved.id == holiday)
        #expect(moved.repo == "drive-documents")
        #expect(fake.files(repo: "drive-documents")["holiday/beach.jpg"] == "sand")
        #expect(fake.files(repo: "drive-documents")["holiday/day2/sea.jpg"] == "water")
        #expect(fake.files(repo: "drive-photos").keys.contains { $0.hasPrefix("holiday/") } == false)
        #expect(try store.item(id: sea)?.path == "holiday/day2/sea.jpg")
        #expect(try store.item(id: sea)?.repo == "drive-documents")
        #expect(try store.item(id: sea)?.modified == date)
    }

    @Test func deletingTopLevelFolderDeletesRepo() async throws {
        fake.seed(repo: "drive-old", files: ["a.txt": "A"])
        try await engine.syncAll()
        let folder = try id("drive-old", "")
        try await engine.delete(id: folder)
        #expect(fake.sync { fake.repos["drive-old"] } == nil)
        #expect(try store.children(of: ItemStore.rootID).isEmpty)
    }

    @Test func largeFilesGoToLFS() async throws {
        let lfsEngine = SyncEngine(
            client: engine.client, store: store, repoDeletion: { .delete }, lfsThreshold: { 16 }
        )
        fake.seed(repo: "drive-media", files: [".gitdrive-keep": "", "small.txt": "tiny"])
        try await lfsEngine.syncAll()
        let folder = try id("drive-media", "")
        let big = String(repeating: "video bytes ", count: 50)

        let file = try await lfsEngine.createFile(parentID: folder, name: "clip one.mov", contents: temp(big))
        #expect(file.size == Int64(big.utf8.count))
        let files = fake.files(repo: "drive-media")
        #expect(files["clip one.mov"]?.hasPrefix("version https://git-lfs.github.com/spec/v1") == true)
        #expect(files[".gitattributes"]?.contains("/clip[[:space:]]one.mov filter=lfs") == true)
        #expect(fake.sync { fake.lfsObjects.count } == 1)

        let (url, _) = try await lfsEngine.download(id: file.id)
        #expect(try String(contentsOf: url, encoding: .utf8) == big)

        // Renaming moves the pointer, the LFS record and the gitattributes rule.
        _ = try await lfsEngine.modify(id: file.id, newName: "clip.mov", newParentID: nil, contents: nil)
        let renamed = fake.files(repo: "drive-media")
        #expect(renamed[".gitattributes"]?.contains("/clip.mov filter=lfs") == true)
        #expect(renamed[".gitattributes"]?.contains("clip[[:space:]]one") == false)
        #expect(try store.item(id: file.id)?.size == Int64(big.utf8.count))

        // Small files stay normal blobs, and hidden files never show in Finder.
        #expect(renamed["small.txt"] == "tiny")
        #expect(try store.item(repo: "drive-media", path: ".gitattributes") == nil)

        try await lfsEngine.delete(id: file.id)
        #expect(fake.files(repo: "drive-media")[".gitattributes"] == nil)
    }

    @Test func gitattributesKeepsUserLines() {
        let out = GitAttributes.update("*.psd binary\n", lfsPaths: ["a b.zip"])
        #expect(out.hasPrefix("*.psd binary\n"))
        #expect(out.contains("/a[[:space:]]b.zip filter=lfs"))
        #expect(GitAttributes.update(out, lfsPaths: []) == "*.psd binary\n")
    }

    @Test func versionsCanBeListedAndRestored() async throws {
        fake.seed(repo: "drive-docs", files: [".gitdrive-keep": ""])
        try await engine.syncAll()
        let folder = try id("drive-docs", "")
        let file = try await engine.createFile(parentID: folder, name: "v.txt", contents: temp("one"))
        _ = try await engine.modify(id: file.id, newName: nil, newParentID: nil, contents: temp("two"))
        _ = try await engine.modify(id: file.id, newName: nil, newParentID: nil, contents: temp("three"))

        let versions = try await engine.versions(repo: "drive-docs", path: "v.txt")
        #expect(versions.count == 3)
        #expect(versions.first?.isCurrent == true)
        let oldest = try #require(versions.last)
        #expect(try String(contentsOf: try await engine.contents(of: oldest, repo: "drive-docs"), encoding: .utf8) == "one")

        try await engine.restore(oldest, repo: "drive-docs", path: "v.txt")
        #expect(fake.files(repo: "drive-docs")["v.txt"] == "one")
    }

    @Test func deletedFilesCanBeFoundAndRestored() async throws {
        fake.seed(repo: "drive-docs", files: [".gitdrive-keep": "", "keep.txt": "k", "gone.txt": "bye"])
        try await engine.syncAll()
        try await engine.delete(id: try id("drive-docs", "gone.txt"))

        let deleted = try await engine.recentlyDeleted()
        #expect(deleted.map(\.path) == ["gone.txt"])
        try await engine.restore(try #require(deleted.first))
        #expect(fake.files(repo: "drive-docs")["gone.txt"] == "bye")
        #expect(try await engine.recentlyDeleted().isEmpty)
    }

    @Test func largeFilesCanBeReadInParts() async throws {
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024)
        for i in bytes.indices { bytes[i] = UInt8(i % 251) }
        let big = String(decoding: bytes.map { $0 % 26 + 97 }, as: UTF8.self)
        fake.seed(repo: "drive-media", files: ["movie bits.bin": big])
        try await engine.syncAll()
        let item = try #require(try store.item(repo: "drive-media", path: "movie bits.bin"))

        let part = try #require(try await engine.partialContents(id: item.id, offset: 3_000_000, length: 10, alignment: 4096))
        #expect(part.offset == 2_998_272)
        #expect(part.length == Int64(SyncEngine.minimumPartialRead))
        let handle = try FileHandle(forReadingFrom: part.url)
        try handle.seek(toOffset: 3_000_000)
        let read = try handle.read(upToCount: 10)
        #expect(read == Data(big.utf8).subdata(in: 3_000_000..<3_000_010))

        let small = try await engine.createFile(parentID: try id("drive-media", ""), name: "s.txt", contents: temp("tiny"))
        #expect(try await engine.partialContents(id: small.id, offset: 0, length: 1, alignment: 4096) == nil)
    }

    @Test func conflictsCanBeResolved() async throws {
        fake.seed(repo: "drive-docs", files: ["a.txt": "base", "b.txt": "base"])
        try await engine.syncAll()
        for name in ["a.txt", "b.txt"] {
            fake.remoteEdit(repo: "drive-docs", path: name, text: "theirs")
            _ = try await engine.modify(id: try id("drive-docs", name), newName: nil, newParentID: nil, contents: temp("mine"))
        }
        let found = try await engine.conflicts().sorted { $0.copy.path < $1.copy.path }
        #expect(found.count == 2)
        #expect(found[0].original?.path == "a.txt")

        try await engine.resolve(found[0], keeping: .mine)
        try await engine.resolve(found[1], keeping: .both)
        let files = fake.files(repo: "drive-docs")
        #expect(files["a.txt"] == "mine")
        #expect(files["b.txt"] == "theirs")
        #expect(files["b (my version).txt"] == "mine")
        #expect(try await engine.conflicts().isEmpty)
    }

    @Test func backupsMirrorAFolderAndSkipUnchangedFiles() async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: local.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: local.appendingPathComponent("sub/b.txt"))
        try Data("x".utf8).write(to: local.appendingPathComponent(".DS_Store"))
        try await engine.syncAll()

        let first = try await engine.backup(local, into: nil, name: "Docs", encrypt: false)
        #expect(first.uploaded == 2)
        #expect(fake.files(repo: first.repo)["sub/b.txt"] == "two")
        #expect(fake.files(repo: first.repo)[".DS_Store"] == nil)

        let commits = fake.commitCount(repo: first.repo)
        let again = try await engine.backup(local, into: first.repo, name: "Docs", encrypt: false)
        #expect(again.unchanged == 2 && again.uploaded == 0)
        #expect(fake.commitCount(repo: first.repo) == commits)

        try Data("one, edited".utf8).write(to: local.appendingPathComponent("a.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: local.appendingPathComponent("a.txt").path)
        try FileManager.default.removeItem(at: local.appendingPathComponent("sub/b.txt"))
        let third = try await engine.backup(local, into: first.repo, name: "Docs", encrypt: false)
        #expect(third.uploaded == 1 && third.deleted == 1)
        #expect(fake.files(repo: first.repo)["a.txt"] == "one, edited")
        #expect(fake.files(repo: first.repo)["sub/b.txt"] == nil)
    }

    @Test func tripwireFiresOnRandomDataOnly() throws {
        let wire = Tripwire(threshold: 3, window: 600)
        var random = Data(count: 16_384)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let encrypted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try random.write(to: encrypted)
        let text = try temp(String(repeating: "Dear diary, today was fine. ", count: 600))

        #expect(Tripwire.looksEncrypted(encrypted, name: "report.docx.locked"))
        #expect(!Tripwire.looksEncrypted(text, name: "diary.txt"))
        #expect(!Tripwire.looksEncrypted(encrypted, name: "holiday.jpg"))
        #expect(!wire.record(encrypted, name: "a.txt"))
        #expect(!wire.record(text, name: "b.txt"))
        #expect(!wire.record(encrypted, name: "c.txt"))
        #expect(wire.record(encrypted, name: "d.txt"))
    }

    @Test func rollBackRestoresEarlierFiles() async throws {
        fake.seed(repo: "drive-docs", files: ["a.txt": "good"])
        try await engine.syncAll()
        let checkpoint = Date()
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await engine.modify(id: try id("drive-docs", "a.txt"), newName: nil, newParentID: nil, contents: temp("encrypted junk"))
        #expect(fake.files(repo: "drive-docs")["a.txt"] == "encrypted junk")

        let changed = try await engine.rollBack(to: checkpoint)
        #expect(changed == ["drive-docs"])
        #expect(fake.files(repo: "drive-docs")["a.txt"] == "good")
    }

    @Test func bitRotCheckFindsChangedBytes() async throws {
        fake.seed(repo: "drive-docs", files: ["ok.txt": "fine", "sub/rot.txt": "original"])
        try await engine.syncAll()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try Data("fine".utf8).write(to: root.appendingPathComponent("docs/ok.txt"))
        try Data("origimal".utf8).write(to: root.appendingPathComponent("docs/sub/rot.txt"))

        let report = await engine.checkForBitRot(root: root, requireDownloaded: false)
        #expect(report.checked == 2)
        #expect(report.damaged.map(\.lastPathComponent) == ["rot.txt"])
    }

    @Test func filesAtRootAreRejected() async throws {
        await #expect(throws: DriveError.filesNotAllowedInRoot) {
            _ = try await engine.createFile(parentID: ItemStore.rootID, name: "x", contents: try temp("x"))
        }
    }

    @Test func concurrentEditsAreBatched() async throws {
        fake.seed(repo: "drive-docs", files: [".gitdrive-keep": ""])
        try await engine.syncAll()
        let folder = try id("drive-docs", "")
        let before = fake.commitCount(repo: "drive-docs")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                let url = try temp("\(i)")
                group.addTask { _ = try await engine.createFile(parentID: folder, name: "f\(i).txt", contents: url) }
            }
            try await group.waitForAll()
        }
        #expect(fake.files(repo: "drive-docs").keys.filter { $0.hasPrefix("f") }.count == 8)
        #expect(fake.commitCount(repo: "drive-docs") - before < 8)
    }
}

@Suite("Errors")
struct ErrorMappingTests {
    @Test func rateLimitIsRecognised() {
        let http = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!, statusCode: 403, httpVersion: nil,
            headerFields: ["X-RateLimit-Remaining": "0", "Retry-After": "7"]
        )!
        #expect(GitHubClient.error(for: http, body: Data()).kind == .rateLimited(retryAfter: 7))
    }

    @Test func unauthorized() {
        let http = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        #expect(GitHubClient.error(for: http, body: Data()).kind == .unauthorized)
    }
}
