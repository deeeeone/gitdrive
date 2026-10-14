import Foundation
@testable import GitDriveCore

/// In-memory stand-in for the GitHub endpoints GitDrive calls. Trees are stored flat (path to blob SHA).
final class FakeGitHub: @unchecked Sendable {
    struct Commit { let tree: String; let parents: [String] }

    private let lock = NSLock()
    var owner = "octo"
    var repos: [String: String] = [:] // repo name -> head commit
    var blobs: [String: Data] = [:]
    var trees: [String: [String: String]] = [:]
    var commits: [String: Commit] = [:]
    var requests: [String] = []
    var lfsObjects: [String: Data] = [:]
    private var counter = 0

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func newSHA() -> String {
        counter += 1
        return String(format: "%040d", counter)
    }

    /// Creates a repo with the given files in one commit.
    func seed(repo: String, files: [String: String]) {
        sync {
            var flat: [String: String] = [:]
            for (path, text) in files {
                let sha = newSHA()
                blobs[sha] = Data(text.utf8)
                flat[path] = sha
            }
            let tree = newSHA()
            trees[tree] = flat
            let commit = newSHA()
            commits[commit] = Commit(tree: tree, parents: [])
            repos[repo] = commit
        }
    }

    /// Simulates someone else pushing a change to `path`.
    func remoteEdit(repo: String, path: String, text: String) {
        sync {
            let head = repos[repo]!
            var flat = trees[commits[head]!.tree]!
            let sha = newSHA()
            blobs[sha] = Data(text.utf8)
            flat[path] = sha
            let tree = newSHA()
            trees[tree] = flat
            let commit = newSHA()
            commits[commit] = Commit(tree: tree, parents: [head])
            repos[repo] = commit
        }
    }

    func files(repo: String) -> [String: String] {
        sync {
            let flat = trees[commits[repos[repo]!]!.tree]!
            return flat.mapValues { String(decoding: blobs[$0]!, as: UTF8.self) }
        }
    }

    func commitCount(repo: String) -> Int {
        sync {
            var n = 0
            var cur: String? = repos[repo]
            while let c = cur { n += 1; cur = commits[c]?.parents.first }
            return n
        }
    }

    // MARK: Routing

    func handle(_ req: URLRequest) -> (Int, Data) {
        sync {
            let method = req.httpMethod ?? "GET"
            let path = req.url!.path
            requests.append("\(method) \(path)")
            let parts = path.split(separator: "/").map(String.init)
            let body = req.httpBody ?? req.httpBodyStream.map(readAll) ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

            if path.hasSuffix(".git/info/lfs/objects/batch") {
                let operation = json["operation"] as! String
                let object = (json["objects"] as! [[String: Any]])[0]
                let oid = object["oid"] as! String
                var actions: [String: Any] = [:]
                let href = ["href": "https://fake.test/lfs/\(oid)", "header": ["X-Fake": "1"]] as [String: Any]
                if operation == "upload", lfsObjects[oid] == nil { actions["upload"] = href }
                if operation == "download" {
                    guard lfsObjects[oid] != nil else {
                        return (200, encode(["objects": [["oid": oid, "error": ["message": "missing"]]]]))
                    }
                    actions["download"] = href
                }
                return (200, encode(["objects": [["oid": oid, "size": object["size"]!, "actions": actions]]]))
            }
            if path.hasPrefix("/lfs/") {
                let oid = String(path.dropFirst("/lfs/".count))
                if method == "PUT" { lfsObjects[oid] = body; return (200, Data()) }
                return lfsObjects[oid].map { (200, $0) } ?? (404, Data())
            }
            // raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>, with Range support.
            if parts.count >= 4, parts[0] == owner, let commit = commits[parts[2]], let ownerRepo = Optional(parts[1]), repos[ownerRepo] != nil {
                let filePath = parts.dropFirst(3).joined(separator: "/").removingPercentEncoding ?? ""
                guard let sha = trees[commit.tree]?[filePath], let data = blobs[sha] else { return (404, Data()) }
                if let range = req.value(forHTTPHeaderField: "Range")?.dropFirst("bytes=".count).split(separator: "-"),
                   let a = Int(range[0]), let b = Int(range[1]) {
                    return (206, data.subdata(in: a..<min(b + 1, data.count)))
                }
                return (200, data)
            }
            if method == "POST", path == "/user/repos" {
                let name = json["name"] as! String
                let tree = newSHA()
                trees[tree] = [:]
                let commit = newSHA()
                commits[commit] = Commit(tree: tree, parents: [])
                repos[name] = commit
                return (201, encode(repoJSON(name)))
            }
            if method == "GET", path == "/user/repos" {
                let list = repos.keys.sorted().map { name -> [String: Any] in
                    ["name": name, "owner": ["login": owner], "default_branch": "main", "size": 1, "archived": false, "private": true]
                }
                return (200, encode(list))
            }
            guard parts.count >= 3, parts[0] == "repos", let head = repos[parts[2]] else { return (404, encode(["message": "Not Found"])) }
            let rest = Array(parts.dropFirst(3))
            if method == "GET", parts.count == 3 { return (200, encode(repoJSON(parts[2]))) }
            if method == "GET", rest == ["commits"] {
                let filter = req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "path" }?.value
                var list: [[String: Any]] = []
                var cur: String? = head
                while let c = cur, let commit = commits[c] {
                    let parent = commit.parents.first
                    let mine = trees[commit.tree]?[filter ?? ""]
                    let before = parent.flatMap { commits[$0] }.flatMap { trees[$0.tree]?[filter ?? ""] }
                    if filter == nil || mine != before {
                        list.append(["sha": c, "commit": ["message": "m", "committer": ["date": "2026-01-02T03:04:05Z"]], "parents": commit.parents.map { ["sha": $0] }])
                    }
                    cur = parent
                }
                return (200, encode(list))
            }
            if method == "GET", rest.count == 2, rest[0] == "commits", let commit = commits[rest[1]] {
                let mine = trees[commit.tree] ?? [:]
                let before = commit.parents.first.flatMap { commits[$0] }.flatMap { trees[$0.tree] } ?? [:]
                var files: [[String: Any]] = []
                for path in Set(mine.keys).union(before.keys).sorted() {
                    switch (before[path], mine[path]) {
                    case (nil, .some): files.append(["filename": path, "status": "added"])
                    case (.some, nil): files.append(["filename": path, "status": "removed"])
                    case let (a?, b?) where a != b: files.append(["filename": path, "status": "modified"])
                    default: break
                    }
                }
                return (200, encode(["files": files]))
            }
            if method == "GET", rest.first == "contents" {
                let filePath = rest.dropFirst().joined(separator: "/")
                let ref = req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "ref" }?.value ?? head
                guard let sha = commits[ref].flatMap({ trees[$0.tree]?[filePath] }) else { return (404, encode(["message": "Not Found"])) }
                return (200, encode(["sha": sha, "size": blobs[sha]?.count ?? 0, "type": "file"]))
            }
            if method == "PUT", rest.first == "contents" {
                let filePath = rest.dropFirst().joined(separator: "/")
                var flat = trees[commits[head]!.tree]!
                let sha = newSHA()
                blobs[sha] = Data(base64Encoded: json["content"] as? String ?? "") ?? Data()
                flat[filePath] = sha
                let tree = newSHA()
                trees[tree] = flat
                let commit = newSHA()
                commits[commit] = Commit(tree: tree, parents: [head])
                repos[parts[2]] = commit
                return (201, encode(["content": ["sha": sha]]))
            }
            if method == "DELETE", parts.count == 3 {
                repos[parts[2]] = nil
                return (204, Data())
            }

