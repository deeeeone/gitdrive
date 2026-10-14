import Foundation

/// Set when the tripwire fires, until the user rolls back or resumes.
public struct TripwireState: Codable, Sendable, Equatable {
    public var trippedAt: Date
    public var count: Int
    public var examples: [String]

    public init(trippedAt: Date, count: Int, examples: [String]) {
        self.trippedAt = trippedAt
        self.count = count
        self.examples = examples
    }
}

extension AppConfig {
    public static var tripwire: TripwireState? {
        get { (sharedDefaults?.data(forKey: "tripwire")).flatMap { try? JSONDecoder().decode(TripwireState.self, from: $0) } }
        set { sharedDefaults?.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "tripwire") }
    }
}

/// Watches overwritten files for the tell-tale sign of ransomware: ordinary files suddenly becoming
/// random data. Fires after `threshold` such files within `window`.
public final class Tripwire: @unchecked Sendable {
    public let threshold: Int
    public let window: TimeInterval
    private let lock = NSLock()
    private var hits: [(Date, String)] = []

    public init(threshold: Int = 25, window: TimeInterval = 600) {
        self.threshold = threshold
        self.window = window
    }

    /// Formats that are random-looking by design, so they never count.
    static let compressed: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "mp4", "mov", "m4v", "mkv", "webm", "mp3", "m4a", "aac",
        "flac", "ogg", "opus", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "pkg", "ipa", "apk", "jar", "pdf",
        "docx", "xlsx", "pptx", "pages", "numbers", "key", "epub", "woff", "woff2", "gpg", "age", "enc",
    ]

    /// Shannon entropy of the first 64 KB, in bits per byte. Encrypted data is close to 8.
    public static func entropy(of file: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: 64 * 1024), sample.count >= 4096 else { return nil }
        var counts = [Int](repeating: 0, count: 256)
        for byte in sample { counts[Int(byte)] += 1 }
        let total = Double(sample.count)
        return counts.reduce(0) { sum, c in
            guard c > 0 else { return sum }
            let p = Double(c) / total
            return sum - p * log2(p)
        }
    }

    public static func looksEncrypted(_ file: URL, name: String) -> Bool {
        guard !compressed.contains((name as NSString).pathExtension.lowercased()) else { return false }
        return (entropy(of: file) ?? 0) > 7.9
    }

    /// Records an overwrite. Returns true when this one trips the wire.
    public func record(_ file: URL, name: String, at date: Date = Date()) -> Bool {
        guard Self.looksEncrypted(file, name: name) else { return false }
        return lock.withLock {
            hits.append((date, name))
            hits.removeAll { date.timeIntervalSince($0.0) > window }
            return hits.count >= threshold
        }
    }

    public var recentNames: [String] { lock.withLock { hits.suffix(5).map(\.1) } }
    public var recentCount: Int { lock.withLock { hits.count } }
}

extension SyncEngine {
    /// Puts every top-level folder back to how it was at `date`, as a new commit on top of the current
    /// one (nothing is force-pushed, so the rolled-back changes stay in history). Returns the folders changed.
    public func rollBack(to date: Date, only: Set<String>? = nil) async throws -> [String] {
        try await syncRepoListIfStale(maxAge: 0)
        var changed: [String] = []
        for rec in try store.repos() where only?.contains(rec.name) ?? true {
            guard let before = try await client.commits(owner: rec.owner, repo: rec.name, until: date, limit: 1).first else { continue }
            let head = try await client.headSHA(owner: rec.owner, repo: rec.name, branch: rec.branch)
            guard head != before.sha else { continue }
            let tree = try await client.treeSHA(owner: rec.owner, repo: rec.name, commit: before.sha)
            guard tree != (try await client.treeSHA(owner: rec.owner, repo: rec.name, commit: head)) else { continue }
            let commit = try await client.createCommit(
                owner: rec.owner, repo: rec.name, message: isVault(rec.name) ? "Update" : "Roll back to \(before.date.formatted())",
                tree: tree, parents: [head]
            )
            try await client.updateRef(owner: rec.owner, repo: rec.name, branch: rec.branch, sha: commit)
            changed.append(rec.name)
            try await syncRepo(rec.name)
        }
        return changed
    }
}
