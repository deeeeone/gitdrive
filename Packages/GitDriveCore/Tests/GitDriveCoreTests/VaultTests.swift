import CryptoKit
import Foundation
import Testing
@testable import GitDriveCore

@Suite("Vault crypto")
struct VaultCryptoTests {
    @Test func padmeLeaksLittleAndStaysSmall() {
        #expect(padme(1) == 1)
        for length in [100, 1000, 12345, 1_000_000, 8_388_608] {
            let padded = padme(length)
            #expect(padded >= length)
            #expect(Double(padded - length) / Double(length) < 0.12)
        }
    }

    @Test func chunkerIsDeterministicAndShiftResistant() {
        let key = FolderKey.random()
        var data = Data(count: 9 * 1024 * 1024)
        data.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let chunks = key.chunker.chunks(of: data)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.count <= key.chunker.maxSize })
        #expect(chunks.first?.lowerBound == 0 && chunks.last?.upperBound == data.count)

        // Inserting bytes at the start only changes the first chunk or two.
        let shifted = Data("inserted".utf8) + data
        let ids = Set(chunks.map { key.chunkID(data.subdata(in: $0)) })
        let shiftedIDs = Set(key.chunker.chunks(of: shifted).map { key.chunkID(shifted.subdata(in: $0)) })
        #expect(ids.intersection(shiftedIDs).count >= ids.count - 2)
    }

    @Test func chunksRoundTripAndCompress() throws {
        let key = FolderKey.random()
        let text = Data(String(repeating: "the same words over and over ", count: 2000).utf8)
        let (id, sealed) = try key.sealChunk(text)
        #expect(sealed.count < text.count / 4)
        #expect(try key.openChunk(sealed, id: id) == text)

        var tampered = sealed
        tampered[20] ^= 1
        #expect(throws: VaultError.self) { _ = try key.openChunk(tampered, id: id) }
        #expect(throws: VaultError.self) { _ = try FolderKey.random().openChunk(sealed, id: id) }
    }

    @Test func folderKeyWrapsToPublicKeyOnly() throws {
        let identity = try VaultIdentity.generate()
        let folder = FolderKey.random()
        let header = try identity.wrap(folder)
        let unwrapped = try identity.unwrap(header)
        #expect(unwrapped.raw == folder.raw)
        #expect(try VaultIdentity(secret: identity.secret) == identity)

        let other = try VaultIdentity.generate()
        #expect(throws: VaultError.wrongKey) { _ = try other.unwrap(header) }
    }
}

@Suite("Encrypted folders", .serialized)
struct EncryptedFolderTests {
    let fake = FakeGitHub()
    let identity: VaultIdentity
    let client: GitHubClient

    init() throws {
        identity = try VaultIdentity.generate()
        client = GitHubClient(token: "test", session: FakeProtocol.session(for: fake))
    }

    private func engine(store: ItemStore, identity: VaultIdentity?) -> SyncEngine {
        SyncEngine(
            client: client, store: store, repoDeletion: { .delete },
            identity: { identity }, encryptNewFolders: { true }
        )
    }

    private func temp(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func nothingReadableReachesGitHub() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()

        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "Secret Plans")
        #expect(folder.filename == "Secret Plans")
        #expect(!folder.repo.contains("Secret"))
        let sub = try await engine.createFolder(parentID: folder.id, name: "Taxes 2026")
        let secret = "my bank PIN is 4921 " + String(repeating: "and some repeated filler text ", count: 500)
        let file = try await engine.createFile(parentID: sub.id, name: "passwords.txt", contents: temp(secret))
        _ = try await engine.createFile(parentID: folder.id, name: "copy.txt", contents: temp(secret))

        let raw = fake.rawBlobs(repo: folder.repo)
        let paths = raw.keys.joined(separator: " ")
        for leak in ["Secret", "Taxes", "passwords", "copy"] { #expect(!paths.contains(leak)) }
        for (_, data) in raw {
            let text = String(decoding: data, as: UTF8.self)
            for leak in ["Secret Plans", "Taxes", "passwords", "PIN", "4921", "filler"] { #expect(!text.contains(leak)) }
        }
        // Compressed and deduplicated: two copies of the text take less room than one plain copy.
        let packBytes = raw.filter { $0.key.hasPrefix("p/") }.values.reduce(0) { $0 + $1.count }
        #expect(packBytes < secret.utf8.count / 2)
        #expect(fake.sync { fake.commits.values.count } > 0)

        let (url, _) = try await engine.download(id: file.id)
        #expect(try String(contentsOf: url, encoding: .utf8) == secret)
    }

    @Test func secondMacReadsItAndOthersCant() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()
        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "Photos")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let file = try await engine.createFile(parentID: folder.id, name: "beach.jpg", contents: temp("sand"), modified: date)
        _ = try await engine.modify(id: file.id, newName: "beach day.jpg", newParentID: nil, contents: nil)
        _ = try await engine.modify(id: folder.id, newName: "Holiday Photos", newParentID: nil, contents: nil)

        let otherStore = try ItemStore(url: nil)
        let other = self.engine(store: otherStore, identity: try VaultIdentity(secret: identity.secret))
        try await other.syncAll()
        let root = try #require(try otherStore.children(of: ItemStore.rootID).first)
        #expect(root.filename == "Holiday Photos")
        let copy = try #require(try otherStore.item(repo: root.repo, path: "beach day.jpg"))
        #expect(copy.modified == date)
        let (url, _) = try await other.download(id: copy.id)
        #expect(try String(contentsOf: url, encoding: .utf8) == "sand")

