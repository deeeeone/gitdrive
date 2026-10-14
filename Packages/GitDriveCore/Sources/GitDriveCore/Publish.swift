import Foundation

extension SyncEngine {
    /// Copies a folder into a public repo (replacing what was published before) and serves it with
    /// GitHub Pages. Adds a simple index page when the folder has none. Returns the site's address.
    public func publish(repo name: String, path: String, as publicName: String) async throws -> URL {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        guard !isVault(name) else {
            throw DriveError.unsupportedMove("Encrypted folders can't be published. Decrypt the folder first if you really want it public.")
        }
        let target = try await client.publicRepo(named: publicName)
        let owner = target.owner.login
        let branch = target.defaultBranch ?? "main"

        let (entries, _) = try await listing(of: rec)
        let prefix = path.isEmpty ? "" : path + "/"
        let files = entries.filter { $0.type == .blob && $0.path.hasPrefix(prefix) && !Reserved.isHidden(path: $0.path) }
        var changes: [TreeChange] = []
        var names: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(prefix.count))
            let url = try await readContent(rec, sha: file.sha)
            defer { try? FileManager.default.removeItem(at: url) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= maxFileSize else { continue }
            let sha = try await client.createBlob(owner: owner, repo: target.name, contentsOf: url)
            changes.append(TreeChange(path: relative, sha: sha))
            names.append(relative)
        }
        if !names.contains(where: { $0.lowercased() == "index.html" }) {
            let title = path.isEmpty ? (try store.item(repo: name, path: "")?.filename ?? publicName) : (path as NSString).lastPathComponent
            let page = Self.indexPage(title: title, files: names.sorted())
            changes.append(TreeChange(path: "index.html", sha: try await client.createBlob(owner: owner, repo: target.name, data: Data(page.utf8))))
        }
        // Without this, Pages runs Jekyll and hides files starting with "_".
        changes.append(TreeChange(path: ".nojekyll", sha: try await client.createBlob(owner: owner, repo: target.name, data: Data())))

        let head = try await client.headSHA(owner: owner, repo: target.name, branch: branch)
        let tree = try await client.createTree(owner: owner, repo: target.name, base: nil, changes: changes)
        let commit = try await client.createCommit(owner: owner, repo: target.name, message: "Publish with GitDrive", tree: tree, parents: [head])
        try await client.updateRef(owner: owner, repo: target.name, branch: branch, sha: commit)
        return try await client.enablePages(owner: owner, repo: target.name, branch: branch)
    }

    /// A plain page linking every file, with images shown as a gallery.
    static func indexPage(title: String, files: [String]) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func href(_ s: String) -> String { s.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/") }
        let images = files.filter { ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
        let others = files.filter { !images.contains($0) }
        let gallery = images.map { "<a href=\"\(href($0))\"><img src=\"\(href($0))\" alt=\"\(escape($0))\" loading=\"lazy\"></a>" }.joined(separator: "\n")
        let list = others.map { "<li><a href=\"\(href($0))\">\(escape($0))</a></li>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; color: #1b1f4a; }
        @media (prefers-color-scheme: dark) { body { background: #0f1220; color: #e6e8f5; } a { color: #8fa8ff; } }
        .gallery { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 8px; }
        .gallery img { width: 100%; height: 180px; object-fit: cover; border-radius: 8px; }
        footer { margin-top: 3rem; font-size: 13px; opacity: 0.6; }
        </style>
        </head>
        <body>
        <h1>\(escape(title))</h1>
        <div class="gallery">
        \(gallery)
        </div>
        <ul>
        \(list)
        </ul>
        <footer>Published with GitDrive</footer>
        </body>
        </html>
        """
    }
}
