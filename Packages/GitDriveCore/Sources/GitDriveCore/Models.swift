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

    /// `.gitattributes` at the repo root, which GitDrive manages for LFS.
    public static let attributesFile = ".gitattributes"

    public static func isHidden(path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.first.map(String.init) == metaFolder || path == attributesFile || path == ".github/workflows/gitdrive-run.yml" { return true }
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

/// Whether a filename is a conflict copy made by `conflictPath(for:)`.
public func isConflictCopy(_ filename: String) -> Bool {
    filename.contains(" (conflict from Mac ")
}

/// The original file a conflict copy was made from: "notes (conflict from Mac …).txt" → "notes.txt".
public func originalPath(ofConflictCopy path: String) -> String? {
    guard let start = path.range(of: " (conflict from Mac "), let end = path.range(of: ")", range: start.upperBound..<path.endIndex) else {
        return nil
    }
    return String(path[..<start.lowerBound]) + String(path[end.upperBound...])
}

public func parentPath(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
}

public func joinPath(_ parent: String, _ name: String) -> String {
    parent.isEmpty ? name : "\(parent)/\(name)"
}

/// A Git LFS object: the SHA-256 of the real file and its size.
public struct LFSObject: Codable, Sendable, Equatable {
    public let oid: String
    public let size: Int64

    public init(oid: String, size: Int64) {
        self.oid = oid
        self.size = size
    }

    /// The small text file git stores in place of the real contents.
    public var pointer: Data {
        Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(size)\n".utf8)
    }

    /// Parses a pointer file. Returns nil for anything else.
    public static func parse(pointer data: Data) -> LFSObject? {
        guard data.count < 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("version https://git-lfs.github.com/spec/v1") else { return nil }
        var oid: String?
        var size: Int64?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("oid sha256:") { oid = String(line.dropFirst("oid sha256:".count)) }
            if line.hasPrefix("size ") { size = Int64(line.dropFirst("size ".count)) }
        }
        guard let oid, let size else { return nil }
        return LFSObject(oid: oid, size: size)
    }
}

/// Contents of `.gitdrive/meta.json`. Kept sorted and pretty-printed so diffs on GitHub stay readable.
public struct DriveMeta: Codable, Sendable, Equatable {
    public var version = 1
    /// Repo path to the file's last modification date.
    public var modified: [String: Date] = [:]
    /// Repo path to the LFS object behind its pointer file.
    public var lfs: [String: LFSObject] = [:]
    /// Blob SHA to photo facts and the blob SHA of its thumbnail, so they follow renames for free.
    public var media: [String: MediaRef] = [:]

    public struct MediaRef: Codable, Sendable, Equatable {
        public var thumb: String?
        public var taken: Date?
        public var latitude: Double?
        public var longitude: Double?
    }

    public init(modified: [String: Date] = [:], lfs: [String: LFSObject] = [:]) {
        self.modified = modified
        self.lfs = lfs
    }

    enum CodingKeys: String, CodingKey { case version, modified, lfs, media }

    /// Missing keys are fine, so files written by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        modified = try c.decodeIfPresent([String: Date].self, forKey: .modified) ?? [:]
        lfs = try c.decodeIfPresent([String: LFSObject].self, forKey: .lfs) ?? [:]
        media = try c.decodeIfPresent([String: MediaRef].self, forKey: .media) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(modified, forKey: .modified)
        if !lfs.isEmpty { try c.encode(lfs, forKey: .lfs) }
        if !media.isEmpty { try c.encode(media, forKey: .media) }
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

/// Builds the GitDrive-managed part of `.gitattributes`, keeping any lines the user wrote.
public enum GitAttributes {
    static let begin = "# >>> GitDrive LFS (managed, do not edit)"
    static let end = "# <<< GitDrive LFS"

    public static func update(_ existing: String, lfsPaths: [String]) -> String {
        var kept: [String] = []
        var inBlock = false
        for line in existing.components(separatedBy: "\n") {
            if line == begin { inBlock = true; continue }
            if line == end { inBlock = false; continue }
            if !inBlock { kept.append(line) }
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        guard !lfsPaths.isEmpty else { return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n" }
        let rules = lfsPaths.sorted().map { "/\(escape($0)) filter=lfs diff=lfs merge=lfs -text" }
        let block = [begin] + rules + [end]
        return (kept.isEmpty ? block : kept + [""] + block).joined(separator: "\n") + "\n"
    }

    /// gitattributes patterns can't contain plain spaces, and some characters are glob syntax.
    static func escape(_ path: String) -> String {
        var out = ""
        for ch in path {
            switch ch {
            case " ": out += "[[:space:]]"
            case "*", "?", "[", "]", "\\", "!", "#": out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        return out
    }
}

extension Date {
    /// ISO 8601 in the meta file keeps whole seconds, so dates are rounded before comparing.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