        let strangerStore = try ItemStore(url: nil)
        let stranger = self.engine(store: strangerStore, identity: try VaultIdentity.generate())
        try await stranger.syncAll()
        let locked = try #require(try strangerStore.children(of: ItemStore.rootID).first)
        #expect(locked.filename.hasPrefix("Locked folder"))
        #expect(try strangerStore.children(of: locked.id).isEmpty)
    }

    @Test func editsDeletesAndFolderMoves() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()
        let a = try await engine.createFolder(parentID: ItemStore.rootID, name: "A")
        let b = try await engine.createFolder(parentID: ItemStore.rootID, name: "B")
        let inner = try await engine.createFolder(parentID: a.id, name: "inner")
        let file = try await engine.createFile(parentID: inner.id, name: "f.txt", contents: temp("one"))
        _ = try await engine.modify(id: file.id, newName: nil, newParentID: nil, contents: temp("two"))
        #expect(try String(contentsOf: try await engine.download(id: file.id).0, encoding: .utf8) == "two")

        // Folder moves between two encrypted repos keep IDs and contents.
        let moved = try await engine.modify(id: inner.id, newName: nil, newParentID: b.id, contents: nil)
        #expect(moved.repo == b.repo)
        #expect(try store.item(id: file.id)?.path == "inner/f.txt")
        #expect(try String(contentsOf: try await engine.download(id: file.id).0, encoding: .utf8) == "two")
        #expect(try store.children(of: a.id).isEmpty)

        // Packs nothing uses are removed from the repo.
        let packsBefore = fake.rawBlobs(repo: b.repo).keys.filter { $0.hasPrefix("p/") }.count
        try await engine.delete(id: file.id)
        let packsAfter = fake.rawBlobs(repo: b.repo).keys.filter { $0.hasPrefix("p/") }.count
        #expect(packsAfter < packsBefore)
    }

    @Test func encryptedFolderCanBeDecrypted() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()
        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "Vault")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sub = try await engine.createFolder(parentID: folder.id, name: "docs")
        _ = try await engine.createFile(parentID: sub.id, name: "a.txt", contents: temp("alpha"), modified: date)
        _ = try await engine.createFolder(parentID: folder.id, name: "empty")

        let plain = try await engine.decrypt(repo: folder.repo)
        #expect(plain == "drive-Vault")
        #expect(fake.sync { fake.repos[folder.repo] } == nil)
        let files = fake.files(repo: plain)
        #expect(files["docs/a.txt"] == "alpha")
        #expect(files["empty/.gitdrive-keep"] == "")
        #expect(files[Reserved.vaultFile] == nil)
        #expect(try store.item(repo: plain, path: "docs/a.txt")?.modified == date)
        #expect(await engine.isEncrypted(repo: plain) == false)
    }

    @Test func encryptedVersionsSurvivePackPruning() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()
        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "V")
        let file = try await engine.createFile(parentID: folder.id, name: "a.txt", contents: temp("first"))
        _ = try await engine.modify(id: file.id, newName: nil, newParentID: nil, contents: temp("second"))

        let versions = try await engine.versions(repo: folder.repo, path: "a.txt")
        #expect(versions.count == 2)
        let old = try #require(versions.last)
        // The first version's pack was pruned from the current tree, but history still has it.
        #expect(try String(contentsOf: try await engine.contents(of: old, repo: folder.repo), encoding: .utf8) == "first")
        try await engine.restore(old, repo: folder.repo, path: "a.txt")
        let (url, _) = try await engine.download(id: file.id)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
    }

    @Test func encryptedDeletesCanBeRestored() async throws {
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()
        let folder = try await engine.createFolder(parentID: ItemStore.rootID, name: "D")
        let file = try await engine.createFile(parentID: folder.id, name: "secret.txt", contents: temp("hidden"))
        try await engine.delete(id: file.id)

        let deleted = try await engine.recentlyDeleted()
        #expect(deleted.map(\.path) == ["secret.txt"])
        try await engine.restore(try #require(deleted.first))
        let restored = try #require(try store.item(repo: folder.repo, path: "secret.txt"))
        #expect(try String(contentsOf: try await engine.download(id: restored.id).0, encoding: .utf8) == "hidden")
    }

    @Test func plainFolderCanBeEncrypted() async throws {
        fake.seed(repo: "drive-notes", files: [".gitdrive-keep": "", "diary.txt": "dear diary", "empty/.gitdrive-keep": ""])
        let store = try ItemStore(url: nil)
        let engine = engine(store: store, identity: identity)
        try await engine.syncAll()

        let newRepo = try await engine.encrypt(repo: "drive-notes")
        #expect(fake.sync { fake.repos["drive-notes"] } == nil)
        let root = try #require(try store.item(repo: newRepo, path: ""))
        #expect(root.filename == "notes")
        #expect(Set(try store.children(of: root.id).map(\.filename)) == ["diary.txt", "empty"])
        let diary = try #require(try store.item(repo: newRepo, path: "diary.txt"))
        #expect(try String(contentsOf: try await engine.download(id: diary.id).0, encoding: .utf8) == "dear diary")
    }
}
