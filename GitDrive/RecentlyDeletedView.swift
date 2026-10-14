import GitDriveCore
import SwiftUI

/// Files deleted in the last 30 days, with Restore.
struct RecentlyDeletedView: View {
    let model: AppModel
    /// Limit to one top-level folder, or nil for all of them.
    let repo: String?
    @State private var files: [DeletedFile] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView("Looking through the last 30 days").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView("Nothing deleted recently", systemImage: "trash")
            } else {
                List(files) { file in
                    HStack {
                        Image(systemName: "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text((file.path as NSString).lastPathComponent)
                            Text("\(file.folder)/\(file.path) · deleted \(file.deletedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Restore") { Task { await restore(file) } }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            files = try await model.readyEngine().recentlyDeleted(repo: repo)
        } catch {
            message = String(describing: error)
        }
        loading = false
    }

    private func restore(_ file: DeletedFile) async {
        do {
            try await model.readyEngine().restore(file)
            files.removeAll { $0 == file }
            message = "Restored \((file.path as NSString).lastPathComponent). Finder updates within a minute."
            await model.refresh()
        } catch {
            message = String(describing: error)
        }
    }
}
