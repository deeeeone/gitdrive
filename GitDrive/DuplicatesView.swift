import GitDriveCore
import SwiftUI

/// Files stored more than once, with Keep One.
struct DuplicatesView: View {
    let model: AppModel
    @State private var groups: [DuplicateGroup] = []
    @State private var folders: [String: String] = [:]
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                ProgressView("Comparing files").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView("No duplicates", systemImage: "doc.on.doc")
            } else {
                let total = groups.reduce(0) { $0 + $1.wasted }
                let spread = Set(groups.flatMap { $0.items.map(\.repo) }).count
                Text("\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) of duplicates across \(spread) folder\(spread == 1 ? "" : "s")")
                    .font(.headline)
                List(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(group.items.count) copies, \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .file)) each")
                            .font(.caption.weight(.semibold))
                        ForEach(group.items, id: \.id) { item in
                            HStack {
                                Text("\(folders[item.repo] ?? item.repo)/\(item.path)").lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Keep This One") { Task { await keep(item, in: group) } }.controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("Removed copies stay in history and can be restored from Recently Deleted.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        do {
            let engine = try await model.readyEngine()
            try await engine.syncAll()
            groups = try await engine.duplicates()
            for item in try engine.store.children(of: ItemStore.rootID) { folders[item.repo] = item.filename }
        } catch {
            message = String(describing: error)
        }
        loading = false
    }

    private func keep(_ item: ItemRecord, in group: DuplicateGroup) async {
        do {
            try await model.readyEngine().removeDuplicates(group, keeping: item)
            groups.removeAll { $0 == group }
            message = "Removed \(group.items.count - 1) extra cop\(group.items.count == 2 ? "y" : "ies")."
            await model.refresh()
        } catch {
            message = String(describing: error)
        }
    }
}