            switch (method, rest.first, rest.dropFirst().first) {
            case ("GET", "git", "ref"):
                return (200, encode(["object": ["sha": head]]))
            case ("GET", "git", "commits"):
                guard let c = commits[rest[2]] else { return (404, Data()) }
                return (200, encode(["tree": ["sha": c.tree], "committer": ["date": "2026-01-02T03:04:05Z"]]))
            case ("GET", "git", "trees"):
                guard let flat = trees[rest[2]] else { return (404, Data()) }
                return (200, encode(["sha": rest[2], "truncated": false, "tree": treeListing(flat)]))
            case ("GET", "git", "blobs"):
                guard let data = blobs[rest[2]] else { return (404, Data()) }
                return (200, data)
            case ("POST", "git", "blobs"):
                let sha = newSHA()
                blobs[sha] = Data(base64Encoded: json["content"] as? String ?? "") ?? Data()
                return (201, encode(["sha": sha]))
            case ("POST", "git", "trees"):
                var flat = trees[json["base_tree"] as! String] ?? [:]
                for change in json["tree"] as! [[String: Any]] {
                    let p = change["path"] as! String
                    if let sha = change["sha"] as? String { flat[p] = sha } else { flat[p] = nil }
                }
                let sha = newSHA()
                trees[sha] = flat
                return (201, encode(["sha": sha]))
            case ("POST", "git", "commits"):
                let sha = newSHA()
                commits[sha] = Commit(tree: json["tree"] as! String, parents: json["parents"] as! [String])
                return (201, encode(["sha": sha]))
            case ("PATCH", "git", "refs"):
                let target = json["sha"] as! String
                let force = json["force"] as? Bool ?? false
                if !force, commits[target]?.parents.first != head {
                    return (422, encode(["message": "Update is not a fast forward"]))
                }
                repos[parts[2]] = target
                return (200, encode(["object": ["sha": target]]))
            default:
                return (404, encode(["message": "Not Found"]))
            }
        }
    }

    private func repoJSON(_ name: String) -> [String: Any] {
        ["name": name, "owner": ["login": owner], "default_branch": "main", "size": 1, "archived": false, "private": true]
    }

    /// Every blob's raw bytes in a repo's current tree, for checking nothing readable leaked.
    func rawBlobs(repo: String) -> [String: Data] {
        sync { trees[commits[repos[repo]!]!.tree]!.mapValues { blobs[$0]! } }
    }

    private func treeListing(_ flat: [String: String]) -> [[String: Any]] {
        var dirs = Set<String>()
        for path in flat.keys {
            var parent = parentPath(of: path)
            while !parent.isEmpty { dirs.insert(parent); parent = parentPath(of: parent) }
        }
        let folders = dirs.sorted().map { ["path": $0, "mode": "040000", "type": "tree", "sha": "tree-\($0)"] as [String: Any] }
        let files = flat.keys.sorted().map { p -> [String: Any] in
            ["path": p, "mode": "100644", "type": "blob", "sha": flat[p]!, "size": blobs[flat[p]!]?.count ?? 0]
        }
        return folders + files
    }

    private func encode(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Routes URLSession traffic to the fake for the duration of a test. Each session carries its own
/// server ID in a header, so suites running in parallel never share state.
final class FakeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var servers: [String: FakeGitHub] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Fake-Server") ?? ""
        let server = Self.lock.withLock { Self.servers[id] }
        let (status, data) = server?.handle(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(for server: FakeGitHub) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { servers[id] = server }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProtocol.self]
        config.httpAdditionalHeaders = ["X-Fake-Server": id]
        return URLSession(configuration: config)
    }
}
