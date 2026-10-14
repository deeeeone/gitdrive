import CryptoKit
import Foundation

/// The decrypted contents of `.gitdrive/index`: everything about an encrypted folder except file data.
public struct VaultIndex: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        /// Content ID: a keyed hash of the chunk list. Used as the item's "blob SHA" in the sync engine.
        public var c: String
        /// Size in bytes.
        public var s: Int64
        /// Modification date, seconds since 1970.
        public var m: Double
        /// Chunk IDs in order.
        public var k: [String]
    }

    public struct Location: Codable, Sendable, Equatable {
        /// Pack ID.
        public var p: String
        /// Offset in the pack.
        public var o: Int
        /// Sealed length.
        public var l: Int
    }

    public var v = 1
    /// The folder's real name, shown in Finder.
    public var name: String
    public var files: [String: File] = [:]
    public var chunks: [String: Location] = [:]

    public init(name: String) {
        self.name = name
    }

    /// Files and the folders implied by their paths, in the same shape as a git tree.
    public var treeEntries: [TreeEntry] {
        var dirs = Set<String>()
        for path in files.keys {
            var parent = parentPath(of: path)
            while !parent.isEmpty, dirs.insert(parent).inserted { parent = parentPath(of: parent) }
        }
        let folders = dirs.map { TreeEntry(path: $0, mode: "040000", type: .tree, sha: "") }
        let blobs = files.map { TreeEntry(path: $0.key, type: .blob, sha: $0.value.c, size: $0.value.s) }
        return folders + blobs
    }

    public var dates: [String: Date] {
        files.mapValues { Date(timeIntervalSince1970: $0.m) }
    }

    public func file(withContent id: String) -> File? {
        files.values.first { $0.c == id }
    }

    /// Packs still holding at least one chunk that a file uses.
    public var livePacks: Set<String> {
        let used = Set(files.values.flatMap(\.k))
        return Set(chunks.filter { used.contains($0.key) }.map(\.value.p))
    }

    /// Drops chunk locations nothing refers to, so dead packs can be removed from the repo.
    public mutating func pruneChunks() {
        let used = Set(files.values.flatMap(\.k))
        chunks = chunks.filter { used.contains($0.key) }
    }

    public static func contentID(chunks: [String], size: Int64) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(size):".utf8))
        for id in chunks { hasher.update(data: Data(id.utf8)) }
        return hasher.finalize().prefix(20).hex
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> VaultIndex {
        do { return try JSONDecoder().decode(VaultIndex.self, from: data) }
        catch { throw VaultError.corrupt("index contents") }
    }

    static func packPath(_ id: String) -> String { "p/\(id.prefix(2))/\(id)" }
}

extension Reserved {
    public static let vaultFile = ".gitdrive/vault.json"
    public static let indexFile = ".gitdrive/index"
}
