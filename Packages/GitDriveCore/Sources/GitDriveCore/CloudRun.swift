import Foundation

public enum CloudTask: String, Sendable, CaseIterable {
    case compressVideo = "compress-video"
    case convertPDF = "convert-pdf"

    public var title: String {
        switch self {
        case .compressVideo: "Compressing video"
        case .convertPDF: "Converting to PDF"
        }
    }

    public static func accepts(_ filename: String, task: CloudTask) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch task {
        case .compressVideo: return ["mov", "mp4", "m4v", "mkv", "avi", "webm"].contains(ext)
        case .convertPDF: return ["doc", "docx", "odt", "rtf", "txt", "ppt", "pptx", "odp", "xls", "xlsx", "ods", "csv"].contains(ext)
        }
    }
}

public struct CloudRun: Sendable, Equatable {
    public let id: Int
    public let url: URL
    public var status: String
    public var conclusion: String?
    public var finished: Bool { status == "completed" }
}

extension Reserved {
    public static let cloudWorkflow = ".github/workflows/gitdrive-run.yml"
}

extension SyncEngine {
    /// The workflow GitDrive adds to a repo. The file path reaches the script only through an
    /// environment variable, so unusual filenames can't inject shell commands.
    static let cloudWorkflow = """
    # Added by GitDrive for "Run in the cloud". Safe to delete; GitDrive adds it again when needed.
    name: GitDrive cloud run
    on:
      workflow_dispatch:
        inputs:
          task:
            required: true
            type: choice
            options: [compress-video, convert-pdf]
          path:
            required: true
            type: string
    permissions:
      contents: write
    concurrency:
      group: gitdrive-run
      cancel-in-progress: false
    jobs:
      run:
        runs-on: ubuntu-latest
        timeout-minutes: 60
        steps:
          - uses: actions/checkout@v4
            with:
              lfs: true
          - name: Install tools
            env:
              TASK: ${{ inputs.task }}
            run: |
              sudo apt-get update -qq
              if [ "$TASK" = compress-video ]; then
                sudo apt-get install -y -qq ffmpeg
              else
                sudo apt-get install -y -qq --no-install-recommends libreoffice-writer libreoffice-calc libreoffice-impress
              fi
          - name: Run
            env:
              TASK: ${{ inputs.task }}
              SRC: ${{ inputs.path }}
            run: |
              set -euo pipefail
              test -f "$SRC"
              dir=$(dirname "$SRC"); base=$(basename "$SRC"); stem="${base%.*}"
              if [ "$TASK" = compress-video ]; then
                out="$dir/$stem (compressed).mp4"
                ffmpeg -y -loglevel error -i "$SRC" -c:v libx264 -crf 28 -preset medium -c:a aac -b:a 128k -movflags +faststart "$out"
              else
                soffice --headless --convert-to pdf --outdir "$dir" "$SRC"
                out="$dir/$stem.pdf"
              fi
              git config user.name "GitDrive"
              git config user.email "gitdrive@users.noreply.github.com"
              git add -- "$out"
              git commit -m "Add ${out##*/}"
              git push

    """

    /// Starts a GitHub Actions run that processes `path`. Adds or updates the workflow first.
    public func runInCloud(repo name: String, path: String, task: CloudTask) async throws -> CloudRun {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        guard !isVault(name) else {
            throw DriveError.unsupportedMove("Encrypted folders can't run in the cloud, because GitHub would need the key.")
        }
        let (entries, _) = try await listing(of: rec)
        let expected = Data(Self.cloudWorkflow.utf8)
        let current = entries.first { $0.path == Reserved.cloudWorkflow }
        var currentData: Data?
        if let current { currentData = try await client.blobData(owner: rec.owner, repo: name, sha: current.sha) }
        if currentData != expected {
            let blob = try await client.createBlob(owner: rec.owner, repo: name, data: expected)
            do {
                try await commit(repo: name, edits: [.put(path: Reserved.cloudWorkflow, sha: blob)], claims: [:], message: "Add GitDrive cloud run workflow")
            } catch let e as GitHubError where e.kind == .notFound || e.kind == .server(status: 403) || e.kind == .server(status: 422) {
                throw GitHubError(e.kind, "GitHub didn't allow adding the workflow. Sign in again with a token that has the workflow scope.")
            }
        }
        // A brand-new workflow can take a few seconds before GitHub accepts runs for it.
        var lastError: Error?
        for attempt in 0..<6 {
            do {
                try await client.dispatch(owner: rec.owner, repo: name, workflow: "gitdrive-run.yml", ref: rec.branch, inputs: ["task": task.rawValue, "path": path])
                lastError = nil
                break
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
            }
        }
        if let lastError { throw lastError }
        for _ in 0..<10 {
            if let run = try await client.latestRun(owner: rec.owner, repo: name, workflow: "gitdrive-run.yml") { return run }
            try await Task.sleep(for: .seconds(2))
        }
        throw GitHubError(.notFound, "The run started but GitHub didn't list it yet. Check the repo's Actions tab.")
    }

    public func cloudRunStatus(repo name: String, id: Int) async throws -> CloudRun {
        guard let rec = try store.repo(named: name) else { throw DriveError.noSuchItem }
        return try await client.run(owner: rec.owner, repo: name, id: id)
    }
}

extension GitHubClient {
    func dispatch(owner: String, repo: String, workflow: String, ref: String, inputs: [String: String]) async throws {
        struct Body: Encodable { let ref: String; let inputs: [String: String] }
        let _: EmptyResponse = try await send(
            "POST", "repos/\(owner)/\(repo)/actions/workflows/\(workflow)/dispatches", body: Body(ref: ref, inputs: inputs)
        )
    }

    private struct RunJSON: Decodable { let id: Int; let html_url: URL; let status: String; let conclusion: String? }

    func latestRun(owner: String, repo: String, workflow: String) async throws -> CloudRun? {
        struct List: Decodable { let workflow_runs: [RunJSON] }
        let list: List = try await get("repos/\(owner)/\(repo)/actions/workflows/\(workflow)/runs", query: ["per_page": "1", "event": "workflow_dispatch"])
        return list.workflow_runs.first.map { CloudRun(id: $0.id, url: $0.html_url, status: $0.status, conclusion: $0.conclusion) }
    }

    func run(owner: String, repo: String, id: Int) async throws -> CloudRun {
        let run: RunJSON = try await get("repos/\(owner)/\(repo)/actions/runs/\(id)")
        return CloudRun(id: run.id, url: run.html_url, status: run.status, conclusion: run.conclusion)
    }
}
