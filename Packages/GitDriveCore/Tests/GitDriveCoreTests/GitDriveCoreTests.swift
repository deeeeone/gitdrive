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
