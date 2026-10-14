import GitDriveCore
import SwiftUI

/// Starts a cloud run and follows it until it finishes.
struct CloudRunView: View {
    let model: AppModel
    let repo: String
    let path: String
    let task: CloudTask
    @State private var run: CloudRun?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(task.title) in the cloud", systemImage: "cloud").font(.headline)
            Text((path as NSString).lastPathComponent).foregroundStyle(.secondary)
            if let run {
                HStack(spacing: 8) {
                    if !run.finished { ProgressView().controlSize(.small) }
                    Text(statusText(run))
                }
                Link("Watch on GitHub", destination: run.url).font(.caption)
            } else if message == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting on GitHub Actions") }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Runs on GitHub's machines and uses your Actions minutes. The result is saved next to the original.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
        .task { await start() }
    }

    private func statusText(_ run: CloudRun) -> String {
        guard run.finished else { return run.status == "queued" ? "Waiting for a GitHub machine" : "Working" }
        return run.conclusion == "success" ? "Done. The result appears next to the original within a minute." : "The run failed (\(run.conclusion ?? "unknown")). See GitHub for details."
    }

    private func start() async {
        do {
            let engine = try await model.readyEngine()
            try await engine.syncRepo(repo)
            var current = try await engine.runInCloud(repo: repo, path: path, task: task)
            run = current
            while !current.finished {
                try await Task.sleep(for: .seconds(10))
                current = try await engine.cloudRunStatus(repo: repo, id: current.id)
                run = current
            }
            await model.refresh()
        } catch {
            message = (error as? GitHubError)?.message ?? String(describing: error)
        }
    }
}
