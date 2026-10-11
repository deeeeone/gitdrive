import FileProvider
import GitDriveCore
import UniformTypeIdentifiers

/// Finder's view of one `ItemRecord`. A nil record is the drive's root.
final class DriveItem: NSObject, NSFileProviderItem, Sendable {
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
        let metadata = record.map { "\($0.repo)/\($0.path)" } ?? "root"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))
    }

    var contentModificationDate: Date? { record?.modified }
    var creationDate: Date? { record?.modified }
}
