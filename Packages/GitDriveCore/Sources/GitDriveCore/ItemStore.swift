import Foundation
import GRDB

/// One file or folder in the drive. IDs are random and stay the same across renames and moves.
public struct ItemRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: String
    /// Repo name, for example `drive-photos`.
    public var repo: String
    /// Path inside the repo. Empty for the repo's own folder.
    public var path: String
    public var parentID: String
    public var isDirectory: Bool
    /// Blob SHA for files, nil for folders.
    public var sha: String?
    public var size: Int64
    public var modified: Date
    /// Change sequence number, used as the File Provider sync anchor.
    public var seq: Int64
    /// Name shown for a repo's own folder when it differs from the repo name (encrypted folders).
    public var displayName: String?

    public init(
        id: String, repo: String, path: String, parentID: String, isDirectory: Bool, sha: String?,
        size: Int64, modified: Date, seq: Int64, displayName: String? = nil
    ) {
        self.id = id
        self.repo = repo
        self.path = path
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.sha = sha
        self.size = size
        self.modified = modified
        self.seq = seq
        self.displayName = displayName
    }

    public var filename: String {
        if path.isEmpty { return displayName ?? String(repo.dropFirst(Reserved.repoPrefix.count)) }
        return String(path.split(separator: "/").last ?? "")
    }
}

public struct RepoRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repos"
    public var name: String
    public var owner: String
    public var branch: String
    /// Last commit the store reflects. Nil until the first sync.
    public var head: String?
    public var sizeKB: Int
}

public struct ChangeSet: Sendable {
    public var updated: [ItemRecord]
    public var deleted: [String]
    public var anchor: Int64
}

/// SQLite index of everything in the drive. Owned by the File Provider extension.
public final class ItemStore: Sendable {
    /// Raw value of `NSFileProviderItemIdentifier.rootContainer`.
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"

