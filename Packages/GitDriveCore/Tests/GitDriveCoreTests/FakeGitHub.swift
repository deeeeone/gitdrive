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

            if method == "GET", path == "/user/repos" {
                let list = repos.keys.sorted().map { name -> [String: Any] in
                    ["name": name, "owner": ["login": owner], "default_branch": "main", "size": 1, "archived": false, "private": true]
                }
                return (200, encode(list))
            }
            guard parts.count >= 3, parts[0] == "repos", let head = repos[parts[2]] else { return (404, encode(["message": "Not Found"])) }
            let rest = Array(parts.dropFirst(3))

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

/// Routes URLSession traffic to the fake for the duration of a test.
final class FakeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: FakeGitHub?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.server!.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(for server: FakeGitHub) -> URLSession {
        Self.server = server
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProtocol.self]
        return URLSession(configuration: config)
    }
}
