import Foundation

/// Names GitDrive uses inside repos and never shows in Finder.
public enum Reserved {
    /// Placeholder that keeps an otherwise empty folder in git.
    public static let keepFile = ".gitdrive-keep"
    /// Folder for GitDrive's own metadata.
    public static let metaFolder = ".gitdrive"
    /// File holding each file's modification date, since git doesn't store them.
    public static let metaFile = ".gitdrive/meta.json"
    /// Prefix that marks a repo as a GitDrive folder.
    public static let repoPrefix = "drive-"

    public static func isHidden(path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.first.map(String.init) == metaFolder { return true }
        return parts.last.map(String.init) == keepFile
    }

    /// Files the OS creates that should stay local.
    public static func isIgnored(filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._") || filename == ".localized"
    }
}

/// GitHub limits a single file to 100 MB.
public let maxFileSize: Int64 = 100 * 1024 * 1024

public struct Repo: Codable, Sendable, Equatable {
    public struct Owner: Codable, Sendable, Equatable { public let login: String }
    public let name: String
    public let owner: Owner
    public let defaultBranch: String?
    /// Size in KB, as reported by GitHub.
    public let size: Int
    public let archived: Bool
    public let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case name, owner, size, archived
        case defaultBranch = "default_branch"
        case isPrivate = "private"
    }

    public init(name: String, owner: String, defaultBranch: String?, size: Int, archived: Bool = false, isPrivate: Bool = true) {
        self.name = name
        self.owner = Owner(login: owner)
        self.defaultBranch = defaultBranch
        self.size = size
        self.archived = archived
        self.isPrivate = isPrivate
    }

    public var isDrive: Bool { name.hasPrefix(Reserved.repoPrefix) }
    /// Folder name shown in Finder.
    public var displayName: String { String(name.dropFirst(Reserved.repoPrefix.count)) }
}

public struct TreeEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case blob, tree, commit }
    public let path: String
    public let mode: String
    public let type: Kind
    public let sha: String
    public let size: Int64?

    public init(path: String, mode: String = "100644", type: Kind, sha: String, size: Int64? = nil) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
        self.size = size
    }
}

public struct GitTree: Decodable, Sendable {
    public let sha: String
    public let tree: [TreeEntry]
    public let truncated: Bool
}

/// One path-level edit in a commit. A nil `sha` deletes the path.
public struct TreeChange: Encodable, Sendable, Equatable {
    public let path: String
    public let sha: String?
    public let mode: String
    /// The blob this edit was based on. If the remote blob differs, the edit is saved as a conflict copy.
    public let baseSHA: String?

    public init(path: String, sha: String?, mode: String = "100644", baseSHA: String? = nil) {
        self.path = path
        self.sha = sha
        self.mode = mode
        self.baseSHA = baseSHA
    }

    enum CodingKeys: String, CodingKey { case path, sha, mode, type }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(mode, forKey: .mode)
        try c.encode("blob", forKey: .type)
        // GitHub deletes a path when sha is an explicit null.
        try c.encode(sha, forKey: .sha)
    }

    public func moved(to newPath: String) -> TreeChange {
        TreeChange(path: newPath, sha: sha, mode: mode, baseSHA: baseSHA)
    }
}

/// Builds the name for a conflict copy, keeping the extension: "notes (conflict from Mac 2026-10-13).txt".
public func conflictPath(for path: String, date: Date = Date()) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd HH.mm"
    let stamp = "conflict from Mac \(fmt.string(from: date))"
    let dir = parentPath(of: path)
    let file = dir.isEmpty ? path : String(path.dropFirst(dir.count + 1))
    let name: String
    if let dot = file.lastIndex(of: "."), dot != file.startIndex {
        name = "\(file[..<dot]) (\(stamp))\(file[dot...])"
    } else {
        name = "\(file) (\(stamp))"
    }
    return joinPath(dir, name)
}

public func parentPath(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

public func joinPath(_ parent: String, _ name: String) -> String {
    parent.isEmpty ? name : "\(parent)/\(name)"
}

/// Contents of `.gitdrive/meta.json`. Kept sorted and pretty-printed so diffs on GitHub stay readable.
public struct DriveMeta: Codable, Sendable, Equatable {
    public var version = 1
    /// Repo path to the file's last modification date.
    public var modified: [String: Date] = [:]

    public init(modified: [String: Date] = [:]) {
        self.modified = modified
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> DriveMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(DriveMeta.self, from: data)) ?? DriveMeta()
    }
}

extension Date {
    /// ISO 8601 in the meta file keeps whole seconds, so dates are rounded before comparing.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
