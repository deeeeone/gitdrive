import Foundation

/// Files with identical contents.
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public var id: String { key }
    let key: String
    public let size: Int64
    public let items: [ItemRecord]
    /// Space that removing all but one copy would free.
    public var wasted: Int64 { size * Int64(items.count - 1) }
}

extension SyncEngine {
    /// Groups identical files using hashes the index already has, so nothing downloads. Plain repos
    /// compare git blob SHAs across all folders. Encrypted folders compare within each folder, since
    /// each has its own key.
    public func duplicates() throws -> [DuplicateGroup] {
        var groups: [String: [ItemRecord]] = [:]
        for item in try store.allItems() where !item.isDirectory && item.size > 0 {
            guard let sha = item.sha, !Reserved.isHidden(path: item.path) else { continue }
            let key = isVault(item.repo) ? "\(item.repo):\(sha)" : sha
            groups[key, default: []].append(item)
        }
        return groups.compactMap { key, items in
            items.count > 1 ? DuplicateGroup(key: key, size: items[0].size, items: items.sorted { $0.path < $1.path }) : nil
        }
        .sorted { $0.wasted > $1.wasted }
    }

    /// Deletes every copy in the group except `keep`. The deleted copies stay in git history.
    public func removeDuplicates(_ group: DuplicateGroup, keeping keep: ItemRecord) async throws {
        for item in group.items where item.id != keep.id {
            try await delete(id: item.id)
        }
    }
}
