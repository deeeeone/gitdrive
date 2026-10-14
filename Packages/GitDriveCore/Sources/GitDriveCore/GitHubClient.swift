import CryptoKit
import Foundation
import os

public struct GitHubError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case unauthorized
        case notFound
        /// The repo has no commits yet.
        case emptyRepo
        /// A ref update was not a fast-forward.
        case conflict
        case rateLimited(retryAfter: TimeInterval)
        case tooLarge
        case server(status: Int)
        case transport
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// Thin async client for the parts of the GitHub REST API that GitDrive uses.
public actor GitHubClient {
    public nonisolated let baseURL: URL
    /// Host for git and LFS endpoints, which live on github.com rather than the API host.
    public nonisolated let gitURL: URL
    private let session: URLSession
    private let token: String
    private var etags: [URL: (etag: String, body: Data)] = [:]
    private let log = Logger(subsystem: "com.diwan.gitdrive", category: "github")

    public init(
        token: String,
        baseURL: URL = URL(string: "https://api.github.com")!,
        gitURL: URL = URL(string: "https://github.com")!,
        session: URLSession = GitHubClient.makeSession()
    ) {
        self.token = token
        self.baseURL = baseURL
        self.gitURL = gitURL
        self.session = session
    }

    /// No HTTP cache: GitHub marks responses cacheable for 60 s, which would hide fresh commits.
    /// Freshness comes from the ETag cache below instead.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }

    // MARK: Users and repos

    public struct User: Decodable, Sendable { public let login: String }

    public func currentUser() async throws -> User {
        try await get("user")
    }

    /// Scopes of a classic token, from GitHub's `X-OAuth-Scopes` header. Nil for fine-grained tokens,
    /// which don't report scopes.
    public func tokenScopes() async throws -> Set<String>? {
        let (_, http) = try await perform(request("GET", "user"))
        guard let header = http.value(forHTTPHeaderField: "X-OAuth-Scopes") else { return nil }
        return Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// All repos the user owns, across pages.
    public func ownedRepos() async throws -> [Repo] {
        var all: [Repo] = []
        var page = 1
        while true {
            let batch: [Repo] = try await get("user/repos", query: [
                "affiliation": "owner", "per_page": "100", "page": "\(page)", "sort": "full_name",
            ])
            all += batch
            if batch.count < 100 { return all }
            page += 1
        }
    }

    /// Repos that make up the drive: owned, not archived, named `drive-*`.
    public func driveRepos() async throws -> [Repo] {
        try await ownedRepos().filter { $0.isDrive && !$0.archived }
    }

    /// Creates a private repo with a first commit, so the Git Data API works on it right away.
    public func createDriveRepo(folderName: String) async throws -> Repo {
        struct Body: Encodable {
            let name: String
            let `private` = true
            let description = "GitDrive folder"
            let auto_init = false
            let has_issues = false
            let has_wiki = false
            let has_projects = false
        }
        let repo: Repo = try await send("POST", "user/repos", body: Body(name: Reserved.repoPrefix + folderName))
        struct Put: Encodable { let message: String; let content: String }
        let _: EmptyResponse = try await send(
            "PUT", "repos/\(repo.owner.login)/\(repo.name)/contents/\(Reserved.keepFile)",
            body: Put(message: "Create GitDrive folder", content: "")
        )
        let fresh: Repo = try await get("repos/\(repo.owner.login)/\(repo.name)")
        return fresh
    }

    public func renameRepo(owner: String, name: String, to newName: String) async throws -> Repo {
        struct Body: Encodable { let name: String }
        return try await send("PATCH", "repos/\(owner)/\(name)", body: Body(name: newName))
    }

    /// Deletes a repo permanently. GitHub requires the `delete_repo` scope for this.
    public func deleteRepo(owner: String, name: String) async throws {
        var req = request("DELETE", "repos/\(owner)/\(name)")
        req.httpBody = nil
        do {
            _ = try await perform(req)
        } catch let e as GitHubError where e.kind == .server(status: 403) || e.kind == .notFound {
            throw GitHubError(
                .server(status: 403),
                "GitHub didn't allow deleting \(name). Sign in again with a token that has the delete_repo scope, "
                    + "or choose Archive in GitDrive Settings."
            )
        }
    }

    /// Archives a repo. It stays on GitHub, read-only, and can be unarchived later.
    public func archiveRepo(owner: String, name: String) async throws {
        struct Body: Encodable { let archived = true }
        let _: Repo = try await send("PATCH", "repos/\(owner)/\(name)", body: Body())
    }

    // MARK: Git data

    /// The commit SHA at the tip of `branch`. Throws `.emptyRepo` for repos with no commits.
    public func headSHA(owner: String, repo: String, branch: String) async throws -> String {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        do {
            let ref: Ref = try await get("repos/\(owner)/\(repo)/git/ref/heads/\(branch)", cache: true)
            return ref.object.sha
        } catch let e as GitHubError where e.kind == .notFound || e.kind == .server(status: 409) {
            throw GitHubError(.emptyRepo, "\(repo) has no commits yet")
        }
    }

    public func treeSHA(owner: String, repo: String, commit: String) async throws -> String {
        try await commitInfo(owner: owner, repo: repo, commit: commit).tree
    }

    /// The commit's tree and its committer date.
    public func commitInfo(owner: String, repo: String, commit: String) async throws -> (tree: String, date: Date?) {
        struct Commit: Decodable {
            struct Tree: Decodable { let sha: String }
            struct Person: Decodable { let date: String? }
            let tree: Tree
            let committer: Person?
        }
        let c: Commit = try await get("repos/\(owner)/\(repo)/git/commits/\(commit)", cache: true)
        return (c.tree.sha, c.committer?.date.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    public func tree(owner: String, repo: String, sha: String, recursive: Bool) async throws -> GitTree {
        try await get(
            "repos/\(owner)/\(repo)/git/trees/\(sha)",
            query: recursive ? ["recursive": "1"] : [:],
            cache: true
        )
    }

    /// Every entry under a tree. Falls back to walking subtrees when GitHub truncates a large recursive listing.
    public func fullTree(owner: String, repo: String, sha: String) async throws -> [TreeEntry] {
        let top = try await tree(owner: owner, repo: repo, sha: sha, recursive: true)
        if !top.truncated { return top.tree }
        log.info("Tree for \(repo, privacy: .public) is truncated, walking subtrees")
        return try await walk(owner: owner, repo: repo, sha: sha, prefix: "")
    }

    private func walk(owner: String, repo: String, sha: String, prefix: String) async throws -> [TreeEntry] {
        let level = try await tree(owner: owner, repo: repo, sha: sha, recursive: false)
        var out: [TreeEntry] = []
        for e in level.tree {
            let path = joinPath(prefix, e.path)
            out.append(TreeEntry(path: path, mode: e.mode, type: e.type, sha: e.sha, size: e.size))
            if e.type == .tree {
                out += try await walk(owner: owner, repo: repo, sha: e.sha, prefix: path)
            }
        }
        return out
    }

    /// Downloads a blob's raw bytes to a temporary file.
    public func downloadBlob(owner: String, repo: String, sha: String) async throws -> URL {
        var req = request("GET", "repos/\(owner)/\(repo)/git/blobs/\(sha)")
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let rawRequest = req
        return try await withRetry {
            let (url, response) = try await self.session.download(for: rawRequest)
            guard let http = response as? HTTPURLResponse else { throw GitHubError(.transport, "No HTTP response") }
            if !(200..<300).contains(http.statusCode) {
                let body = (try? Data(contentsOf: url)) ?? Data()
                throw Self.error(for: http, body: body)
            }
            return url
        }
    }

    /// A blob's bytes in memory. Only for small files such as GitDrive's own metadata.
    public func blobData(owner: String, repo: String, sha: String) async throws -> Data {
        let url = try await downloadBlob(owner: owner, repo: repo, sha: sha)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    public func createBlob(owner: String, repo: String, contentsOf file: URL) async throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard Int64(data.count) <= maxFileSize else {
            throw GitHubError(.tooLarge, "\(file.lastPathComponent) is larger than GitHub's 100 MB file limit")
        }
        return try await createBlob(owner: owner, repo: repo, data: data)
    }

    public func createBlob(owner: String, repo: String, data: Data) async throws -> String {
        struct Body: Encodable { let content: String; let encoding = "base64" }
        struct Out: Decodable { let sha: String }
        let out: Out = try await send("POST", "repos/\(owner)/\(repo)/git/blobs", body: Body(content: data.base64EncodedString()))
        return out.sha
    }

    public func createTree(owner: String, repo: String, base: String, changes: [TreeChange]) async throws -> String {
        struct Body: Encodable { let base_tree: String; let tree: [TreeChange] }
        struct Out: Decodable { let sha: String }
        let out: Out = try await send("POST", "repos/\(owner)/\(repo)/git/trees", body: Body(base_tree: base, tree: changes))
        return out.sha
    }

    public func createCommit(owner: String, repo: String, message: String, tree: String, parents: [String]) async throws -> String {
        struct Body: Encodable { let message: String; let tree: String; let parents: [String] }
        struct Out: Decodable { let sha: String }
        let out: Out = try await send(
            "POST", "repos/\(owner)/\(repo)/git/commits",
            body: Body(message: message, tree: tree, parents: parents)
        )
        return out.sha
    }

    /// Moves a branch. Throws `.conflict` when it is not a fast-forward and `force` is false.
    public func updateRef(owner: String, repo: String, branch: String, sha: String, force: Bool = false) async throws {
        struct Body: Encodable { let sha: String; let force: Bool }
        do {
            let _: EmptyResponse = try await send(
                "PATCH", "repos/\(owner)/\(repo)/git/refs/heads/\(branch)",
                body: Body(sha: sha, force: force)
            )
        } catch let e as GitHubError where e.kind == .server(status: 422) {
            throw GitHubError(.conflict, "\(repo) changed on GitHub while saving")
        }
    }

    // MARK: History

    public struct CommitSummary: Sendable, Hashable {
        public let sha: String
        public let message: String
        public let date: Date
        public let parents: [String]
    }

    /// Recent commits, newest first, optionally only those touching `path` or made after `since`.
    public func commits(owner: String, repo: String, path: String? = nil, since: Date? = nil, until: Date? = nil, limit: Int = 30) async throws -> [CommitSummary] {
        struct Item: Decodable {
            struct Inner: Decodable { struct Person: Decodable { let date: String }; let message: String; let committer: Person }
            struct Parent: Decodable { let sha: String }
            let sha: String
            let commit: Inner
            let parents: [Parent]
        }
        var query = ["per_page": "\(min(limit, 100))"]
        if let path { query["path"] = path }
        let iso = ISO8601DateFormatter()
        if let since { query["since"] = iso.string(from: since) }
        if let until { query["until"] = iso.string(from: until) }
        let items: [Item] = try await get("repos/\(owner)/\(repo)/commits", query: query)
        return items.map {
            CommitSummary(sha: $0.sha, message: $0.commit.message, date: iso.date(from: $0.commit.committer.date) ?? .distantPast, parents: $0.parents.map(\.sha))
        }
    }

    /// The blob SHA and size of a file at a given commit, or nil if it didn't exist then.
    public func fileAt(owner: String, repo: String, path: String, ref: String) async throws -> (sha: String, size: Int64)? {
        struct Content: Decodable { let sha: String; let size: Int64; let type: String }
        do {
            let c: Content = try await get("repos/\(owner)/\(repo)/contents/\(path)", query: ["ref": ref])
            return c.type == "file" ? (c.sha, c.size) : nil
        } catch let e as GitHubError where e.kind == .notFound {
            return nil
        }
    }

    public struct ChangedFile: Decodable, Sendable {
        public let filename: String
        public let status: String
    }

    /// Files a commit added, modified, removed or renamed.
    public func changedFiles(owner: String, repo: String, commit: String) async throws -> [ChangedFile] {
        struct Detail: Decodable { let files: [ChangedFile]? }
        let detail: Detail = try await get("repos/\(owner)/\(repo)/commits/\(commit)", cache: true)
        return detail.files ?? []
    }

    // MARK: Git LFS

    /// GitHub's LFS limit for a single file on Free and Pro plans.
    public static let maxLFSFileSize: Int64 = 2 * 1024 * 1024 * 1024

    private struct LFSAction: Decodable { let href: URL; let header: [String: String]? }
    private struct LFSBatchObject: Decodable {
        struct Err: Decodable { let message: String }
        let oid: String
        let actions: [String: LFSAction]?
        let error: Err?
    }

    private func lfsBatch(owner: String, repo: String, operation: String, object: LFSObject) async throws -> LFSBatchObject {
        struct Body: Encodable {
            struct Obj: Encodable { let oid: String; let size: Int64 }
            let operation: String
            let transfers = ["basic"]
            let objects: [Obj]
        }
        struct Reply: Decodable { let objects: [LFSBatchObject] }
        var req = URLRequest(url: gitURL.appendingPathComponent("\(owner)/\(repo).git/info/lfs/objects/batch"))
        req.httpMethod = "POST"
        req.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Accept")
        req.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
        req.setValue("Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("GitDrive", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONEncoder().encode(Body(operation: operation, objects: [.init(oid: object.oid, size: object.size)]))
        let (data, _) = try await perform(req)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let first = reply.objects.first else {
            throw GitHubError(.transport, "Unexpected reply from GitHub LFS")
        }
        if let error = first.error { throw GitHubError(.server(status: 422), "Git LFS: \(error.message)") }
        return first
    }

    /// Hashes a file without loading it all into memory.
    public static func lfsObject(for file: URL) throws -> LFSObject {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        let oid = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return LFSObject(oid: oid, size: size)
    }

    /// Uploads a file to LFS storage. Skips the upload when GitHub already has the object.
    public func lfsUpload(owner: String, repo: String, file: URL) async throws -> LFSObject {
        let object = try Self.lfsObject(for: file)
        guard object.size <= Self.maxLFSFileSize else {
            throw GitHubError(.tooLarge, "\(file.lastPathComponent) is larger than GitHub's 2 GB Git LFS limit")
        }
        let batch = try await lfsBatch(owner: owner, repo: repo, operation: "upload", object: object)
        if let upload = batch.actions?["upload"] {
            var req = URLRequest(url: upload.href)
            req.httpMethod = "PUT"
            upload.header?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.upload(for: req, fromFile: file)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GitHubError(.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0), "Git LFS upload failed")
            }
            if let verify = batch.actions?["verify"] {
                var v = URLRequest(url: verify.href)
                v.httpMethod = "POST"
                verify.header?.forEach { v.setValue($1, forHTTPHeaderField: $0) }
                v.setValue("application/vnd.git-lfs+json", forHTTPHeaderField: "Content-Type")
                struct Verify: Encodable { let oid: String; let size: Int64 }
                v.httpBody = try JSONEncoder().encode(Verify(oid: object.oid, size: object.size))
                _ = try await perform(v)
            }
        }
        return object
    }

    /// Downloads an LFS object to a temporary file. Counts against the repo owner's LFS bandwidth.
    public func lfsDownload(owner: String, repo: String, object: LFSObject) async throws -> URL {
        let batch = try await lfsBatch(owner: owner, repo: repo, operation: "download", object: object)
        guard let action = batch.actions?["download"] else { throw GitHubError(.notFound, "The LFS object is missing on GitHub") }
        var req = URLRequest(url: action.href)
        action.header?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let request = req
        return try await withRetry {
            let (url, response) = try await self.session.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw GitHubError(.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0), "Git LFS download failed")
            }
            return url
        }
    }

    /// Downloads a file's real contents, following an LFS pointer if the blob is one.
    public func downloadContents(owner: String, repo: String, sha: String) async throws -> URL {
        let url = try await downloadBlob(owner: owner, repo: repo, sha: sha)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < 1024, let data = try? Data(contentsOf: url), let object = LFSObject.parse(pointer: data) else { return url }
        try? FileManager.default.removeItem(at: url)
        return try await lfsDownload(owner: owner, repo: repo, object: object)
    }

    // MARK: Plumbing

    struct EmptyResponse: Decodable {}

    private func request(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GitDrive", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], cache: Bool = false) async throws -> T {
        var req = request("GET", path, query: query)
        let key = req.url!
        if cache, let hit = etags[key] {
            req.setValue(hit.etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, http) = try await perform(req)
        if http.statusCode == 304, let hit = etags[key] {
            return try decode(hit.body)
        }
        if cache, let etag = http.value(forHTTPHeaderField: "ETag") {
            etags[key] = (etag, data)
        }
        return try decode(data)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> T {
        var req = request(method, path)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await perform(req)
        return try decode(data)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError(.transport, "Unexpected response from GitHub: \(error)")
        }
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withRetry {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await self.session.data(for: req)
            } catch {
                throw GitHubError(.transport, error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else { throw GitHubError(.transport, "No HTTP response") }
            if (200..<300).contains(http.statusCode) || http.statusCode == 304 { return (data, http) }
            throw Self.error(for: http, body: data)
        }
    }

    /// Retries rate limits, server errors and network failures with exponential backoff.
    private func withRetry<T: Sendable>(attempts: Int = 4, _ op: @Sendable () async throws -> T) async throws -> T {
        var delay: TimeInterval = 1
        for attempt in 1...attempts {
            do {
                return try await op()
            } catch let e as GitHubError {
                let wait: TimeInterval
                switch e.kind {
                case let .rateLimited(retryAfter): wait = min(retryAfter, 60)
                case let .server(status) where status >= 500: wait = delay
                case .transport: wait = delay
                default: throw e
                }
                if attempt == attempts { throw e }
                log.notice("Retrying in \(wait)s after: \(e.message, privacy: .public)")
                try await Task.sleep(for: .seconds(wait))
                delay *= 2
            }
        }
        preconditionFailure("unreachable")
    }

    static func error(for http: HTTPURLResponse, body: Data) -> GitHubError {
        struct Message: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(Message.self, from: body))?.message ?? "HTTP \(http.statusCode)"
        switch http.statusCode {
        case 401:
            return GitHubError(.unauthorized, "GitHub sign-in expired or was revoked")
        case 403, 429:
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if http.statusCode == 429 || remaining == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil {
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    ?? http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map { $0 - Date().timeIntervalSince1970 }
                    ?? 60
                return GitHubError(.rateLimited(retryAfter: max(retry, 1)), "GitHub rate limit reached")
            }
            return GitHubError(.server(status: 403), message)
        case 404:
            return GitHubError(.notFound, message)
        default:
            return GitHubError(.server(status: http.statusCode), message)
        }
    }
}