    private let db: DatabaseQueue

    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            db = try DatabaseQueue(path: url.path)
        } else {
            db = try DatabaseQueue()
        }
        try migrator.migrate(db)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("repo", .text).notNull()
                t.column("path", .text).notNull()
                t.column("parentID", .text).notNull().indexed()
                t.column("isDirectory", .boolean).notNull()
                t.column("sha", .text)
                t.column("size", .integer).notNull()
                t.column("modified", .datetime).notNull()
                t.column("seq", .integer).notNull().indexed()
                t.uniqueKey(["repo", "path"])
            }
            try db.create(table: "repos") { t in
                t.primaryKey("name", .text)
                t.column("owner", .text).notNull()
                t.column("branch", .text).notNull()
                t.column("head", .text)
                t.column("sizeKB", .integer).notNull()
            }
            try db.create(table: "tombstones") { t in
                t.primaryKey("id", .text)
                t.column("parentID", .text).notNull()
                t.column("seq", .integer).notNull().indexed()
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .integer).notNull()
            }
        }
        m.registerMigration("v2-display-name") { db in
            try db.alter(table: "items") { t in t.add(column: "displayName", .text) }
        }
        return m
    }

    // MARK: Reads

    public func item(id: String) throws -> ItemRecord? {
        try db.read { try ItemRecord.fetchOne($0, key: id) }
    }

    public func item(repo: String, path: String) throws -> ItemRecord? {
        try db.read { try ItemRecord.filter(Column("repo") == repo && Column("path") == path).fetchOne($0) }
    }

    public func children(of parentID: String) throws -> [ItemRecord] {
        try db.read { try ItemRecord.filter(Column("parentID") == parentID).order(Column("path")).fetchAll($0) }
    }

    public func allItems() throws -> [ItemRecord] {
        try db.read { try ItemRecord.order(Column("repo"), Column("path")).fetchAll($0) }
    }

    public func items(inRepo repo: String) throws -> [ItemRecord] {
        try db.read { try ItemRecord.filter(Column("repo") == repo).fetchAll($0) }
    }

    /// Everything strictly inside a folder, at any depth.
    public func descendants(of item: ItemRecord) throws -> [ItemRecord] {
        try db.read { db in
            let all = try ItemRecord.filter(Column("repo") == item.repo).fetchAll(db)
            if item.path.isEmpty { return all.filter { !$0.path.isEmpty } }
            return all.filter { $0.path.hasPrefix(item.path + "/") }
        }
    }

    public func repo(named name: String) throws -> RepoRecord? {
        try db.read { try RepoRecord.fetchOne($0, key: name) }
    }

    public func repos() throws -> [RepoRecord] {
        try db.read { try RepoRecord.order(Column("name")).fetchAll($0) }
    }

    public func currentAnchor() throws -> Int64 {
        try db.read { try Int64.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'seq'") ?? 0 }
    }

    /// Items and deletions after `anchor`. Pass `parentID` to limit to one folder.
    public func changes(since anchor: Int64, parentID: String? = nil) throws -> ChangeSet {
        try db.read { db in
            var updated = ItemRecord.filter(Column("seq") > anchor)
            var deleted = Table("tombstones").filter(Column("seq") > anchor)
            if let parentID {
                updated = updated.filter(Column("parentID") == parentID)
                deleted = deleted.filter(Column("parentID") == parentID)
            }
            let ids = try String.fetchAll(db, deleted.select(Column("id")))
            let now = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'seq'") ?? 0
            return ChangeSet(updated: try updated.fetchAll(db), deleted: ids, anchor: now)
        }
    }

    // MARK: Writes

    public func saveRepo(_ repo: RepoRecord) throws {
        try db.write { try repo.save($0) }
    }

    public func write<T>(_ body: (Writer) throws -> T) throws -> T {
        try db.write { db in try body(Writer(db: db)) }
    }

    /// Write access inside one transaction. Every change gets the next sequence number.
    public struct Writer {
        let db: Database

        public func nextSeq() throws -> Int64 {
            let next = (try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'seq'") ?? 0) + 1
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('seq', ?)", arguments: [next])
            return next
        }

        public func upsert(_ item: ItemRecord) throws {
            var item = item
            item.seq = try nextSeq()
            try item.save(db)
            try db.execute(sql: "DELETE FROM tombstones WHERE id = ?", arguments: [item.id])
        }

        public func delete(_ item: ItemRecord) throws {
            let seq = try nextSeq()
            _ = try ItemRecord.deleteOne(db, key: item.id)
            try db.execute(
                sql: "INSERT OR REPLACE INTO tombstones (id, parentID, seq) VALUES (?, ?, ?)",
                arguments: [item.id, item.parentID, seq]
            )
        }

        public func item(repo: String, path: String) throws -> ItemRecord? {
            try ItemRecord.filter(Column("repo") == repo && Column("path") == path).fetchOne(db)
        }

        public func item(id: String) throws -> ItemRecord? {
            try ItemRecord.fetchOne(db, key: id)
        }

        public func items(inRepo repo: String) throws -> [ItemRecord] {
            try ItemRecord.filter(Column("repo") == repo).fetchAll(db)
        }

        public func saveRepo(_ repo: RepoRecord) throws {
            try repo.save(db)
        }

        public func repo(named name: String) throws -> RepoRecord? {
            try RepoRecord.fetchOne(db, key: name)
        }

        public func repos() throws -> [RepoRecord] {
            try RepoRecord.fetchAll(db)
        }

        public func deleteRepo(named name: String) throws {
            _ = try RepoRecord.deleteOne(db, key: name)
        }

        /// Points every item at a renamed repo. Only the repo's own folder needs a new version.
        public func renameRepo(_ old: String, to new: String) throws {
            try db.execute(sql: "UPDATE items SET repo = ? WHERE repo = ?", arguments: [new, old])
            try db.execute(sql: "UPDATE repos SET name = ? WHERE name = ?", arguments: [new, old])
            if var folder = try item(repo: new, path: "") {
                folder.modified = Date()
                try upsert(folder)
            }
        }
    }
}
