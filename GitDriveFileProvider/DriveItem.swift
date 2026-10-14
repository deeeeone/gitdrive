import FileProvider
import GitDriveCore
import UniformTypeIdentifiers

/// Finder's view of one `ItemRecord`. A nil record is the drive's root.
final class DriveItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, Sendable {
    let record: ItemRecord?

    init(_ record: ItemRecord?) {
        self.record = record
    }

    static let root = DriveItem(nil)

    var itemIdentifier: NSFileProviderItemIdentifier {
        record.map { NSFileProviderItemIdentifier($0.id) } ?? .rootContainer
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let record, record.parentID != ItemStore.rootID else { return .rootContainer }
        return NSFileProviderItemIdentifier(record.parentID)
    }

    var filename: String { record?.filename ?? "GitHub" }

    private var isDirectory: Bool { record?.isDirectory ?? true }

    var contentType: UTType {
        if isDirectory { return .folder }
        let ext = (filename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var documentSize: NSNumber? {
        guard let record, !record.isDirectory else { return nil }
        return NSNumber(value: record.size)
    }

    var capabilities: NSFileProviderItemCapabilities {
        guard let record else { return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
        if record.isDirectory {
            var caps: NSFileProviderItemCapabilities = [
                .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting, .allowsEvicting,
            ]
            if !record.path.isEmpty { caps.insert(.allowsReparenting) }
            return caps
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting, .allowsEvicting]
    }

    var itemVersion: NSFileProviderItemVersion {
        let content = record?.sha ?? "folder"
        // Decorations are part of the metadata version so Finder refreshes the badge when it changes.
        let badges = (decorations ?? []).map(\.rawValue).joined(separator: ",")
        let flags = (userInfo ?? [:]).compactMap { ($0.value as? Bool) == true ? "\($0.key)" : nil }.sorted().joined(separator: ",")
        let metadata = record.map { "\($0.repo)/\($0.path)#\(badges)#\(flags)" } ?? "root"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))
    }

    var contentModificationDate: Date? { record?.modified }

    /// Facts Finder action rules in Info.plist test with `userInfo.<key> == 1`. Feature flags are folded in,
    /// so an action only appears when its Extra is on.
    var userInfo: [AnyHashable: Any]? {
        guard let record else { return nil }
        let encrypted = record.displayName != nil
        return [
            "file": !record.isDirectory,
            "folder": record.isDirectory,
            "top": record.path.isEmpty,
            "plain": !encrypted,
            "versions": !record.isDirectory && AppConfig.isOn(.versions),
            "deleted": record.isDirectory && AppConfig.isOn(.recentlyDeleted),
        ]
    }

    /// Encrypted top-level folders get a lock badge (only encrypted repos carry a display name).
    /// With the Sync badges extra, conflict copies get a warning badge.
    var decorations: [NSFileProviderItemDecorationIdentifier]? {
        guard let record else { return nil }
        var badges: [NSFileProviderItemDecorationIdentifier] = []
        if record.path.isEmpty, record.displayName != nil { badges.append(Self.encryptedDecoration) }
        if !record.isDirectory, AppConfig.isOn(.syncBadges), isConflictCopy(record.filename) {
            badges.append(Self.conflictDecoration)
        }
        return badges.isEmpty ? nil : badges
    }

    static let conflictDecoration = NSFileProviderItemDecorationIdentifier(
        rawValue: (Bundle.main.bundleIdentifier ?? "com.diwan.gitdrive.FileProvider") + ".conflict"
    )

    /// Must match the Identifier in NSFileProviderDecorations in the extension's Info.plist.
    static let encryptedDecoration = NSFileProviderItemDecorationIdentifier(
        rawValue: (Bundle.main.bundleIdentifier ?? "com.diwan.gitdrive.FileProvider") + ".encrypted"
    )
    var creationDate: Date? { record?.modified }
}
