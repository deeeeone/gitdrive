import GitDriveCore
import SwiftUI

/// Earlier versions of one file, with Open and Restore.
struct VersionsView: View {
    let model: AppModel
    let repo: String
    let path: String
    @State private var versions: [FileVersion] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((path as NSString).lastPathComponent).font(.headline)
            if loading {
                ProgressView("Reading history").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if versions.isEmpty {
                ContentUnavailableView("No earlier versions", systemImage: "clock")
            } else {
                List(versions) { version in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(version.date.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: version.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if version.isCurrent {
                            Text("Current").foregroundStyle(.secondary)
                        } else {
                            Button("Open") { Task { await open(version) } }
                            Button("Restore") { Task { await restore(version) } }
                        }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        do {
            versions = try await model.readyEngine().versions(repo: repo, path: path)
        } catch {
            message = String(describing: error)
        }
        loading = false
    }

    private func open(_ version: FileVersion) async {
        do {
            let url = try await model.readyEngine().contents(of: version, repo: repo)
            NSWorkspace.shared.open(Tools.named(url, (path as NSString).lastPathComponent, suffix: version.date))
        } catch {
            message = String(describing: error)
        }
    }

    private func restore(_ version: FileVersion) async {
        do {
            try await model.readyEngine().restore(version, repo: repo, path: path)
            message = "Restored the version from \(version.date.formatted(date: .abbreviated, time: .shortened)). Finder updates within a minute."
            await model.refresh()
            await load()
        } catch {
            message = String(describing: error)
        }
    }
}
