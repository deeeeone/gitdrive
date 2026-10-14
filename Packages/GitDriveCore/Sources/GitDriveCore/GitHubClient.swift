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
    private let session: URLSession
    private let token: String
    private var etags: [URL: (etag: String, body: Data)] = [:]
    private let log = Logger(subsystem: "com.diwan.gitdrive", category: "github")

    public init(token: String, baseURL: URL = URL(string: "https://api.github.com")!, session: URLSession = GitHubClient.makeSession()) {
        self.token = token
        self.baseURL = baseURL
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

    /// Archives instead of deleting, so nothing is ever lost.
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
